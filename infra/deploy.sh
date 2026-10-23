#!/usr/bin/env bash
# Deploys the fraud detection pipeline to AWS with the AWS CLI.
#
# Usage (from anywhere):  bash infra/deploy.sh [stage ...]
# Stages run in this order by default; pass names to run only some of them:
#   storage iam training catalog image api refresh monitoring
# Every stage checks for existing resources, so re-running is safe.
set -euo pipefail
cd "$(dirname "$0")/.."
. infra/config.sh

log() { printf '\n==> %s\n' "$*"; }

# Retry a command while IAM changes propagate (new roles take a few seconds to be usable)
retry() {
    local n=0
    until "$@"; do
        n=$((n + 1))
        [ "$n" -ge 10 ] && return 1
        echo "   ...retrying in 10s ($n/10)" >&2
        sleep 10
    done
}

role_arn() { echo "arn:aws:iam::${ACCOUNT_ID}:role/$1"; }

trust_policy() {
    cat > "$BUILD_DIR/trust-$1.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow", "Principal": { "Service": "$1" }, "Action": "sts:AssumeRole" }]
}
EOF
    echo "file://$BUILD_DIR/trust-$1.json"
}

ensure_role() {
    local name=$1 service=$2
    if ! aws iam get-role --role-name "$name" >/dev/null 2>&1; then
        aws iam create-role --role-name "$name" \
            --assume-role-policy-document "$(trust_policy "$service")" \
            --description "Fraud pipeline: $3" >/dev/null
        echo "   created role $name"
    fi
}

# ---------------------------------------------------------------- storage
stage_storage() {
    log "S3 bucket s3://$BUCKET"
    if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
        aws s3api create-bucket --bucket "$BUCKET" >/dev/null
    fi
    aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
        BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
    aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
        '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

    log "Uploading training data and Glue script"
    if ! aws s3api head-object --bucket "$BUCKET" --key "${RAW_PREFIX}creditcard.csv" >/dev/null 2>&1; then
        aws s3 cp starter/data/creditcard.csv "s3://$BUCKET/${RAW_PREFIX}creditcard.csv" --only-show-errors
    fi
    aws s3 cp starter/fraud_detection_pipeline/fraud_detector_model_trainer.py \
        "s3://$BUCKET/scripts/fraud_detector_model_trainer.py" --only-show-errors
}

