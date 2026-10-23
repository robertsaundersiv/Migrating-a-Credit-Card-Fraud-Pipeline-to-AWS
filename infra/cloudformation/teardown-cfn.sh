#!/usr/bin/env bash
# Deletes the CloudFormation stack and its buckets, including all data and models.
#
# Usage (from anywhere):  bash infra/cloudformation/teardown-cfn.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
. infra/config.sh

STACK="${STACK_NAME:-fraud-pipeline-cfn}"
DATA_BUCKET="${STACK}-${ACCOUNT_ID}-${AWS_REGION}"
ARTIFACTS="${STACK}-artifacts-${ACCOUNT_ID}-${AWS_REGION}"

echo "This deletes stack $STACK in account $ACCOUNT_ID ($AWS_REGION), including s3://$DATA_BUCKET."
if [ "${CONFIRM:-}" != yes ]; then
    read -r -p "Type 'yes' to continue: " answer
    [ "$answer" = yes ] || { echo "Cancelled"; exit 1; }
fi

# CloudFormation cannot delete a bucket that still holds objects or object versions
empty_bucket() {
    aws s3api head-bucket --bucket "$1" 2>/dev/null || return 0
    echo "   emptying s3://$1"
    while true; do
        aws s3api list-object-versions --bucket "$1" --max-items 1000 --output json \
            --query '{Objects: [Versions, DeleteMarkers][][].{Key: Key, VersionId: VersionId}}' \
            > "$BUILD_DIR/delete-batch.json"
        grep -q '"Key"' "$BUILD_DIR/delete-batch.json" || break
        aws s3api delete-objects --bucket "$1" --delete "file://$BUILD_DIR/delete-batch.json" >/dev/null
    done
}

empty_bucket "$DATA_BUCKET"
echo "Deleting stack $STACK (the load balancer and ECS service take a few minutes)"
aws cloudformation delete-stack --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --stack-name "$STACK" && echo "   stack deleted"

empty_bucket "$ARTIFACTS"
aws s3api delete-bucket --bucket "$ARTIFACTS" 2>/dev/null && echo "   deleted s3://$ARTIFACTS"
echo "Done"
