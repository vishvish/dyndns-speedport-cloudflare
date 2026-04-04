#!/usr/bin/env zsh
set -euo pipefail

if [[ ! -f .envrc ]]; then
  echo "Error: .envrc not found in $(pwd)" >&2
  exit 1
fi

# Load the environment variables defined for this project.
# If using direnv, `direnv allow` is recommended before running this script.
source .envrc

if [[ -z "${AWS_REGION:-}" || -z "${STACK_NAME:-}" || -z "${DDNS_SECRET_NAME:-}" || -z "${CLOUDFLARE_SECRET_NAME:-}" ]]; then
  echo "Error: AWS_REGION, STACK_NAME, DDNS_SECRET_NAME, and CLOUDFLARE_SECRET_NAME must be defined in .envrc" >&2
  exit 1
fi

exec ./scripts/bootstrap-iam-user.zsh \
  --region "$AWS_REGION" \
  --stack-name "$STACK_NAME" \
  --ddns-secret-name "$DDNS_SECRET_NAME" \
  --cloudflare-secret-name "$CLOUDFLARE_SECRET_NAME"
