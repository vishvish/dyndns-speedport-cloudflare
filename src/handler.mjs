import { timingSafeEqual } from "node:crypto";
import { isIP } from "node:net";
import { SSMClient, GetParameterCommand } from "@aws-sdk/client-ssm";

const ssmClient = new SSMClient({});
let cachedSecrets = null;

async function loadSecrets() {
  if (cachedSecrets) return cachedSecrets;

  const authParamName = process.env.DDNS_AUTH_PARAM_NAME;
  const tokenParamName = process.env.CF_API_TOKEN_PARAM_NAME;

  if (!authParamName || !tokenParamName) {
    throw new Error("DDNS_AUTH_PARAM_NAME and CF_API_TOKEN_PARAM_NAME must be set");
  }

  const [authResult, tokenResult] = await Promise.all([
    ssmClient.send(new GetParameterCommand({ Name: authParamName, WithDecryption: true })),
    ssmClient.send(new GetParameterCommand({ Name: tokenParamName, WithDecryption: true }))
  ]);

  const auth = JSON.parse(authResult.Parameter.Value);
  cachedSecrets = {
    username: auth.username,
    password: auth.password,
    cfToken: tokenResult.Parameter.Value
  };
  return cachedSecrets;
}

const DYNDNS_SUCCESS = 200;

function dynResponse(body, statusCode = DYNDNS_SUCCESS) {
  return {
    statusCode,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store"
    },
    body: `${body}\n`
  };
}

function getHeader(headers, key) {
  if (!headers) return undefined;
  const lower = key.toLowerCase();
  for (const [k, v] of Object.entries(headers)) {
    if (k.toLowerCase() === lower) return v;
  }
  return undefined;
}

function parseQuery(event) {
  if (event?.queryStringParameters) return event.queryStringParameters;

  if (event?.rawQueryString) {
    const params = new URLSearchParams(event.rawQueryString);
    const out = {};
    for (const [k, v] of params.entries()) out[k] = v;
    return out;
  }

  return {};
}

function getSourceIp(event) {
  const xff = getHeader(event?.headers, "x-forwarded-for");
  if (xff) return xff.split(",")[0].trim();

  return (
    event?.requestContext?.http?.sourceIp ||
    event?.requestContext?.identity?.sourceIp ||
    undefined
  );
}

function parseBasicAuth(authHeader) {
  if (!authHeader || !authHeader.toLowerCase().startsWith("basic ")) return null;

  const encoded = authHeader.slice(6).trim();
  if (!encoded) return null;

  try {
    const decoded = Buffer.from(encoded, "base64").toString("utf8");
    const split = decoded.indexOf(":");
    if (split < 0) return null;

    return {
      username: decoded.slice(0, split),
      password: decoded.slice(split + 1)
    };
  } catch {
    return null;
  }
}

function safeCompare(a, b) {
  const aBuf = Buffer.from(a ?? "", "utf8");
  const bBuf = Buffer.from(b ?? "", "utf8");
  if (aBuf.length !== bBuf.length) return false;
  return timingSafeEqual(aBuf, bBuf);
}

function parseHostnames(hostnameParam) {
  if (!hostnameParam) return [];
  return hostnameParam
    .split(",")
    .map((h) => h.trim().toLowerCase())
    .filter(Boolean);
}

function isFqdn(hostname) {
  if (!hostname || hostname.length > 253) return false;

  const labels = hostname.split(".");
  if (labels.length < 2) return false;

  return labels.every((label) => {
    if (!label || label.length > 63) return false;
    if (label.startsWith("-") || label.endsWith("-")) return false;
    return /^[a-z0-9-]+$/i.test(label);
  });
}

function getAllowedHostnames() {
  const raw = process.env.DDNS_ALLOWED_HOSTNAMES;
  if (!raw) return null;
  const set = new Set(
    raw
      .split(",")
      .map((h) => h.trim().toLowerCase())
      .filter(Boolean)
  );
  return set.size > 0 ? set : null;
}

async function cloudflareRequest(path, cfToken, options = {}) {
  const zoneId = process.env.CF_ZONE_ID;

  if (!cfToken || !zoneId) {
    throw new Error("CF_API_TOKEN and CF_ZONE_ID are required");
  }

  const url = `https://api.cloudflare.com/client/v4/zones/${zoneId}${path}`;
  const response = await fetch(url, {
    ...options,
    headers: {
      Authorization: `Bearer ${cfToken}`,
      "Content-Type": "application/json",
      ...(options.headers || {})
    }
  });

  const payload = await response.json();
  if (!response.ok || !payload.success) {
    const details = JSON.stringify(payload.errors || payload);
    throw new Error(`Cloudflare API error (${response.status}): ${details}`);
  }

  return payload.result;
}

