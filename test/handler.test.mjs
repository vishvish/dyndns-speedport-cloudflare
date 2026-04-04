import test from "node:test";
import assert from "node:assert/strict";

import { handler } from "../src/handler.mjs";

const ORIGINAL_ENV = { ...process.env };
const ORIGINAL_FETCH = global.fetch;
const ORIGINAL_CONSOLE_ERROR = console.error;

function makeAuth(username = "user", password = "pass") {
  return `Basic ${Buffer.from(`${username}:${password}`, "utf8").toString("base64")}`;
}

function baseEvent(overrides = {}) {
  return {
    headers: {
      authorization: makeAuth()
    },
    queryStringParameters: {
      hostname: "home.example.com",
      myip: "203.0.113.42"
    },
    requestContext: {
      http: {
        sourceIp: "198.51.100.22"
      }
    },
    ...overrides
  };
}

function setBaseEnv() {
  process.env.DDNS_USERNAME = "user";
  process.env.DDNS_PASSWORD = "pass";
  process.env.CF_API_TOKEN = "token";
  process.env.CF_ZONE_ID = "zone";
  delete process.env.DDNS_ALLOWED_HOSTNAMES;
  delete process.env.CF_PROXIED;
}

function cfOk(result) {
  return {
    ok: true,
    status: 200,
    json: async () => ({ success: true, result })
  };
}

function useFetchResponses(responses) {
  const queue = [...responses];
  const calls = [];
  global.fetch = async (url, options) => {
    calls.push({ url, options });
    assert.ok(queue.length > 0, "unexpected fetch call");
    return queue.shift();
  };
  return calls;
}

test.beforeEach(() => {
  process.env = { ...ORIGINAL_ENV };
  setBaseEnv();
  global.fetch = ORIGINAL_FETCH;
  console.error = () => {};
});

test.after(() => {
  process.env = ORIGINAL_ENV;
  global.fetch = ORIGINAL_FETCH;
  console.error = ORIGINAL_CONSOLE_ERROR;
});

test("returns 911 if DDNS credentials are missing", async () => {
  delete process.env.DDNS_USERNAME;
  const response = await handler(baseEvent());

  assert.equal(response.statusCode, 500);
  assert.equal(response.body.trim(), "911");
});

test("returns badauth when basic auth is invalid", async () => {
  const response = await handler(
    baseEvent({ headers: { authorization: makeAuth("user", "wrong") } })
  );

  assert.equal(response.statusCode, 401);
  assert.equal(response.body.trim(), "badauth");
  assert.equal(response.headers["WWW-Authenticate"], 'Basic realm="DynDNS"');
});

test("returns notfqdn when hostname is missing", async () => {
  const response = await handler(
    baseEvent({ queryStringParameters: { myip: "203.0.113.42" } })
  );

  assert.equal(response.statusCode, 200);
  assert.equal(response.body.trim(), "notfqdn");
});

test("returns numhost when multiple hostnames are provided", async () => {
  const response = await handler(
    baseEvent({
      queryStringParameters: {
        hostname: "a.example.com,b.example.com",
        myip: "203.0.113.42"
      }
    })
  );

  assert.equal(response.statusCode, 200);
  assert.equal(response.body.trim(), "numhost");
});

test("returns nohost when hostname is not in allow list", async () => {
  process.env.DDNS_ALLOWED_HOSTNAMES = "router.example.com";

  const response = await handler(baseEvent());

  assert.equal(response.statusCode, 200);
  assert.equal(response.body.trim(), "nohost");
});

test("returns dnserr when myip and source ip are invalid", async () => {
  const response = await handler(
    baseEvent({
      queryStringParameters: {
        hostname: "home.example.com",
        myip: "not-an-ip"
      },
      requestContext: { http: { sourceIp: "still-not-ip" } }
    })
  );

  assert.equal(response.statusCode, 200);
  assert.equal(response.body.trim(), "dnserr");
});

test("creates DNS record and returns good when record does not exist", async () => {
  const calls = useFetchResponses([cfOk([]), cfOk({ id: "new-id" })]);

  const response = await handler(baseEvent());

  assert.equal(response.statusCode, 200);
  assert.equal(response.body.trim(), "good 203.0.113.42");
  assert.equal(calls.length, 2);
  assert.match(calls[0].url, /\/dns_records\?/);
  assert.match(calls[1].url, /\/dns_records$/);
  assert.equal(calls[1].options.method, "POST");
});

test("falls back to sourceIp when myip is omitted", async () => {
  useFetchResponses([
    cfOk([
      {
        id: "record-id",
        content: "198.51.100.22",
        proxied: false
      }
    ])
  ]);

  const response = await handler(
    baseEvent({ queryStringParameters: { hostname: "home.example.com" } })
  );

  assert.equal(response.statusCode, 200);
  assert.equal(response.body.trim(), "nochg 198.51.100.22");
});

test("uses AAAA type when updating an IPv6 address", async () => {
  const calls = useFetchResponses([cfOk([]), cfOk({ id: "new-ipv6" })]);

  const response = await handler(
    baseEvent({
      queryStringParameters: {
        hostname: "home.example.com",
        myip: "2001:db8::10"
      }
    })
  );

  assert.equal(response.statusCode, 200);
  assert.equal(response.body.trim(), "good 2001:db8::10");
  assert.match(calls[0].url, /type=AAAA/);

  const requestBody = JSON.parse(calls[1].options.body);
  assert.equal(requestBody.type, "AAAA");
  assert.equal(requestBody.content, "2001:db8::10");
});

test("returns nochg when existing record content matches", async () => {
  useFetchResponses([
    cfOk([
      {
        id: "record-id",
        content: "203.0.113.42",
        proxied: false
      }
    ])
  ]);

  const response = await handler(baseEvent());

  assert.equal(response.statusCode, 200);
  assert.equal(response.body.trim(), "nochg 203.0.113.42");
});

test("updates DNS record and returns good when content changes", async () => {
  const calls = useFetchResponses([
    cfOk([
      {
        id: "record-id",
        content: "203.0.113.5",
        proxied: false
      }
    ]),
    cfOk({ id: "record-id" })
  ]);

  const response = await handler(baseEvent());

  assert.equal(response.statusCode, 200);
  assert.equal(response.body.trim(), "good 203.0.113.42");
  assert.equal(calls.length, 2);
  assert.match(calls[1].url, /\/dns_records\/record-id$/);
  assert.equal(calls[1].options.method, "PUT");
});

test("returns 911 when Cloudflare API fails", async () => {
  useFetchResponses([
    {
      ok: false,
      status: 403,
      json: async () => ({ success: false, errors: [{ message: "forbidden" }] })
    }
  ]);

  const response = await handler(baseEvent());

  assert.equal(response.statusCode, 500);
  assert.equal(response.body.trim(), "911");
});
