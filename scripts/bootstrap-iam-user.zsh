#!/usr/bin/env zsh
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/bootstrap-iam-user.zsh \
    --region your-region \
    [--stack-name your-stack-name] \
    [--user-name your-user-name] \
    [--artifacts-bucket your-artifacts-bucket] \
    [--ddns-secret-name /your/ddns/secret] \
    [--cloudflare-secret-name /your/cloudflare/secret] \
    [--create-access-key]

Creates a least-privilege IAM deploy user for this app:
- IAM user with policy limited to one stack, one artifacts bucket, and two secrets
- CloudFormation execution role restricted to app resources
- Optional access key pair for aws-vault
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

REGION="${REGION:-}"
STACK_NAME="${STACK_NAME:-your-stack-name}"
USER_NAME="${USER_NAME:-your-user-name}"
ARTIFACTS_BUCKET="${ARTIFACTS_BUCKET:-}"
DDNS_SECRET_NAME="${DDNS_SECRET_NAME:-/your/ddns/secret}"
CLOUDFLARE_SECRET_NAME="${CLOUDFLARE_SECRET_NAME:-/your/cloudflare/secret}"
CREATE_ACCESS_KEY="${CREATE_ACCESS_KEY:-false}"

if [[ -z "$REGION" ]]; then
  echo "Error: --region is required" >&2
  exit 1
fi

if [[ "$STACK_NAME" == "your-stack-name" ]]; then
  echo "Error: STACK_NAME must be set to a real stack name" >&2
  exit 1
fi

if [[ "$USER_NAME" == "your-user-name" ]]; then
  echo "Error: USER_NAME must be set to a real user name" >&2
  exit 1
fi

if [[ "$DDNS_SECRET_NAME" == "/your/ddns/secret" || "$CLOUDFLARE_SECRET_NAME" == "/your/cloudflare/secret" ]]; then
  echo "Error: DDNS_SECRET_NAME and CLOUDFLARE_SECRET_NAME must be set to real secret names" >&2
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      REGION="$2"
      shift 2
      ;;
    --stack-name)
      STACK_NAME="$2"
      shift 2
      ;;
    --user-name)
      USER_NAME="$2"
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
    --create-access-key)
      CREATE_ACCESS_KEY="true"
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

if [[ -z "$REGION" ]]; then
  echo "Error: --region is required" >&2
  usage
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
if [[ -z "$ARTIFACTS_BUCKET" ]]; then
  ARTIFACTS_BUCKET="${STACK_NAME}-sam-artifacts-${ACCOUNT_ID}-${REGION}"
fi

CFN_EXEC_ROLE_NAME="${STACK_NAME}-cfn-exec-role"
CFN_EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${CFN_EXEC_ROLE_NAME}"
LAMBDA_EXEC_ROLE_NAME="${STACK_NAME}-lambda-exec-role"
LAMBDA_EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_EXEC_ROLE_NAME}"
USER_POLICY_NAME="${STACK_NAME}-deploy-user-policy"
CFN_ROLE_POLICY_NAME="${STACK_NAME}-cfn-exec-policy"
USER_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${USER_POLICY_NAME}"

STACK_ARN="arn:aws:cloudformation:${REGION}:${ACCOUNT_ID}:stack/${STACK_NAME}/*"
CHANGESET_ARN="arn:aws:cloudformation:${REGION}:${ACCOUNT_ID}:changeSet/*/*"
SAM_TRANSFORM_ARN="arn:aws:cloudformation:${REGION}:aws:transform/Serverless-2016-10-31"
S3_BUCKET_ARN="arn:aws:s3:::${ARTIFACTS_BUCKET}"
S3_OBJECTS_ARN="arn:aws:s3:::${ARTIFACTS_BUCKET}/*"
DDNS_SECRET_ARN_PREFIX="arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:${DDNS_SECRET_NAME}*"
CF_SECRET_ARN_PREFIX="arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:${CLOUDFLARE_SECRET_NAME}*"
LAMBDA_FN_ARN_PREFIX="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${STACK_NAME}*"
LOG_GROUP_ARN_PREFIX="arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/aws/lambda/${STACK_NAME}*"

create_bucket_if_missing() {
  if aws s3api head-bucket --bucket "$ARTIFACTS_BUCKET" >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --region "$REGION" \
      --bucket "$ARTIFACTS_BUCKET" \
      >/dev/null
  else
    aws s3api create-bucket \
      --region "$REGION" \
      --bucket "$ARTIFACTS_BUCKET" \
      --create-bucket-configuration "LocationConstraint=${REGION}" \
      >/dev/null
  fi

  aws s3api put-bucket-versioning \
    --region "$REGION" \
    --bucket "$ARTIFACTS_BUCKET" \
    --versioning-configuration Status=Enabled \
    >/dev/null

  aws s3api put-public-access-block \
    --region "$REGION" \
    --bucket "$ARTIFACTS_BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
    >/dev/null
}

