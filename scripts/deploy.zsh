#!/usr/bin/env zsh
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
Usage:
  DDNS_SECRET_NAME=... CLOUDFLARE_SECRET_NAME=... CF_ZONE_ID=... LAMBDA_EXEC_ROLE_ARN=... [AWS_REGION=your-region] [STACK_NAME=your-stack-name] [ALLOWED_HOSTNAMES=your-hostname.example.com] [CF_PROXIED=false] ./scripts/deploy.zsh

Required env vars:
  CF_ZONE_ID               Cloudflare zone ID
  LAMBDA_EXEC_ROLE_ARN     Lambda execution role ARN

Optional env vars:
  AWS_REGION               AWS region (default: from aws config, else us-east-1)
  STACK_NAME               CloudFormation stack name (default: dynamoody)
  SAM_ARTIFACT_BUCKET      Existing S3 bucket for SAM artifacts (default: <stack>-sam-artifacts-<account>-<region>)
  CFN_EXEC_ROLE_ARN        CloudFormation execution role ARN (recommended for least privilege)
  ALLOWED_HOSTNAMES        Comma-separated hostname allow list
  CF_PROXIED               true/false (default: false)
  DDNS_SECRET_NAME         SSM SecureString parameter name containing JSON auth values (default: /dynamoody/dyndns-auth)
  CLOUDFLARE_SECRET_NAME   SSM SecureString parameter name containing the Cloudflare token (default: /dynamoody/cloudflare)
  DDNS_USERNAME            DynDNS username (optional; if provided with DDNS_PASSWORD, JSON parameter is created/updated)
  DDNS_PASSWORD            DynDNS password (optional; if provided with DDNS_USERNAME, JSON parameter is created/updated)
  CF_API_TOKEN             Cloudflare API token (optional; if provided, SSM parameter is created/updated)
  SSM_KMS_KEY_ID           Optional KMS key ID or ARN for SSM SecureString encryption
USAGE
  exit 0
fi

require_env() {
  local name="$1"
  if [[ -z "${(P)name:-}" ]]; then
    echo "Error: required env var '$name' is not set" >&2
    exit 1
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: command '$cmd' not found" >&2
    exit 1
  fi
}

require_cmd aws
require_cmd sam
require_cmd jq

STACK_NAME="${STACK_NAME:-your-stack-name}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SAM_ARTIFACT_BUCKET="${SAM_ARTIFACT_BUCKET:-}"
CFN_EXEC_ROLE_ARN="${CFN_EXEC_ROLE_ARN:-}"
LAMBDA_EXEC_ROLE_ARN="${LAMBDA_EXEC_ROLE_ARN:-}"
ALLOWED_HOSTNAMES="${ALLOWED_HOSTNAMES:-}"
CF_PROXIED="${CF_PROXIED:-false}"
SSM_KMS_KEY_ID="${SSM_KMS_KEY_ID:-}"
DDNS_SECRET_NAME="${DDNS_SECRET_NAME:-/your/ddns/parameter}"
CLOUDFLARE_SECRET_NAME="${CLOUDFLARE_SECRET_NAME:-/your/cloudflare/parameter}"

if [[ -z "$SAM_ARTIFACT_BUCKET" ]]; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  SAM_ARTIFACT_BUCKET="${STACK_NAME}-sam-artifacts-${ACCOUNT_ID}-${AWS_REGION}"
fi

if [[ -z "$LAMBDA_EXEC_ROLE_ARN" ]]; then
  echo "Error: required env var 'LAMBDA_EXEC_ROLE_ARN' is not set" >&2
  exit 1
fi

if [[ -z "$CF_ZONE_ID" ]]; then
  echo "Error: required env var 'CF_ZONE_ID' is not set" >&2
  exit 1
fi

if [[ -z "$STACK_NAME" || "$STACK_NAME" == "your-stack-name" ]]; then
  echo "Error: STACK_NAME must be set to a real stack name" >&2
  exit 1
fi