async function getDnsRecord(hostname, type, cfToken) {
  const qs = new URLSearchParams({ type, name: hostname });
  const result = await cloudflareRequest(`/dns_records?${qs.toString()}`, cfToken);
  return result;
}

async function createDnsRecord(hostname, type, ip, proxied, cfToken) {
  return cloudflareRequest("/dns_records", cfToken, {
    method: "POST",
    body: JSON.stringify({
      type,
      name: hostname,
      content: ip,
      proxied,
      ttl: 1
    })
  });
}

async function updateDnsRecord(id, hostname, type, ip, proxied, cfToken) {
  return cloudflareRequest(`/dns_records/${id}`, cfToken, {
    method: "PUT",
    body: JSON.stringify({
      type,
      name: hostname,
      content: ip,
      proxied,
      ttl: 1
    })
  });
}

export async function handler(event) {
  try {
    let secrets;
    try {
      secrets = await loadSecrets();
    } catch (err) {
      console.error("Failed to load secrets from SSM", err);
      return dynResponse("911", 500);
    }

    const expectedUser = secrets.username;
    const expectedPass = secrets.password;

    const auth = parseBasicAuth(getHeader(event?.headers, "authorization"));
    if (
      !auth ||
      !safeCompare(auth.username, expectedUser) ||
      !safeCompare(auth.password, expectedPass)
    ) {
      return {
        ...dynResponse("badauth", 401),
        headers: {
          "WWW-Authenticate": 'Basic realm="DynDNS"',
          "Content-Type": "text/plain; charset=utf-8",
          "Cache-Control": "no-store"
        }
      };
    }

    // Dyn-compatible: support comma-separated IPs in `myip` (IPv4,IPv6)
    const query = parseQuery(event);
    const hostnames = parseHostnames(query.hostname);

    if (hostnames.length === 0) return dynResponse("notfqdn");
    if (hostnames.length > 1) return dynResponse("numhost");

    const hostname = hostnames[0];
    if (!isFqdn(hostname)) return dynResponse("notfqdn");

    const allowedHostnames = getAllowedHostnames();
    if (allowedHostnames && !allowedHostnames.has(hostname)) {
      return dynResponse("nohost");
    }

    // Parse comma-separated IPs and accept IPv4 and IPv6 in one request
    const myipRaw = (query.myip || getSourceIp(event) || "").trim();
    const ips = myipRaw.split(",").map((s) => s.trim()).filter(Boolean);
    if (ips.length === 0) return dynResponse("dnserr");

    const proxied = (process.env.CF_PROXIED || "false").toLowerCase() === "true";

    // Process each IP independently and return one line per IP (good/nochg/911)
    const results = [];
    for (const ipStr of ips) {
      if (!isIP(ipStr)) {
        results.push("dnserr");
        continue;
      }

      const type = isIP(ipStr) === 6 ? "AAAA" : "A";
      try {
        const records = await getDnsRecord(hostname, type, secrets.cfToken);
        if (records.length > 1) {
          results.push("numhost");
          continue;
        }

        if (records.length === 0) {
          await createDnsRecord(hostname, type, ipStr, proxied, secrets.cfToken);
          results.push(`good ${ipStr}`);
          continue;
        }

        const [record] = records;
        const contentUnchanged = record.content === ipStr;
        const proxiedUnchanged = Boolean(record.proxied) === proxied;

        if (contentUnchanged && proxiedUnchanged) {
          results.push(`nochg ${ipStr}`);
          continue;
        }

        await updateDnsRecord(record.id, hostname, type, ipStr, proxied, secrets.cfToken);
        results.push(`good ${ipStr}`);
      } catch (err) {
        console.error("Update failed for", ipStr, err);
        results.push("911");
      }
    }

    const all911 = results.length > 0 && results.every((r) => r === "911");
    const status = all911 ? 500 : DYNDNS_SUCCESS;
    return dynResponse(results.join("\n"), status);
  } catch (error) {
    console.error("Update failed", error);
    return dynResponse("911", 500);
  }
}