ensure_role() {
  if aws iam get-role --role-name "$CFN_EXEC_ROLE_NAME" >/dev/null 2>&1; then
    return 0
  fi

  local trust_file
  trust_file="$(mktemp)"
  cat > "$trust_file" <<JSON
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

  aws iam create-role \
    --role-name "$CFN_EXEC_ROLE_NAME" \
    --assume-role-policy-document "file://${trust_file}" \
    --description "CloudFormation execution role for ${STACK_NAME}" \
    >/dev/null

  rm -f "$trust_file"
}

ensure_lambda_exec_role() {
  if aws iam get-role --role-name "$LAMBDA_EXEC_ROLE_NAME" >/dev/null 2>&1; then
    return 0
  fi

  local trust_file
  trust_file="$(mktemp)"
  cat > "$trust_file" <<JSON
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

  aws iam create-role \
    --role-name "$LAMBDA_EXEC_ROLE_NAME" \
    --assume-role-policy-document "file://${trust_file}" \
    --description "Lambda execution role for ${STACK_NAME}" \
    >/dev/null

  rm -f "$trust_file"
}

put_cfn_exec_policy() {
  local policy_file
  policy_file="$(mktemp)"
  cat > "$policy_file" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LambdaManagement",
      "Effect": "Allow",
      "Action": [
        "lambda:CreateFunction",
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration",
        "lambda:DeleteFunction",
        "lambda:GetFunction",
        "lambda:TagResource",
        "lambda:UntagResource",
        "lambda:AddPermission",
        "lambda:RemovePermission"
      ],
      "Resource": "${LAMBDA_FN_ARN_PREFIX}"
    },
    {
      "Sid": "ApiGatewayManagement",
      "Effect": "Allow",
      "Action": [
        "apigateway:GET",
        "apigateway:POST",
        "apigateway:PUT",
        "apigateway:PATCH",
        "apigateway:DELETE",
        "apigateway:TagResource"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassLambdaExecutionRole",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole",
        "iam:PassRole"
      ],
      "Resource": "${LAMBDA_EXEC_ROLE_ARN}"
    },
    {
      "Sid": "LogsManagement",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:DeleteLogGroup",
        "logs:PutRetentionPolicy",
        "logs:DeleteRetentionPolicy",
        "logs:TagResource",
        "logs:UntagResource"
      ],
      "Resource": "${LOG_GROUP_ARN_PREFIX}"
    },
    {
      "Sid": "ReadDeploymentSecrets",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": [
        "${DDNS_SECRET_ARN_PREFIX}",
        "${CF_SECRET_ARN_PREFIX}"
      ]
    }
    ,
    {
      "Sid": "SamArtifactsBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "${S3_BUCKET_ARN}"
    },
    {
      "Sid": "SamArtifactsObjects",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": "${S3_OBJECTS_ARN}"
    }
    ,
    {
      "Sid": "CloudFormationSamTransform",
      "Effect": "Allow",
      "Action": "cloudformation:CreateChangeSet",
      "Resource": "*"
    }
  ]
}
JSON

  aws iam put-role-policy \
    --role-name "$CFN_EXEC_ROLE_NAME" \
    --policy-name "$CFN_ROLE_POLICY_NAME" \
    --policy-document "file://${policy_file}" \
    >/dev/null

  rm -f "$policy_file"
}

ensure_lambda_exec_role_policies() {
  aws iam attach-role-policy \
    --role-name "$LAMBDA_EXEC_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" \
    >/dev/null
}

ensure_user() {
  if aws iam get-user --user-name "$USER_NAME" >/dev/null 2>&1; then
    return 0
  fi

  aws iam create-user --user-name "$USER_NAME" >/dev/null
}

