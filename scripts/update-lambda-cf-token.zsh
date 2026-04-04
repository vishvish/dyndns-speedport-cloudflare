#!/usr/bin/env zsh
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/update-lambda-cf-token.zsh --function-name NAME [--region REGION] [--token TOKEN | --token-file FILE] [--profile PROFILE]

Updates the Lambda function environment variable `CF_API_TOKEN` safely by
reading the existing environment, merging the new token, and calling
`update-function-configuration` with a JSON payload file.

Examples:
  # run under aws-vault admin
  aws-vault exec admin -- ./scripts/update-lambda-cf-token.zsh \
    --function-name your-function-name \
    --region your-region --token 'NEW_TOKEN'

  # read token from a file
  ./scripts/update-lambda-cf-token.zsh --function-name your-function-name --token-file ./token.txt
USAGE
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Error: $1 required" >&2; exit 1; } }

require_cmd aws
require_cmd jq
require_cmd mktemp

REGION="${AWS_REGION:-}"
PROFILE=""
FUNC=""
TOKEN=""
TOKEN_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --function-name)
      FUNC="$2"; shift 2 ;; 
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

if [[ -z "$FUNC" ]]; then
  echo "Error: --function-name is required" >&2
  usage
  exit 1
fi

if [[ -z "$REGION" ]]; then
  echo "Error: --region is required or AWS_REGION must be set" >&2
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

TMP_CUR=$(mktemp)
TMP_MERGED=$(mktemp)
TMP_PAYLOAD=$(mktemp)
trap 'rm -f "$TMP_CUR" "$TMP_MERGED" "$TMP_PAYLOAD"' EXIT

AWS_OPTS=()
if [[ -n "$PROFILE" ]]; then
  AWS_OPTS+=(--profile "$PROFILE")
fi

# Read existing environment variables
aws lambda get-function-configuration --function-name "$FUNC" --region "$REGION" "${AWS_OPTS[@]}" --query 'Environment.Variables' --output json > "$TMP_CUR" || {
  echo "Failed to read function configuration for $FUNC" >&2
  exit 1
}

# Ensure we have an object to merge into
if [[ ! -s "$TMP_CUR" || "$(cat "$TMP_CUR")" = "null" ]]; then
  echo "{}" > "$TMP_CUR"
fi

# Merge the new token (safe JSON handling)
jq --arg t "$TOKEN" '. + {CF_API_TOKEN:$t}' "$TMP_CUR" > "$TMP_MERGED"

# Wrap as {"Variables": {...}}
jq -n --argfile v "$TMP_MERGED" '{"Variables": $v}' > "$TMP_PAYLOAD"

echo "Updating Lambda function environment..."
aws lambda update-function-configuration --function-name "$FUNC" --region "$REGION" "${AWS_OPTS[@]}" --environment file://"$TMP_PAYLOAD" || {
  echo "Failed to update function configuration" >&2
  exit 1
}

# Verify (show masked token)
NEW=$(aws lambda get-function-configuration --function-name "$FUNC" --region "$REGION" "${AWS_OPTS[@]}" --query 'Environment.Variables.CF_API_TOKEN' --output text || true)
MASK=$(printf '%s' "$NEW" | awk '{ if (length($0)<=8) print "******"; else print substr($0,1,4) "..." substr($0,length($0)-3,4) }')
echo "Updated CF_API_TOKEN: $MASK"

exit 0
