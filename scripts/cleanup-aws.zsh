#!/usr/bin/env zsh
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/cleanup-aws.zsh [--region REGION] [--stack-name STACK] [--artifacts-bucket BUCKET]
    [--ddns-secret-name NAME] [--cloudflare-secret-name NAME] [--delete-bucket] [--delete-secrets]
    [--force] [--confirm] [--confirm-force] [--dry-run]

Options:
  --region                 AWS region (default: from aws config, else us-east-1)
  --stack-name             CloudFormation stack name (default: dynamoody)
  --artifacts-bucket       SAM artifacts S3 bucket (default: <stack>-sam-artifacts-<account>-<region>)
  --ddns-secret-name       Secrets Manager name for DynDNS (default: /dynamoody/dyndns-auth)
  --cloudflare-secret-name Secrets Manager name for Cloudflare token (default: /dynamoody/cloudflare)
  --delete-bucket          Remove the SAM artifacts S3 bucket (must be emptyable)
  --delete-secrets         Remove the application secrets from Secrets Manager
  --force                  Also remove IAM roles, policies and the deploy user created by bootstrap (destructive)
  --confirm                Actually perform destructive actions (default: dry-run)
  --confirm-force          Required in addition to --force to remove IAM resources
  --dry-run                Show what would be done (default behavior unless --confirm provided)

Notes:
  - By default the script runs in dry-run mode and will only report planned actions.
  - To actually delete resources pass --confirm. For IAM removal you MUST also pass --confirm-force.
  - The script writes a manifest and log file before making any destructive changes.
USAGE
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Error: command '$cmd' not found" >&2
    exit 1
  }
}

require_cmd aws

# defaults (respect existing env vars if set)
STACK_NAME="${STACK_NAME:-your-stack-name}"
ARTIFACTS_BUCKET="${ARTIFACTS_BUCKET:-}"
DDNS_SECRET_NAME="${DDNS_SECRET_NAME:-/your/ddns/secret}"
CLOUDFLARE_SECRET_NAME="${CLOUDFLARE_SECRET_NAME:-/your/cloudflare/secret}"
DELETE_BUCKET="${DELETE_BUCKET:-false}"
DELETE_SECRETS="${DELETE_SECRETS:-false}"
FORCE="${FORCE:-false}"

# Safety controls
DRY_RUN="true"
CONFIRM="false"
CONFIRM_FORCE="false"

# output files (initialized after argument parsing so CLI overrides are respected)

log() {
  echo "$@" | tee -a "$LOG_FILE"
}

if [[ "$STACK_NAME" == "your-stack-name" ]]; then
  echo "Error: STACK_NAME must be set to a real stack name" >&2
  exit 1
fi

if [[ "$DDNS_SECRET_NAME" == "/your/ddns/secret" || "$CLOUDFLARE_SECRET_NAME" == "/your/cloudflare/secret" ]]; then
  echo "Error: DDNS_SECRET_NAME and CLOUDFLARE_SECRET_NAME must be set to real secret names" >&2
  exit 1
fi

plan_action() {
  # append planned action to manifest (simple JSON array)
  echo "$1" >>"$MANIFEST_FILE.tmp"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      AWS_REGION="$2"
      shift 2
      ;;
    --stack-name)
      STACK_NAME="$2"
      shift 2
      ;;
    --artifacts-bucket)
      ARTIFACTS_BUCKET="$2"
      shift 2
      ;;
    --ddns-secret-name)
      DDNS_SECRET_NAME="$2"
      shift 2
      ;;
    --cloudflare-secret-name)
      CLOUDFLARE_SECRET_NAME="$2"
      shift 2
      ;;
    --delete-bucket)
      DELETE_BUCKET="true"
      shift
      ;;
    --delete-secrets)
      DELETE_SECRETS="true"
      shift
      ;;
    --confirm)
      DRY_RUN="false"
      CONFIRM="true"
      shift
      ;;
    --confirm-force)
      CONFIRM_FORCE="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --force)
      FORCE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

# determine region
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
AWS_REGION="${AWS_REGION:-us-east-1}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

if [[ -z "$ARTIFACTS_BUCKET" ]]; then
  ARTIFACTS_BUCKET="${STACK_NAME}-sam-artifacts-${ACCOUNT_ID}-${AWS_REGION}"
fi

# output files (timestamped, use final STACK_NAME)
TS="$(date -u +%Y%m%dT%H%M%SZ)"
MANIFEST_FILE="./cleanup-manifest-${STACK_NAME}-${TS}.json"
LOG_FILE="./cleanup-log-${STACK_NAME}-${TS}.log"

echo "Region: $AWS_REGION"
echo "Stack: $STACK_NAME"

# prepare manifest/log
echo "Manifest: $MANIFEST_FILE" > "$MANIFEST_FILE" 2>/dev/null || true
echo "[" >"$MANIFEST_FILE.tmp"

log "Region: $AWS_REGION"
log "Stack: $STACK_NAME"

if [[ "$DRY_RUN" == "true" ]]; then
  log "DRY RUN: no destructive actions will be performed. Use --confirm to execute."
