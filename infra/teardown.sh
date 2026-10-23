#!/usr/bin/env bash
# Deletes everything deploy.sh created, including all data and models in the bucket.
#
# Usage (from anywhere):  bash infra/teardown.sh
# Missing resources are skipped, so it is safe to run more than once.
set -uo pipefail
cd "$(dirname "$0")/.."
. infra/config.sh

log() { printf '\n==> %s\n' "$*"; }
quiet() { "$@" >/dev/null 2>&1 || true; }

echo "This deletes the fraud pipeline in account $ACCOUNT_ID ($AWS_REGION), including s3://$BUCKET."
if [ "${CONFIRM:-}" != yes ]; then
    read -r -p "Type 'yes' to continue: " answer
    [ "$answer" = yes ] || { echo "Cancelled"; exit 1; }
fi

log "Monitoring"
quiet aws cloudwatch delete-alarms --alarm-names fraud-refresh-lambda-errors fraud-api-unhealthy-targets \
    fraud-api-5xx-errors fraud-api-high-cpu
quiet aws cloudwatch delete-dashboards --dashboard-names "$DASHBOARD"

log "Retraining trigger and Lambda"
quiet aws s3api put-bucket-notification-configuration --bucket "$BUCKET" --notification-configuration '{}'
quiet aws events remove-targets --rule "$GLUE_EVENT_RULE" --ids refresh-lambda
quiet aws events delete-rule --name "$GLUE_EVENT_RULE"
quiet aws lambda delete-function --function-name "$LAMBDA_NAME"
quiet aws logs delete-log-group --log-group-name "/aws/lambda/$LAMBDA_NAME"

log "Prediction API"
quiet aws application-autoscaling deregister-scalable-target --service-namespace ecs \
    --resource-id "service/$CLUSTER/$SERVICE" --scalable-dimension ecs:service:DesiredCount
if aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
        --query 'services[0].status' --output text 2>/dev/null | grep -q ACTIVE; then
    quiet aws ecs delete-service --cluster "$CLUSTER" --service "$SERVICE" --force
    echo "   waiting for tasks to stop"
    quiet aws ecs wait services-inactive --cluster "$CLUSTER" --services "$SERVICE"
fi
for td in $(aws ecs list-task-definitions --family-prefix "$TASK_FAMILY" --query taskDefinitionArns --output text 2>/dev/null); do
    quiet aws ecs deregister-task-definition --task-definition "$td"
    quiet aws ecs delete-task-definitions --task-definitions "$td"
done
quiet aws ecs delete-cluster --cluster "$CLUSTER"
quiet aws logs delete-log-group --log-group-name "$API_LOG_GROUP"
quiet aws logs delete-log-group --log-group-name "/aws/ecs/containerinsights/$CLUSTER/performance"

alb_arn=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text 2>/dev/null || true)
if [ -n "$alb_arn" ] && [ "$alb_arn" != None ]; then
    quiet aws elbv2 delete-load-balancer --load-balancer-arn "$alb_arn"
    echo "   waiting for the load balancer to be deleted"
    quiet aws elbv2 wait load-balancers-deleted --load-balancer-arns "$alb_arn"
fi
tg_arn=$(aws elbv2 describe-target-groups --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' \
    --output text 2>/dev/null || true)
[ -n "$tg_arn" ] && [ "$tg_arn" != None ] && quiet aws elbv2 delete-target-group --target-group-arn "$tg_arn"

# Security groups can only go once the load balancer's and tasks' network interfaces are released
vpc=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
for sg_name in "$TASK_SG_NAME" "$ALB_SG_NAME"; do
    sg=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$vpc" Name=group-name,Values="$sg_name" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
    [ -z "$sg" ] || [ "$sg" = None ] && continue
    for _ in $(seq 1 18); do
        aws ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1 && { echo "   deleted $sg_name"; break; }
        sleep 10
    done
done
quiet aws ecr delete-repository --repository-name "$ECR_REPO" --force

log "Training job and Data Catalog"
quiet aws glue delete-crawler --name "$GLUE_CRAWLER"
quiet aws glue delete-database --name "$GLUE_DATABASE"
quiet aws glue delete-job --job-name "$GLUE_JOB"

log "S3 bucket (all objects and versions)"
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    while true; do
        aws s3api list-object-versions --bucket "$BUCKET" --max-items 1000 --output json \
            --query '{Objects: [Versions, DeleteMarkers][][].{Key: Key, VersionId: VersionId}}' \
            > "$BUILD_DIR/delete-batch.json"
        grep -q '"Key"' "$BUILD_DIR/delete-batch.json" || break
        aws s3api delete-objects --bucket "$BUCKET" --delete "file://$BUILD_DIR/delete-batch.json" >/dev/null
    done
    quiet aws s3api delete-bucket --bucket "$BUCKET"
fi

log "IAM roles"
for role in "$GLUE_ROLE" "$LAMBDA_ROLE" "$TASK_EXEC_ROLE" "$TASK_ROLE"; do
    aws iam get-role --role-name "$role" >/dev/null 2>&1 || continue
    for arn in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text); do
        quiet aws iam detach-role-policy --role-name "$role" --policy-arn "$arn"
    done
    for name in $(aws iam list-role-policies --role-name "$role" --query PolicyNames --output text); do
        quiet aws iam delete-role-policy --role-name "$role" --policy-name "$name"
    done
    quiet aws iam delete-role --role-name "$role" && echo "   deleted $role"
done

log "Done"
