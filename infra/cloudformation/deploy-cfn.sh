#!/usr/bin/env bash
# Deploys the fraud pipeline as a CloudFormation stack (fraud-pipeline.yaml).
#
# Usage (from anywhere):  bash infra/cloudformation/deploy-cfn.sh
# Set STACK_NAME to deploy a second copy (default: fraud-pipeline-cfn). Names of all
# resources are derived from the stack name, so it can run alongside infra/deploy.sh.
#
# Order matters: the API needs a trained model before its tasks can start, so the
# stack is created with 0 tasks, then the image is pushed, the data uploaded and the
# first model trained, and finally the stack is updated to run 1 task (+ auto scaling).
set -euo pipefail
cd "$(dirname "$0")/../.."
. infra/config.sh

STACK="${STACK_NAME:-fraud-pipeline-cfn}"
ARTIFACTS="${STACK}-artifacts-${ACCOUNT_ID}-${AWS_REGION}"
TEMPLATE="infra/cloudformation/fraud-pipeline.yaml"
PACKAGED="$BUILD_DIR/fraud-pipeline.packaged.yaml"

log() { printf '\n==> %s\n' "$*"; }
output() {
    aws cloudformation describe-stacks --stack-name "$STACK" \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" \
    Name=availability-zone,Values="${AWS_REGION}a,${AWS_REGION}b,${AWS_REGION}c" \
    --query 'Subnets[].SubnetId' --output text | tr '\t ' ',,')

deploy_stack() {
    aws cloudformation deploy --stack-name "$STACK" --template-file "$PACKAGED" \
        --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset \
        --parameter-overrides VpcId="$VPC" SubnetIds="$SUBNETS" ArtifactBucket="$ARTIFACTS" \
            DesiredCount="$1"
}

log "Artifact bucket s3://$ARTIFACTS"
if ! aws s3api head-bucket --bucket "$ARTIFACTS" 2>/dev/null; then
    aws s3api create-bucket --bucket "$ARTIFACTS" >/dev/null
    aws s3api put-public-access-block --bucket "$ARTIFACTS" --public-access-block-configuration \
        BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi

log "Packaging the Glue script and Lambda code"
aws cloudformation package --template-file "$TEMPLATE" --s3-bucket "$ARTIFACTS" \
    --output-template-file "$PACKAGED" >/dev/null

# Keep the API running on re-deploys; only a brand-new stack starts at 0 tasks
current=$(aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Parameters[?ParameterKey=='DesiredCount'].ParameterValue" --output text 2>/dev/null || echo 0)
log "Deploying stack $STACK (API tasks: ${current:-0})"
deploy_stack "${current:-0}"

BUCKET=$(output DataBucketName)
REPO=$(output RepositoryUri)
JOB=$(output TrainingJobName)

log "Building and pushing the API image to $REPO"
aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO%%/*}"
docker build --platform linux/amd64 -t "$REPO:latest" starter/fraud_detection_api
docker push "$REPO:latest"

log "Uploading training data"
if ! aws s3api head-object --bucket "$BUCKET" --key data/raw/creditcard.csv >/dev/null 2>&1; then
    aws s3 cp starter/data/creditcard.csv "s3://$BUCKET/data/raw/creditcard.csv" --only-show-errors
fi
aws glue start-crawler --name "${STACK}-raw-data-crawler" 2>/dev/null || true

if ! aws s3api head-object --bucket "$BUCKET" \
        --key models/fraud_detection_model_latest/metadata/_SUCCESS >/dev/null 2>&1; then
    log "Running initial training (takes several minutes)"
    run_id=$(aws glue start-job-run --job-name "$JOB" --query JobRunId --output text)
    while true; do
        state=$(aws glue get-job-run --job-name "$JOB" --run-id "$run_id" --query JobRun.JobRunState --output text)
        case "$state" in
            SUCCEEDED) echo "   $state"; break ;;
            FAILED|ERROR|TIMEOUT|STOPPED)
                aws glue get-job-run --job-name "$JOB" --run-id "$run_id" --query JobRun.ErrorMessage --output text
                exit 1 ;;
            *) echo "   $state..."; sleep 30 ;;
        esac
    done
fi

if [ "${current:-0}" = 0 ]; then
    log "Starting the API (1 task, auto scaling 1-4)"
    deploy_stack 1
fi

log "Done"
echo "   API: $(output ApiUrl)"