else
  log "CONFIRMED: destructive actions will be performed."
fi

# safety: require explicit confirm-force to run IAM deletions
if [[ "$FORCE" == "true" && "$CONFIRM_FORCE" != "true" ]]; then
  log "ERROR: --force requires --confirm-force to proceed with IAM removal. Aborting."
  exit 1
fi

# extra safety: require typing stack name if not dry-run to proceed with deletion
if [[ "$DRY_RUN" != "true" ]]; then
  printf "WARNING: you are about to perform destructive actions on stack '%s' in region '%s'.\n" "$STACK_NAME" "$AWS_REGION" | tee -a "$LOG_FILE"
  echo -n "Type the stack name to confirm: "
  read typed
  if [[ "$typed" != "$STACK_NAME" ]]; then
    log "Confirmation mismatch (typed: $typed). Aborting."
    exit 1
  fi
fi
# Delete CloudFormation stack
if aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$STACK_NAME" >/dev/null 2>&1; then
  echo "Deleting CloudFormation stack $STACK_NAME..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY RUN: would call aws cloudformation delete-stack --region $AWS_REGION --stack-name $STACK_NAME"
    plan_action "{\"action\":\"delete-stack\",\"region\":\"$AWS_REGION\",\"stack\":\"$STACK_NAME\"}"
  else
    aws cloudformation delete-stack --region "$AWS_REGION" --stack-name "$STACK_NAME"
    log "Waiting for stack deletion to complete (this may take a minute)..."
    if ! aws cloudformation wait stack-delete-complete --region "$AWS_REGION" --stack-name "$STACK_NAME"; then
      log "Warning: stack delete waiter failed (check CloudFormation console for details)."
    fi
    log "Stack deletion requested/completed."
    plan_action "{\"action\":\"delete-stack-executed\",\"region\":\"$AWS_REGION\",\"stack\":\"$STACK_NAME\"}"
  fi
else
  echo "No CloudFormation stack named $STACK_NAME found; skipping stack deletion."
fi

# Remove SAM artifacts bucket (optional)
if [[ "$DELETE_BUCKET" == "true" ]]; then
  if aws s3api head-bucket --bucket "$ARTIFACTS_BUCKET" >/dev/null 2>&1; then
    log "Artifacts bucket found: $ARTIFACTS_BUCKET"
    if [[ "$DRY_RUN" == "true" ]]; then
      log "DRY RUN: would empty s3://$ARTIFACTS_BUCKET and then delete the bucket"
      plan_action "{\"action\":\"empty-and-delete-s3-bucket\",\"bucket\":\"$ARTIFACTS_BUCKET\"}"
    else
      log "Emptying S3 bucket: $ARTIFACTS_BUCKET"
      aws s3 rm "s3://$ARTIFACTS_BUCKET" --recursive || log "Warning: some objects may not have been deleted"
      log "Attempting to delete bucket: $ARTIFACTS_BUCKET"
      if ! aws s3api delete-bucket --bucket "$ARTIFACTS_BUCKET" --region "$AWS_REGION"; then
        log "Failed to delete bucket (permission or non-empty). You may need to delete manually."
      else
        log "Bucket deleted: $ARTIFACTS_BUCKET"
      fi
      plan_action "{\"action\":\"s3-bucket-deleted\",\"bucket\":\"$ARTIFACTS_BUCKET\"}"
    fi
  else
    echo "Artifacts bucket $ARTIFACTS_BUCKET does not exist; skipping."
  fi
fi

# Remove Secrets Manager secrets (optional)
if [[ "$DELETE_SECRETS" == "true" ]]; then
  for secret in "$DDNS_SECRET_NAME" "$CLOUDFLARE_SECRET_NAME"; do
    if aws secretsmanager describe-secret --region "$AWS_REGION" --secret-id "$secret" >/dev/null 2>&1; then
      log "Secret exists: $secret"
      if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN: would permanently delete secret: $secret"
        plan_action "{\"action\":\"delete-secret\",\"secret\":\"$secret\"}"
      else
        if ! aws secretsmanager delete-secret --region "$AWS_REGION" --secret-id "$secret" --force-delete-without-recovery; then
          log "Failed to delete secret: $secret (permission or policy)."
        else
          log "Deleted secret: $secret"
        fi
        plan_action "{\"action\":\"delete-secret-executed\",\"secret\":\"$secret\"}"
      fi
    else
      echo "Secret $secret not found; skipping."
    fi
  done
fi

