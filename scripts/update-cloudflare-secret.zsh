#!/usr/bin/env zsh
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/update-cloudflare-secret.zsh [--secret-id SECRET] [--region REGION] [--token TOKEN | --token-file FILE] [--profile PROFILE]

Updates (or creates) the Secrets Manager secret that stores the Cloudflare API
token as JSON: {"apiToken": "..."}.

Examples:
  aws-vault exec admin -- ./scripts/update-cloudflare-secret.zsh --region your-region --secret-id /your/secret/name --token 'NEW_TOKEN'
  ./scripts/update-cloudflare-secret.zsh --region your-region --secret-id /your/secret/name --token-file ./token.txt
USAGE
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Error: $1 required" >&2; exit 1; } }

require_cmd aws
require_cmd jq
require_cmd mktemp

REGION="${AWS_REGION:-}"
PROFILE=""
SECRET_ID=""
TOKEN=""
TOKEN_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --secret-id)
      SECRET_ID="$2"; shift 2 ;; 
    --region)
      REGION="$2"; shift 2 ;; 
    --token)
      TOKEN="$2"; shift 2 ;; 
    --token-file)
      TOKEN_FILE="$2"; shift 2 ;; 
    --profile)
      PROFILE="$2"; shift 2 ;; 
    -h|--help)
      usage; exit 0 ;; 
    *)
      echo "Unknown argument: $1" >&2; usage; exit 1 ;; 
  esac
done

if [[ -z "$REGION" ]]; then
  echo "Error: --region is required or AWS_REGION must be set" >&2
  exit 1
fi

if [[ -z "$SECRET_ID" ]]; then
  echo "Error: --secret-id is required" >&2
  exit 1
fi

if [[ -z "$TOKEN" && -n "$TOKEN_FILE" ]]; then
  if [[ ! -f "$TOKEN_FILE" ]]; then
    echo "Token file not found: $TOKEN_FILE" >&2
    exit 1
  fi
  TOKEN=$(<"$TOKEN_FILE")
fi

if [[ -z "$TOKEN" ]]; then
  echo "Enter token on stdin (end with Ctrl-D) or pass --token/--token-file:" >&2
  TOKEN=$(cat -)
fi

TOKEN=$(printf '%s' "$TOKEN" | tr -d '\r\n')

AWS_OPTS=()
if [[ -n "$PROFILE" ]]; then
  AWS_OPTS+=(--profile "$PROFILE")
fi

PAYLOAD=$(jq -c -n --arg t "$TOKEN" '{apiToken:$t}')

if aws secretsmanager describe-secret --secret-id "$SECRET_ID" --region "$REGION" "${AWS_OPTS[@]}" >/dev/null 2>&1; then
  echo "Updating secret $SECRET_ID..."
  aws secretsmanager put-secret-value --secret-id "$SECRET_ID" --secret-string "$PAYLOAD" --region "$REGION" "${AWS_OPTS[@]}"
else
  echo "Creating secret $SECRET_ID..."
  aws secretsmanager create-secret --name "$SECRET_ID" --secret-string "$PAYLOAD" --region "$REGION" "${AWS_OPTS[@]}"
fi

echo "Secret $SECRET_ID updated."

exit 0
