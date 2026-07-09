#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Bootstrap the Terraform REMOTE STATE backend.
#
# Creates the S3 bucket (versioned, encrypted, private) and the DynamoDB table
# that Terraform uses to store and lock its state. Run this ONCE per account
# before the first `terraform init`. It's safe to re-run (idempotent).
#
# Usage:
#   TF_STATE_BUCKET=myname-devops-workshop-tfstate ./scripts/bootstrap-backend.sh
#
# Optional env:
#   AWS_REGION      (default: eu-west-1)
#   TF_LOCK_TABLE   (default: devops-workshop-tf-locks)
# -----------------------------------------------------------------------------
set -euo pipefail

REGION="${AWS_REGION:-eu-west-1}"
BUCKET="${TF_STATE_BUCKET:?Set TF_STATE_BUCKET, e.g. myname-devops-workshop-tfstate}"
TABLE="${TF_LOCK_TABLE:-devops-workshop-tf-locks}"

echo "==> State bucket: $BUCKET   region: $REGION   lock table: $TABLE"

# --- S3 bucket ---------------------------------------------------------------
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "    bucket already exists"
elif [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
fi

aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# --- DynamoDB lock table -----------------------------------------------------
if aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" >/dev/null 2>&1; then
  echo "    lock table already exists"
else
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" >/dev/null
  echo "    lock table created"
fi

cat <<EOF

==> Backend ready. Initialize Terraform with:

    cd terraform
    terraform init \\
      -backend-config="bucket=$BUCKET" \\
      -backend-config="dynamodb_table=$TABLE" \\
      -backend-config="region=$REGION" \\
      -backend-config="key=devops-workshop/terraform.tfstate"

In CI, set repo VARIABLES: TF_STATE_BUCKET=$BUCKET, TF_LOCK_TABLE=$TABLE
EOF