# Dangerous: IAM cleanup only when --force
if [[ "$FORCE" == "true" ]]; then
  log "Performing IAM cleanup (roles, policies, user)."

  CFN_EXEC_ROLE_NAME="${STACK_NAME}-cfn-exec-role"
  CFN_ROLE_POLICY_NAME="${STACK_NAME}-cfn-exec-policy"
  LAMBDA_EXEC_ROLE_NAME="${STACK_NAME}-lambda-exec-role"
  USER_NAME="${STACK_NAME}-deployer"
  USER_POLICY_NAME="${STACK_NAME}-deploy-user-policy"
  USER_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${USER_POLICY_NAME}"

  # CFN exec role
  if aws iam get-role --role-name "$CFN_EXEC_ROLE_NAME" >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == "true" ]]; then
      log "DRY RUN: would remove inline policy $CFN_ROLE_POLICY_NAME and delete role $CFN_EXEC_ROLE_NAME"
      plan_action "{\"action\":\"delete-role\",\"role\":\"$CFN_EXEC_ROLE_NAME\"}"
    else
      aws iam delete-role-policy --role-name "$CFN_EXEC_ROLE_NAME" --policy-name "$CFN_ROLE_POLICY_NAME" >/dev/null 2>&1 || log "Warning: failed to delete inline policy"
      aws iam delete-role --role-name "$CFN_EXEC_ROLE_NAME" >/dev/null 2>&1 || log "Warning: failed to delete role $CFN_EXEC_ROLE_NAME"
      plan_action "{\"action\":\"delete-role-executed\",\"role\":\"$CFN_EXEC_ROLE_NAME\"}"
    fi
  else
    log "CFN exec role not found; skipping: $CFN_EXEC_ROLE_NAME"
  fi

  # Lambda exec role
  if aws iam get-role --role-name "$LAMBDA_EXEC_ROLE_NAME" >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == "true" ]]; then
      log "DRY RUN: would detach policies and delete role $LAMBDA_EXEC_ROLE_NAME"
      plan_action "{\"action\":\"delete-role\",\"role\":\"$LAMBDA_EXEC_ROLE_NAME\"}"
    else
      attached_polices=$(aws iam list-attached-role-policies --role-name "$LAMBDA_EXEC_ROLE_NAME" --query 'AttachedPolicies[].PolicyArn' --output text || true)
      for p in $attached_polices; do
        aws iam detach-role-policy --role-name "$LAMBDA_EXEC_ROLE_NAME" --policy-arn "$p" >/dev/null 2>&1 || true
      done
      inline_policies=$(aws iam list-role-policies --role-name "$LAMBDA_EXEC_ROLE_NAME" --query 'PolicyNames[]' --output text || true)
      for p in $inline_policies; do
        aws iam delete-role-policy --role-name "$LAMBDA_EXEC_ROLE_NAME" --policy-name "$p" >/dev/null 2>&1 || true
      done
      aws iam delete-role --role-name "$LAMBDA_EXEC_ROLE_NAME" >/dev/null 2>&1 || log "Warning: failed to delete role $LAMBDA_EXEC_ROLE_NAME"
      plan_action "{\"action\":\"delete-role-executed\",\"role\":\"$LAMBDA_EXEC_ROLE_NAME\"}"
    fi
  else
    log "Lambda exec role not found; skipping: $LAMBDA_EXEC_ROLE_NAME"
  fi

  # Deploy user
  if aws iam get-user --user-name "$USER_NAME" >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == "true" ]]; then
      log "DRY RUN: would remove access keys, detach policies, and delete user $USER_NAME and policy $USER_POLICY_ARN"
      plan_action "{\"action\":\"delete-user\",\"user\":\"$USER_NAME\"}"
    else
      keys=$(aws iam list-access-keys --user-name "$USER_NAME" --query 'AccessKeyMetadata[].AccessKeyId' --output text || true)
      for k in $keys; do
        aws iam delete-access-key --user-name "$USER_NAME" --access-key-id "$k" >/dev/null 2>&1 || true
      done

      if aws iam get-policy --policy-arn "$USER_POLICY_ARN" >/dev/null 2>&1; then
        aws iam detach-user-policy --user-name "$USER_NAME" --policy-arn "$USER_POLICY_ARN" >/dev/null 2>&1 || true
        versions=$(aws iam list-policy-versions --policy-arn "$USER_POLICY_ARN" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text || true)
        for v in $versions; do
          aws iam delete-policy-version --policy-arn "$USER_POLICY_ARN" --version-id "$v" >/dev/null 2>&1 || true
        done
        aws iam delete-policy --policy-arn "$USER_POLICY_ARN" >/dev/null 2>&1 || true
      fi

      aws iam delete-user-policy --user-name "$USER_NAME" --policy-name "$USER_POLICY_NAME" >/dev/null 2>&1 || true
      aws iam delete-user --user-name "$USER_NAME" >/dev/null 2>&1 || log "Warning: failed to delete user $USER_NAME"
      plan_action "{\"action\":\"delete-user-executed\",\"user\":\"$USER_NAME\"}"
    fi
  else
    log "Deploy user not found; skipping: $USER_NAME"
  fi

  log "IAM cleanup complete."
else
  echo "IAM cleanup skipped. Use --force to remove IAM roles/policies and the deploy user."
fi

echo "," >>"$MANIFEST_FILE.tmp"
cat "$MANIFEST_FILE.tmp" | sed '$ s/,$//' >>"$MANIFEST_FILE"
echo "]" >>"$MANIFEST_FILE"
rm -f "$MANIFEST_FILE.tmp"

log "Cleanup finished. See $MANIFEST_FILE and $LOG_FILE for details."
