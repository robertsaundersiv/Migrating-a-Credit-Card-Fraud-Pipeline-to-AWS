# Shared settings for deploy.sh and teardown.sh. Source from the repo root.

# Git Bash on Windows rewrites "/..." arguments into Windows paths; keep them literal
export MSYS_NO_PATHCONV=1
export AWS_PAGER=""

# Load AWS credentials from the API's .env unless they are already in the environment
ENV_FILE="starter/fraud_detection_api/.env"
if [ -z "${AWS_ACCESS_KEY_ID:-}" ] && [ -f "$ENV_FILE" ]; then
    set -a
    . <(tr -d '\r' < "$ENV_FILE" | grep -E '^AWS_[A-Z_]+=.')
    set +a
fi

export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# Storage
BUCKET="fraud-pipeline-${ACCOUNT_ID}-${AWS_REGION}"
RAW_PREFIX="data/raw/"
INCOMING_PREFIX="data/incoming/"
ARCHIVE_PREFIX="data/archive/"
MODEL_PREFIX="models"

# Training
GLUE_JOB="fraud-detection-training"
GLUE_VERSION="5.0"
GLUE_DATABASE="fraud_detection"
GLUE_CRAWLER="fraud-raw-data-crawler"

# Prediction API
ECR_REPO="fraud-detection-api"
CLUSTER="fraud-pipeline"
SERVICE="fraud-detection-api"
TASK_FAMILY="fraud-detection-api"
API_LOG_GROUP="/ecs/fraud-detection-api"
ALB_NAME="fraud-api-alb"
TG_NAME="fraud-api-tg"
ALB_SG_NAME="fraud-api-alb-sg"
TASK_SG_NAME="fraud-api-task-sg"

# Retraining
LAMBDA_NAME="fraud-model-refresh"
GLUE_EVENT_RULE="fraud-training-succeeded"

# Monitoring
DASHBOARD="fraud-pipeline"

# IAM roles
GLUE_ROLE="fraud-glue-training-role"
LAMBDA_ROLE="fraud-refresh-lambda-role"
TASK_EXEC_ROLE="fraud-ecs-task-execution-role"
TASK_ROLE="fraud-ecs-task-role"

# Scratch space for generated JSON and zip files (git-ignored)
BUILD_DIR="infra/.build"
mkdir -p "$BUILD_DIR"
