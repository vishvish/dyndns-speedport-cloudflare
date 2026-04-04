#!/usr/bin/env zsh
set -euo pipefail

# Usage: ./scripts/bootstrap-lambda-roles.zsh [--stack-name your-stack-name] [--region your-region] [--create-cfn-role]

STACK_NAME="${STACK_NAME:-your-stack-name}"
REGION="${AWS_REGION:-your-region}"
CREATE_CFN_ROLE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-name)
      STACK_NAME="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --create-cfn-role)
      CREATE_CFN_ROLE="true"
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--stack-name name] [--region region] [--create-cfn-role]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
  esac
done

if [[ -z "$STACK_NAME" || "$STACK_NAME" == "your-stack-name" ]]; then
  echo "Error: --stack-name is required or STACK_NAME must be set to a real stack name" >&2
  exit 1
fi

if [[ -z "$REGION" || "$REGION" == "your-region" ]]; then
  echo "Error: --region is required or AWS_REGION must be set to a real region" >&2
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
LAMBDA_ROLE_NAME="${STACK_NAME}-lambda-exec-role"
LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"

cat <<INFO
Creating Lambda execution role:
  Name: $LAMBDA_ROLE_NAME
  Region: $REGION
  Account: $ACCOUNT_ID
INFO

# Trust policy for Lambda
TRUST_FILE=$(mktemp)
cat > "$TRUST_FILE" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

if aws iam get-role --role-name "$LAMBDA_ROLE_NAME" >/dev/null 2>&1; then
  echo "Lambda execution role already exists: $LAMBDA_ROLE_NAME"
else
  aws iam create-role \
    --role-name "$LAMBDA_ROLE_NAME" \
    --assume-role-policy-document "file://$TRUST_FILE" \
    --description "Lambda execution role for $STACK_NAME" \
    >/dev/null
  echo "Created role: $LAMBDA_ROLE_NAME"
fi

rm -f "$TRUST_FILE"

# Attach AWSLambdaBasicExecutionRole managed policy
aws iam attach-role-policy \
  --role-name "$LAMBDA_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
  >/dev/null || true

echo "Attached AWSLambdaBasicExecutionRole policy."

# Inline policy for SecretsManager read
POLICY_FILE=$(mktemp)
cat > "$POLICY_FILE" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "*"
    }
  ]
}
JSON

aws iam put-role-policy \
  --role-name "$LAMBDA_ROLE_NAME" \
  --policy-name "${STACK_NAME}-lambda-secrets-policy" \
  --policy-document "file://$POLICY_FILE" \
  >/dev/null

rm -f "$POLICY_FILE"

echo "Attached inline policy for SecretsManager read."

echo ""
echo "Lambda execution role ARN: $LAMBDA_ROLE_ARN"
echo "Add this to your .envrc:"
echo "  export LAMBDA_EXEC_ROLE_ARN='$LAMBDA_ROLE_ARN'"

echo ""

if [[ "$CREATE_CFN_ROLE" == "true" ]]; then
  CFN_ROLE_NAME="${STACK_NAME}-cfn-exec-role"
  CFN_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${CFN_ROLE_NAME}"
  echo "Creating CloudFormation execution role: $CFN_ROLE_NAME"
  CFN_TRUST_FILE=$(mktemp)
  cat > "$CFN_TRUST_FILE" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "cloudformation.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON
  if aws iam get-role --role-name "$CFN_ROLE_NAME" >/dev/null 2>&1; then
    echo "CloudFormation execution role already exists: $CFN_ROLE_NAME"
  else
    aws iam create-role \
      --role-name "$CFN_ROLE_NAME" \
      --assume-role-policy-document "file://$CFN_TRUST_FILE" \
      --description "CloudFormation execution role for $STACK_NAME" \
      >/dev/null
    echo "Created role: $CFN_ROLE_NAME"
  fi
  rm -f "$CFN_TRUST_FILE"
  echo "CloudFormation execution role ARN: $CFN_ROLE_ARN"
fi

echo "Done."