if [[ "$DDNS_SECRET_NAME" == "/your/ddns/secret" || "$CLOUDFLARE_SECRET_NAME" == "/your/cloudflare/secret" ]]; then
  echo "Error: DDNS_SECRET_NAME and CLOUDFLARE_SECRET_NAME must be set to real secret names" >&2
  exit 1
fi

if [[ "$CF_PROXIED" != "true" && "$CF_PROXIED" != "false" ]]; then
  echo "Error: CF_PROXIED must be 'true' or 'false'" >&2
  exit 1
fi

require_secret() {
  local name="$1"
  if ! aws ssm get-parameter --name "$name" --with-decryption --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "Error: parameter '$name' does not exist in $AWS_REGION" >&2
    exit 1
  fi
}

upsert_parameter() {
  local param_name="$1"
  local param_value="$2"
  local kms_args=()

  if [[ -n "$SSM_KMS_KEY_ID" ]]; then
    kms_args+=(--key-id "$SSM_KMS_KEY_ID")
  fi

  if aws ssm get-parameter --name "$param_name" --with-decryption --region "$AWS_REGION" >/dev/null 2>&1; then
    aws ssm put-parameter --name "$param_name" --value "$param_value" --type SecureString --overwrite --region "$AWS_REGION" "${kms_args[@]}" >/dev/null
  else
    aws ssm put-parameter --name "$param_name" --value "$param_value" --type SecureString --region "$AWS_REGION" "${kms_args[@]}" >/dev/null
  fi
}

if [[ -n "${DDNS_USERNAME:-}" || -n "${DDNS_PASSWORD:-}" ]]; then
  if [[ -z "${DDNS_USERNAME:-}" || -z "${DDNS_PASSWORD:-}" ]]; then
    echo "Error: both DDNS_USERNAME and DDNS_PASSWORD are required when updating the DDNS parameter" >&2
    exit 1
  fi
  DDNS_SECRET_VALUE=$(jq -c -n --arg u "$DDNS_USERNAME" --arg p "$DDNS_PASSWORD" '{username:$u,password:$p}')
  upsert_parameter "$DDNS_SECRET_NAME" "$DDNS_SECRET_VALUE"
else
  require_secret "$DDNS_SECRET_NAME"
fi

if [[ -n "${CF_API_TOKEN:-}" ]]; then
  upsert_parameter "$CLOUDFLARE_SECRET_NAME" "$CF_API_TOKEN"
else
  require_secret "$CLOUDFLARE_SECRET_NAME"
fi

echo "Using SSM SecureString parameters:"
echo "  DDNS parameter: $DDNS_SECRET_NAME"
echo "  Cloudflare parameter: $CLOUDFLARE_SECRET_NAME"

echo "Building SAM application..."
sam build --template-file template.yaml

deploy_args=(
  --template-file .aws-sam/build/template.yaml
  --stack-name "$STACK_NAME"
  --region "$AWS_REGION"
  --capabilities CAPABILITY_IAM
  --no-confirm-changeset
  --no-fail-on-empty-changeset
  --parameter-overrides
    DynDnsAuthParamName="$DDNS_SECRET_NAME"
    CloudflareApiTokenParamName="$CLOUDFLARE_SECRET_NAME"
    CloudflareZoneId="$CF_ZONE_ID"
    AllowedHostnames="$ALLOWED_HOSTNAMES"
    CloudflareProxied="$CF_PROXIED"
)


deploy_args+=(LambdaExecutionRoleArn="$LAMBDA_EXEC_ROLE_ARN")

deploy_args+=(--s3-bucket "$SAM_ARTIFACT_BUCKET")

if [[ -n "$CFN_EXEC_ROLE_ARN" ]]; then
  deploy_args+=(--role-arn "$CFN_EXEC_ROLE_ARN")
fi

echo "Deploying stack '$STACK_NAME'..."
sam deploy "${deploy_args[@]}"

echo "Deployment finished."
aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[?OutputKey==`EndpointUrl`].OutputValue' \
  --output text | sed 's/^/EndpointUrl: /'