# ---------------------------------------------------------------- iam
stage_iam() {
    log "IAM roles"

    # Glue: run the training job, read data and write models in the project bucket
    ensure_role "$GLUE_ROLE" glue.amazonaws.com "Glue training job and crawler"
    aws iam attach-role-policy --role-name "$GLUE_ROLE" \
        --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole
    # GlueFolderMarkers: overwriting a model makes Glue's S3 connector write "<folder>_$folder$" objects
    cat > "$BUILD_DIR/glue-s3.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::$BUCKET" },
    { "Effect": "Allow", "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::$BUCKET/data/*", "arn:aws:s3:::$BUCKET/scripts/*"] },
    { "Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::$BUCKET/$MODEL_PREFIX/*", "arn:aws:s3:::$BUCKET/glue-temp/*"] },
    { "Sid": "GlueFolderMarkers", "Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::$BUCKET/*_\$folder\$" }
  ]
}
EOF
    aws iam put-role-policy --role-name "$GLUE_ROLE" --policy-name fraud-bucket-access \
        --policy-document "file://$BUILD_DIR/glue-s3.json"

    # Lambda: archive new data, start the Glue job, redeploy the API after training
    ensure_role "$LAMBDA_ROLE" lambda.amazonaws.com "retraining Lambda"
    aws iam attach-role-policy --role-name "$LAMBDA_ROLE" \
        --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    cat > "$BUILD_DIR/lambda-access.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::$BUCKET/${INCOMING_PREFIX}*" },
    { "Effect": "Allow", "Action": ["s3:PutObject"],
      "Resource": "arn:aws:s3:::$BUCKET/${ARCHIVE_PREFIX}*" },
    { "Effect": "Allow", "Action": ["glue:StartJobRun"],
      "Resource": "arn:aws:glue:$AWS_REGION:$ACCOUNT_ID:job/$GLUE_JOB" },
    { "Effect": "Allow", "Action": ["ecs:UpdateService"],
      "Resource": "arn:aws:ecs:$AWS_REGION:$ACCOUNT_ID:service/$CLUSTER/$SERVICE" }
  ]
}
EOF
    aws iam put-role-policy --role-name "$LAMBDA_ROLE" --policy-name fraud-refresh-access \
        --policy-document "file://$BUILD_DIR/lambda-access.json"

    # ECS task execution role: lets ECS pull the image from ECR and write container logs
    ensure_role "$TASK_EXEC_ROLE" ecs-tasks.amazonaws.com "ECS task execution (ECR pull, logs)"
    aws iam attach-role-policy --role-name "$TASK_EXEC_ROLE" \
        --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

    # ECS task role: what the API code itself may do, read-only access to the models
    ensure_role "$TASK_ROLE" ecs-tasks.amazonaws.com "prediction API reads the model from S3"
    cat > "$BUILD_DIR/task-s3.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::$BUCKET",
      "Condition": { "StringLike": { "s3:prefix": "$MODEL_PREFIX/*" } } },
    { "Effect": "Allow", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::$BUCKET/$MODEL_PREFIX/*" }
  ]
}
EOF
    aws iam put-role-policy --role-name "$TASK_ROLE" --policy-name fraud-model-read \
        --policy-document "file://$BUILD_DIR/task-s3.json"

    # New roles take a few seconds before Glue, Lambda and ECS can assume them
    sleep 15
}

# ---------------------------------------------------------------- training
stage_training() {
    log "Glue job $GLUE_JOB"
    aws s3 cp starter/fraud_detection_pipeline/fraud_detector_model_trainer.py \
        "s3://$BUCKET/scripts/fraud_detector_model_trainer.py" --only-show-errors
    cat > "$BUILD_DIR/glue-job.json" <<EOF
{
  "Role": "$(role_arn "$GLUE_ROLE")",
  "Description": "Transforms the credit card data and trains the fraud detection model",
  "Command": { "Name": "glueetl", "PythonVersion": "3",
               "ScriptLocation": "s3://$BUCKET/scripts/fraud_detector_model_trainer.py" },
  "DefaultArguments": {
    "--job-language": "python",
    "--DATA_URL": "s3://$BUCKET/$RAW_PREFIX",
    "--MODEL_SAVE_PATH": "s3://$BUCKET/$MODEL_PREFIX",
    "--TempDir": "s3://$BUCKET/glue-temp/",
    "--enable-metrics": "true",
    "--enable-continuous-cloudwatch-log": "true",
    "--enable-observability-metrics": "true"
  },
  "GlueVersion": "$GLUE_VERSION",
  "WorkerType": "G.1X",
  "NumberOfWorkers": 2,
  "Timeout": 60,
  "ExecutionProperty": { "MaxConcurrentRuns": 1 }
}
EOF
    if aws glue get-job --job-name "$GLUE_JOB" >/dev/null 2>&1; then
        aws glue update-job --job-name "$GLUE_JOB" --job-update "file://$BUILD_DIR/glue-job.json" >/dev/null
    else
        retry aws glue create-job --name "$GLUE_JOB" --cli-input-json "file://$BUILD_DIR/glue-job.json" >/dev/null
    fi

    if aws s3api head-object --bucket "$BUCKET" \
        --key "$MODEL_PREFIX/fraud_detection_model_latest/metadata/_SUCCESS" >/dev/null 2>&1 \
        && [ "${RETRAIN:-0}" != 1 ]; then
        echo "   model already trained (set RETRAIN=1 to train again)"
        return
    fi
    log "Running initial training (takes several minutes)"
    local run_id state
    run_id=$(aws glue start-job-run --job-name "$GLUE_JOB" --query JobRunId --output text)
    echo "   job run $run_id"
    while true; do
        state=$(aws glue get-job-run --job-name "$GLUE_JOB" --run-id "$run_id" --query JobRun.JobRunState --output text)
        case "$state" in
            SUCCEEDED) echo "   $state"; break ;;
            FAILED|ERROR|TIMEOUT|STOPPED)
                aws glue get-job-run --job-name "$GLUE_JOB" --run-id "$run_id" --query JobRun.ErrorMessage --output text
                echo "   training $state"; return 1 ;;
            *) echo "   $state..."; sleep 30 ;;
        esac
    done
}

# ---------------------------------------------------------------- catalog
stage_catalog() {
    log "Glue Data Catalog"
    aws glue get-database --name "$GLUE_DATABASE" >/dev/null 2>&1 \
        || aws glue create-database --database-input "{\"Name\":\"$GLUE_DATABASE\",\"Description\":\"Fraud pipeline datasets\"}"
    if ! aws glue get-crawler --name "$GLUE_CRAWLER" >/dev/null 2>&1; then
        retry aws glue create-crawler --name "$GLUE_CRAWLER" --role "$(role_arn "$GLUE_ROLE")" \
            --database-name "$GLUE_DATABASE" \
            --targets "{\"S3Targets\":[{\"Path\":\"s3://$BUCKET/$RAW_PREFIX\"}]}"
    fi
    aws glue start-crawler --name "$GLUE_CRAWLER" 2>/dev/null || echo "   crawler already running"
}

# ---------------------------------------------------------------- image
stage_image() {
    log "ECR repository and API image"
    aws ecr describe-repositories --repository-names "$ECR_REPO" >/dev/null 2>&1 \
        || aws ecr create-repository --repository-name "$ECR_REPO" \
            --image-scanning-configuration scanOnPush=true \
            --encryption-configuration encryptionType=AES256 >/dev/null
    local registry="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
    aws ecr get-login-password | docker login --username AWS --password-stdin "$registry"
    docker build --platform linux/amd64 -t "$registry/$ECR_REPO:latest" starter/fraud_detection_api
    docker push "$registry/$ECR_REPO:latest"
}

# ---------------------------------------------------------------- api
stage_api() {
    log "Networking"
    local vpc subnets sg_alb sg_task
    vpc=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
    subnets=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$vpc" \
        Name=availability-zone,Values="${AWS_REGION}a,${AWS_REGION}b,${AWS_REGION}c" \
        --query 'Subnets[].SubnetId' --output text)

    sg_alb=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$vpc" Name=group-name,Values="$ALB_SG_NAME" \
        --query 'SecurityGroups[0].GroupId' --output text)
    if [ "$sg_alb" = None ]; then
        sg_alb=$(aws ec2 create-security-group --group-name "$ALB_SG_NAME" --vpc-id "$vpc" \
            --description "Fraud API load balancer: HTTP from the internet" --query GroupId --output text)
        aws ec2 authorize-security-group-ingress --group-id "$sg_alb" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
    fi
    sg_task=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$vpc" Name=group-name,Values="$TASK_SG_NAME" \
        --query 'SecurityGroups[0].GroupId' --output text)
    if [ "$sg_task" = None ]; then
        sg_task=$(aws ec2 create-security-group --group-name "$TASK_SG_NAME" --vpc-id "$vpc" \
            --description "Fraud API tasks: port 8000 from the load balancer only" --query GroupId --output text)
        aws ec2 authorize-security-group-ingress --group-id "$sg_task" --protocol tcp --port 8000 \
            --source-group "$sg_alb" >/dev/null
    fi

    log "Load balancer"
    local alb_arn tg_arn
    alb_arn=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text 2>/dev/null || true)
    if [ -z "$alb_arn" ] || [ "$alb_arn" = None ]; then
        # shellcheck disable=SC2086
        alb_arn=$(aws elbv2 create-load-balancer --name "$ALB_NAME" --type application --scheme internet-facing \
            --subnets $subnets --security-groups "$sg_alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text)
    fi
    tg_arn=$(aws elbv2 describe-target-groups --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' \
        --output text 2>/dev/null || true)
    if [ -z "$tg_arn" ] || [ "$tg_arn" = None ]; then
        tg_arn=$(aws elbv2 create-target-group --name "$TG_NAME" --protocol HTTP --port 8000 --vpc-id "$vpc" \
            --target-type ip --health-check-path /health --health-check-interval-seconds 30 \
            --healthy-threshold-count 2 --unhealthy-threshold-count 3 --matcher HttpCode=200 \
            --query 'TargetGroups[0].TargetGroupArn' --output text)
    fi
    if [ "$(aws elbv2 describe-listeners --load-balancer-arn "$alb_arn" --query 'length(Listeners)')" = 0 ]; then
        aws elbv2 create-listener --load-balancer-arn "$alb_arn" --protocol HTTP --port 80 \
            --default-actions Type=forward,TargetGroupArn="$tg_arn" >/dev/null
    fi

    log "ECS cluster, task definition and service"
    aws logs create-log-group --log-group-name "$API_LOG_GROUP" 2>/dev/null || true
    aws logs put-retention-policy --log-group-name "$API_LOG_GROUP" --retention-in-days 14
    if [ "$(aws ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].status' --output text)" != ACTIVE ]; then
        aws ecs create-cluster --cluster-name "$CLUSTER" --settings name=containerInsights,value=enabled >/dev/null
    fi

    cat > "$BUILD_DIR/task-definition.json" <<EOF
{
  "family": "$TASK_FAMILY",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "4096",
  "runtimePlatform": { "operatingSystemFamily": "LINUX", "cpuArchitecture": "X86_64" },
  "executionRoleArn": "$(role_arn "$TASK_EXEC_ROLE")",
  "taskRoleArn": "$(role_arn "$TASK_ROLE")",
  "containerDefinitions": [{
    "name": "fraud-detection-api",
    "image": "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest",
    "essential": true,
    "portMappings": [{ "containerPort": 8000, "protocol": "tcp" }],
    "environment": [
      { "name": "AWS_REGION", "value": "$AWS_REGION" },
      { "name": "MODEL_S3_BUCKET", "value": "$BUCKET" },
      { "name": "MODEL_S3_PREFIX", "value": "$MODEL_PREFIX/fraud_detection_model_latest" },
      { "name": "LOCAL_MODEL_PATH", "value": "/tmp/fraud_detection_model_latest" }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": { "awslogs-group": "$API_LOG_GROUP", "awslogs-region": "$AWS_REGION",
                   "awslogs-stream-prefix": "api" }
    }
  }]
}
EOF
    local task_def
    task_def=$(retry aws ecs register-task-definition --cli-input-json "file://$BUILD_DIR/task-definition.json" \
        --query 'taskDefinition.taskDefinitionArn' --output text)

    local subnet_list
    subnet_list=$(echo "$subnets" | tr '\t ' ',,')
    if [ "$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
            --query 'services[0].status' --output text 2>/dev/null)" = ACTIVE ]; then
        aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$task_def" \
            --force-new-deployment >/dev/null
    else
        retry aws ecs create-service --cluster "$CLUSTER" --service-name "$SERVICE" \
            --task-definition "$task_def" --desired-count 1 --launch-type FARGATE \
            --network-configuration "awsvpcConfiguration={subnets=[$subnet_list],securityGroups=[$sg_task],assignPublicIp=ENABLED}" \
            --load-balancers "targetGroupArn=$tg_arn,containerName=fraud-detection-api,containerPort=8000" \
            --health-check-grace-period-seconds 300 \
            --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true}" >/dev/null
    fi

    log "Auto scaling (1-4 tasks, target 60% CPU)"
    retry aws application-autoscaling register-scalable-target --service-namespace ecs \
        --resource-id "service/$CLUSTER/$SERVICE" --scalable-dimension ecs:service:DesiredCount \
        --min-capacity 1 --max-capacity 4
    aws application-autoscaling put-scaling-policy --service-namespace ecs \
        --resource-id "service/$CLUSTER/$SERVICE" --scalable-dimension ecs:service:DesiredCount \
        --policy-name fraud-api-cpu-target --policy-type TargetTrackingScaling \
        --target-tracking-scaling-policy-configuration \
        '{"TargetValue":60.0,"PredefinedMetricSpecification":{"PredefinedMetricType":"ECSServiceAverageCPUUtilization"},"ScaleInCooldown":120,"ScaleOutCooldown":60}' >/dev/null

    log "Waiting for the service to become stable (pulls a 1.5 GB image, a few minutes)"
    aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"
    echo "   API: http://$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
        --query 'LoadBalancers[0].DNSName' --output text)"
}

# ---------------------------------------------------------------- refresh
stage_refresh() {
    log "Retraining Lambda $LAMBDA_NAME"
    py -I -c "import zipfile; z = zipfile.ZipFile('$BUILD_DIR/refresh_function.zip', 'w', zipfile.ZIP_DEFLATED); z.write('starter/refresh_function/refresh_function.py', 'refresh_function.py'); z.close()"
    local env_vars="Variables={GLUE_JOB_NAME=$GLUE_JOB,MODEL_SAVE_PATH=s3://$BUCKET/$MODEL_PREFIX,ARCHIVE_PREFIX=$ARCHIVE_PREFIX,ECS_CLUSTER=$CLUSTER,ECS_SERVICE=$SERVICE}"
    if aws lambda get-function --function-name "$LAMBDA_NAME" >/dev/null 2>&1; then
        aws lambda update-function-code --function-name "$LAMBDA_NAME" \
            --zip-file "fileb://$BUILD_DIR/refresh_function.zip" >/dev/null
        aws lambda wait function-updated --function-name "$LAMBDA_NAME"
        aws lambda update-function-configuration --function-name "$LAMBDA_NAME" --environment "$env_vars" >/dev/null
    else
        retry aws lambda create-function --function-name "$LAMBDA_NAME" --runtime python3.14 \
            --handler refresh_function.lambda_handler --role "$(role_arn "$LAMBDA_ROLE")" \
            --zip-file "fileb://$BUILD_DIR/refresh_function.zip" --timeout 120 --memory-size 256 \
            --description "Archives new training data, starts the Glue job, redeploys the API" \
            --environment "$env_vars" >/dev/null
    fi
    aws lambda wait function-active-v2 --function-name "$LAMBDA_NAME"
    local fn_arn
    fn_arn=$(aws lambda get-function --function-name "$LAMBDA_NAME" --query Configuration.FunctionArn --output text)

    log "S3 trigger on s3://$BUCKET/$INCOMING_PREFIX"
    aws lambda add-permission --function-name "$LAMBDA_NAME" --statement-id s3-new-data \
        --action lambda:InvokeFunction --principal s3.amazonaws.com \
        --source-arn "arn:aws:s3:::$BUCKET" --source-account "$ACCOUNT_ID" >/dev/null 2>&1 || true
    cat > "$BUILD_DIR/bucket-notification.json" <<EOF
{
  "LambdaFunctionConfigurations": [{
    "Id": "retrain-on-new-data",
    "LambdaFunctionArn": "$fn_arn",
    "Events": ["s3:ObjectCreated:*"],
    "Filter": { "Key": { "FilterRules": [
      { "Name": "prefix", "Value": "$INCOMING_PREFIX" },
      { "Name": "suffix", "Value": ".csv" }
    ] } }
  }]
}
EOF
    retry aws s3api put-bucket-notification-configuration --bucket "$BUCKET" \
        --notification-configuration "file://$BUILD_DIR/bucket-notification.json"

    log "EventBridge rule: redeploy the API when training succeeds"
    aws events put-rule --name "$GLUE_EVENT_RULE" --state ENABLED \
        --description "Glue training job succeeded: redeploy the API so it loads the new model" \
        --event-pattern "{\"source\":[\"aws.glue\"],\"detail-type\":[\"Glue Job State Change\"],\"detail\":{\"jobName\":[\"$GLUE_JOB\"],\"state\":[\"SUCCEEDED\"]}}" >/dev/null
    aws lambda add-permission --function-name "$LAMBDA_NAME" --statement-id glue-succeeded \
        --action lambda:InvokeFunction --principal events.amazonaws.com \
        --source-arn "arn:aws:events:$AWS_REGION:$ACCOUNT_ID:rule/$GLUE_EVENT_RULE" >/dev/null 2>&1 || true
    aws events put-targets --rule "$GLUE_EVENT_RULE" --targets "Id=refresh-lambda,Arn=$fn_arn" >/dev/null
}

# ---------------------------------------------------------------- monitoring
stage_monitoring() {
    log "CloudWatch alarms and dashboard"
    local alb_dim tg_dim
    alb_dim=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text | sed 's|.*:loadbalancer/||')
    tg_dim=$(aws elbv2 describe-target-groups --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' \
        --output text | sed 's|.*:||')

    aws cloudwatch put-metric-alarm --alarm-name fraud-refresh-lambda-errors \
        --alarm-description "Retraining Lambda failed" --namespace AWS/Lambda --metric-name Errors \
        --dimensions Name=FunctionName,Value="$LAMBDA_NAME" --statistic Sum --period 300 \
        --evaluation-periods 1 --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold \
        --treat-missing-data notBreaching
    aws cloudwatch put-metric-alarm --alarm-name fraud-api-unhealthy-targets \
        --alarm-description "Prediction API has unhealthy tasks behind the load balancer" \
        --namespace AWS/ApplicationELB --metric-name UnHealthyHostCount \
        --dimensions Name=LoadBalancer,Value="$alb_dim" Name=TargetGroup,Value="$tg_dim" \
        --statistic Maximum --period 60 --evaluation-periods 3 --threshold 1 \
        --comparison-operator GreaterThanOrEqualToThreshold --treat-missing-data notBreaching
    aws cloudwatch put-metric-alarm --alarm-name fraud-api-5xx-errors \
        --alarm-description "Prediction API is returning server errors" \
        --namespace AWS/ApplicationELB --metric-name HTTPCode_Target_5XX_Count \
        --dimensions Name=LoadBalancer,Value="$alb_dim" --statistic Sum --period 300 \
        --evaluation-periods 1 --threshold 5 --comparison-operator GreaterThanOrEqualToThreshold \
        --treat-missing-data notBreaching
    aws cloudwatch put-metric-alarm --alarm-name fraud-api-high-cpu \
        --alarm-description "Prediction API CPU is high even after scaling" \
        --namespace AWS/ECS --metric-name CPUUtilization \
        --dimensions Name=ClusterName,Value="$CLUSTER" Name=ServiceName,Value="$SERVICE" \
        --statistic Average --period 300 --evaluation-periods 2 --threshold 85 \
        --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching

    cat > "$BUILD_DIR/dashboard.json" <<EOF
{
  "widgets": [
    { "type": "metric", "x": 0, "y": 0, "width": 12, "height": 6, "properties": {
        "title": "API requests and errors", "region": "$AWS_REGION", "stat": "Sum", "period": 60,
        "metrics": [
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", "$alb_dim"],
          [".", "HTTPCode_Target_4XX_Count", ".", "."],
          [".", "HTTPCode_Target_5XX_Count", ".", "."] ] } },
    { "type": "metric", "x": 12, "y": 0, "width": 12, "height": 6, "properties": {
        "title": "API latency (seconds)", "region": "$AWS_REGION", "period": 60,
        "metrics": [
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", "$alb_dim", { "stat": "Average" }],
          ["...", { "stat": "p99" }] ] } },
    { "type": "metric", "x": 0, "y": 6, "width": 12, "height": 6, "properties": {
        "title": "API tasks: CPU and memory (%)", "region": "$AWS_REGION", "stat": "Average", "period": 60,
        "metrics": [
          ["AWS/ECS", "CPUUtilization", "ClusterName", "$CLUSTER", "ServiceName", "$SERVICE"],
          [".", "MemoryUtilization", ".", ".", ".", "."] ] } },
    { "type": "metric", "x": 12, "y": 6, "width": 12, "height": 6, "properties": {
        "title": "Retraining Lambda", "region": "$AWS_REGION", "stat": "Sum", "period": 300,
        "metrics": [
          ["AWS/Lambda", "Invocations", "FunctionName", "$LAMBDA_NAME"],
          [".", "Errors", ".", "."] ] } },
    { "type": "alarm", "x": 0, "y": 12, "width": 24, "height": 3, "properties": {
        "title": "Alarms",
        "alarms": [
          "arn:aws:cloudwatch:$AWS_REGION:$ACCOUNT_ID:alarm:fraud-refresh-lambda-errors",
          "arn:aws:cloudwatch:$AWS_REGION:$ACCOUNT_ID:alarm:fraud-api-unhealthy-targets",
          "arn:aws:cloudwatch:$AWS_REGION:$ACCOUNT_ID:alarm:fraud-api-5xx-errors",
          "arn:aws:cloudwatch:$AWS_REGION:$ACCOUNT_ID:alarm:fraud-api-high-cpu" ] } }
  ]
}
EOF
    aws cloudwatch put-dashboard --dashboard-name "$DASHBOARD" \
        --dashboard-body "file://$BUILD_DIR/dashboard.json" >/dev/null
}

# ---------------------------------------------------------------- main
STAGES=("$@")
[ ${#STAGES[@]} -eq 0 ] && STAGES=(storage iam training catalog image api refresh monitoring)
echo "Account $ACCOUNT_ID, region $AWS_REGION, stages: ${STAGES[*]}"
for stage in "${STAGES[@]}"; do
    "stage_$stage"
done
log "Done"