put_user_policy() {
  local policy_file
  policy_file="$(mktemp)"
  cat > "$policy_file" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudFormationDeploy",
      "Effect": "Allow",
      "Action": [
        "cloudformation:CreateStack",
        "cloudformation:UpdateStack",
        "cloudformation:DeleteStack",
        "cloudformation:DescribeStacks",
        "cloudformation:DescribeStackEvents",
        "cloudformation:DescribeStackResources",
        "cloudformation:GetTemplate",
        "cloudformation:GetTemplateSummary",
        "cloudformation:CreateChangeSet",
        "cloudformation:DescribeChangeSet",
        "cloudformation:ExecuteChangeSet",
        "cloudformation:DeleteChangeSet"
      ],
      "Resource": [
        "${STACK_ARN}",
        "${CHANGESET_ARN}"
      ]
    },
    {
      "Sid": "CloudFormationReadValidation",
      "Effect": "Allow",
      "Action": [
        "cloudformation:ValidateTemplate",
        "cloudformation:ListStacks"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudFormationSamTransform",
      "Effect": "Allow",
      "Action": "cloudformation:CreateChangeSet",
      "Resource": "*"
    },
    {
      "Sid": "PassCfnExecutionRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "${CFN_EXEC_ROLE_ARN}",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "cloudformation.amazonaws.com"
        }
      }
    },
    {
      "Sid": "SamArtifactsBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "${S3_BUCKET_ARN}"
    },
    {
      "Sid": "SamArtifactsObjects",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": "${S3_OBJECTS_ARN}"
    },
    {
      "Sid": "CreateAppSecrets",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:CreateSecret"
      ],
      "Resource": "*",
      "Condition": {
        "ForAnyValue:StringEquals": {
          "secretsmanager:Name": [
            "${DDNS_SECRET_NAME}",
            "${CLOUDFLARE_SECRET_NAME}"
          ]
        }
      }
    },
    {
      "Sid": "ManageExistingAppSecrets",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:PutSecretValue",
        "secretsmanager:UpdateSecret",
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetSecretValue",
        "secretsmanager:TagResource"
      ],
      "Resource": [
        "${DDNS_SECRET_ARN_PREFIX}",
        "${CF_SECRET_ARN_PREFIX}"
      ]
    }
    ,
    {
      "Sid": "LambdaManagement",
      "Effect": "Allow",
      "Action": [
        "lambda:CreateFunction",
        "lambda:DeleteFunction",
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration",
        "lambda:GetFunction",
        "lambda:TagResource",
        "lambda:UntagResource",
        "lambda:AddPermission",
        "lambda:RemovePermission"
      ],
      "Resource": "${LAMBDA_FN_ARN_PREFIX}"
    },
    {
      "Sid": "PassLambdaExecutionRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "${LAMBDA_EXEC_ROLE_ARN}"
    }
  ]
}
JSON

  if aws iam get-policy --policy-arn "$USER_POLICY_ARN" >/dev/null 2>&1; then
    if ! aws iam create-policy-version \
      --policy-arn "$USER_POLICY_ARN" \
      --policy-document "file://${policy_file}" \
      --set-as-default \
      >/dev/null 2>&1; then
      local oldest_nondefault
      oldest_nondefault="$(
        aws iam list-policy-versions \
          --policy-arn "$USER_POLICY_ARN" \
          --query 'Versions[?IsDefaultVersion==`false`]|sort_by(@,&CreateDate)[0].VersionId' \
          --output text
      )"
      if [[ -n "$oldest_nondefault" && "$oldest_nondefault" != "None" ]]; then
        aws iam delete-policy-version \
          --policy-arn "$USER_POLICY_ARN" \
          --version-id "$oldest_nondefault" \
          >/dev/null
      fi

      aws iam create-policy-version \
        --policy-arn "$USER_POLICY_ARN" \
        --policy-document "file://${policy_file}" \
        --set-as-default \
        >/dev/null
    fi
  else
    aws iam create-policy \
      --policy-name "$USER_POLICY_NAME" \
      --policy-document "file://${policy_file}" \
      >/dev/null
  fi

  aws iam attach-user-policy \
    --user-name "$USER_NAME" \
    --policy-arn "$USER_POLICY_ARN" \
    >/dev/null

  aws iam delete-user-policy \
    --user-name "$USER_NAME" \
    --policy-name "$USER_POLICY_NAME" \
    >/dev/null 2>&1 || true

  rm -f "$policy_file"
}

create_access_key_if_requested() {
  if [[ "$CREATE_ACCESS_KEY" != "true" ]]; then
    return 0
  fi

  local key_json
  key_json="$(aws iam create-access-key --user-name "$USER_NAME")"

  echo
  echo "New access key created for $USER_NAME (save now):"
  echo "$key_json"
}

echo "Ensuring artifacts bucket exists: $ARTIFACTS_BUCKET"
create_bucket_if_missing

echo "Ensuring CloudFormation execution role: $CFN_EXEC_ROLE_NAME"
ensure_role
put_cfn_exec_policy

echo "Ensuring Lambda execution role: $LAMBDA_EXEC_ROLE_NAME"
ensure_lambda_exec_role
ensure_lambda_exec_role_policies

echo "Ensuring IAM user: $USER_NAME"
ensure_user
put_user_policy
create_access_key_if_requested

echo
cat <<SUMMARY
Done.

Use this IAM user with aws-vault profile: $USER_NAME
CloudFormation execution role ARN:
  $CFN_EXEC_ROLE_ARN
Lambda execution role ARN:
  $LAMBDA_EXEC_ROLE_ARN

For deploys, set:
  CFN_EXEC_ROLE_ARN=$CFN_EXEC_ROLE_ARN
  LAMBDA_EXEC_ROLE_ARN=$LAMBDA_EXEC_ROLE_ARN
  SAM_ARTIFACT_BUCKET=$ARTIFACTS_BUCKET

Example:
  aws-vault exec $USER_NAME -- \\
    CFN_EXEC_ROLE_ARN='$CFN_EXEC_ROLE_ARN' \\
    LAMBDA_EXEC_ROLE_ARN='$LAMBDA_EXEC_ROLE_ARN' \\
    SAM_ARTIFACT_BUCKET='$ARTIFACTS_BUCKET' \\
    ./scripts/deploy.zsh
SUMMARY
