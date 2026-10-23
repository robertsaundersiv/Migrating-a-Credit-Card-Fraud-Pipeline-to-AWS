# Migrating a Credit Card Fraud Pipeline to AWS

In this project, you will work as a cloud architect at a credit card company. The company's data scientists have developed a fraud detection pipeline on-premises, which includes:

1. A Spark pipeline running on a Hadoop cluster that transforms incoming data and trains the model.
2. A containerized API running on an on-premises server that returns a fraud/no-fraud response.
3. A function or workflow that updates the data used to train the model and triggers model retraining.

Your task is to migrate this pipeline to AWS Cloud, ensuring improved security, scalability, performance, and cost-efficiency. You will use the skills learned in this course to:

1. **Evaluate each workload and select appropriate AWS services** for storage, model training, API deployment, retraining, and monitoring/logging.
2. **Modify the starter source code** so the training job, prediction API, and retraining workflow run with your selected AWS services instead of relying on local-only execution.
3. **Deploy and configure the selected AWS services**, including the IAM roles or service permissions needed for the services to run and interact securely.
4. **Provide evidence that the migrated pipeline works in AWS** by completing the project template with short explanations and screenshots showing the training job, model artifact, running API service, retraining workflow, and IAM/service permission configuration.

## Getting Started

Follow the steps below to make modifications to the code on your local machine:

1. Clone the project repo
2. Make the necessary modifications to the code where "#TODO"s have been provided
3. Upload the appropriate code to your AWS environment
4. Deploy and configure your selected AWS services
5. Complete the project template with your rationale, screenshots, and workflow explanation

### Dependencies

```text
Python 3.14
PySpark 3.3.1
FastAPI 0.89.1
Joblib 1.2.0
Pipenv 2022.10.4
```

### Installation for Local Machine

We highly recommend completing the project work in AWS Cloud9.

1. Clone the repository to your local machine
2. (Optional) Install and create a virtual environment using pipenv
   - ```pip install pipenv```
   - ```pipenv shell```
3. Install the necessary dependencies using pipenv in each project directory
   - ```pipenv install pyspark fastapi joblib```
   - Note: the directories are meant to be standalone pipenv environments, so you can run ```pipenv shell``` in each directory to activate the environment.
4. You can run starter scripts locally while developing using the following command:
   - ```pipenv run python <app_name>.py```

## Project Instructions

Complete the project by migrating the starter fraud detection pipeline to AWS. Your submission must include the modified project code and a completed project template.

<a href="https://video.udacity-data.com/topher/2026/April/69f3095b_migrating_a_credit_card_fraud_template/migrating_a_credit_card_fraud_template.docx" target="_blank">Download the project template from here</a>.

For each workload, complete the following tasks:

⬜ **Select the AWS services for your architecture**

- Choose suitable AWS services for data and model storage, model training, API deployment, retraining or refresh, and monitoring/logging.
- Base your choices on the workload requirements and course content.
- Document each selected service and your rationale in the template.

⬜ **Modify the provided Python scripts**

- Update the starter scripts to work with your selected AWS services (**address all TODOs**).
- Include the training script, API script, retraining or refresh workflow code, and any required deployment files.
- Use AWS-accessible data and model locations for deployed execution.

⬜ **Configure the AWS services and permissions**

- Provision the AWS services needed for your architecture.
- Configure IAM roles, execution roles, task roles, service roles, or service permissions so the services can run and interact securely.
- Do not include AWS secret access keys in your code or submission.

⬜ **Provide evidence in the template**

- Add readable screenshots showing:
  - The model training job or training service completed successfully.
  - The trained model artifact exists in AWS storage or a managed model artifact location.
  - The prediction API service is deployed and running.
  - The retraining workflow ran, logged an invocation, or started the training process.
  - The IAM roles or service permissions used by the architecture. Include all roles or service permissions used, with at least two separate role/service permission examples.
- Add short answers explaining how the final AWS workflow connects the training job, model artifact, API, and retraining process.

### Model Training Job

The development team's model training job uses PySpark to:

- Extract the raw data from the source location
- Transform the data (splitting into train/test, modifying columns for training)
- Load the resulting data into the input folder
- Train the model and output the resulting model in the destination folder

The development team would like an AWS service that satisfies the following requirements:

- Automate as much as possible of the data preparation environment.
- Integrate with other AWS services.
- The team does not have experience managing infrastructure, so they would like to use a fully managed service.
- The model will only be trained monthly, so they do not want to pay for ongoing infrastructure.
- Eventually, they would like to develop a data catalog of all of their existing datasets.

Your evidence should show the training job or service completed successfully and show where the trained model artifact was saved.

### Model Deployment API

Once the model is trained, the development team uses the trained model via a FastAPI service to:

- read the incoming transaction
- process the transaction as fraud or non-fraud
- return the result at the endpoint

The development team would like to deploy their API to an AWS service that:

- Can serve as a container orchestration service without the need to manage servers or Kubernetes clusters.
- Can automatically scale to support an increased load of requests.
- Integrates with CloudWatch and CloudTrail for monitoring and logging.

Your evidence should show the deployed API service running and explain how it accesses the trained model.

### Model Retraining Function

The model retraining function is an event-based function that:

- Monitors for new data in an AWS-accessible source, storage location, database, or event flow.
- Triggers retraining when a new file is added.
- Labels the model as latest and saves it for inference.

They would like an AWS service that:

- Does not require the developers to manage servers.
- Can respond to new data or a scheduled refresh and execute the retraining workflow.
- Is efficient for this infrequent monthly workload.
- Can easily integrate with the service used for the model training job.

Your evidence should show the retraining workflow ran, logged an invocation, or started the training process.

## AWS Architecture

![Architecture diagram: a client calls the API through an Application Load Balancer to ECS Fargate tasks, which load the latest model from S3; a new CSV in S3 triggers a Lambda that starts the Glue training job, and when training succeeds EventBridge invokes the Lambda again to redeploy the API; CloudWatch collects logs and metrics from all of them](docs/architecture.svg)

| Pipeline component | AWS service(s) selected | Why does this service fit the project requirements? |
| --- | --- | --- |
| Data and model storage | Amazon S3 | One durable, low-cost store for the raw dataset, new training data, and every trained model. Glue, Lambda, and ECS all read and write S3 natively. S3 event notifications trigger retraining when a new file lands. Default encryption, blocked public access, versioning, and least-privilege IAM policies keep data secure and earlier models recoverable. |
| Model training job | AWS Glue (Spark ETL job), Glue Data Catalog | Glue runs the existing PySpark code as a fully managed, serverless Spark job, so the team has no cluster to manage. It bills only while the job runs (about 4 minutes per training run here), so a monthly schedule carries no ongoing infrastructure cost. It integrates with S3, Lambda, EventBridge, and CloudWatch. A Glue crawler already catalogs the training data, the first step toward cataloging all of the team's datasets. |
| Prediction API | Amazon ECS on AWS Fargate, Application Load Balancer, Amazon ECR | Fargate runs the FastAPI container without managing servers or a Kubernetes cluster. ECS Service Auto Scaling grows the service from 1 to 4 tasks when average CPU passes 60%, and the load balancer spreads requests across healthy tasks. Container logs go to CloudWatch through the `awslogs` driver, and CloudTrail can record ECS API activity. An ECS task role gives the container read-only access to the model in S3, so no credentials are stored in the image. |
| Retraining or refresh workflow | AWS Lambda (S3 trigger), Amazon EventBridge | Lambda is serverless and charges per invocation, so it costs almost nothing for a monthly workload. A new `.csv` in `data/incoming/` invokes it automatically. It archives the file and starts the Glue job through the Glue API. When training succeeds, an EventBridge rule invokes the function again to redeploy the API, so the new "latest" model goes into service with no manual steps. |
| Monitoring or logs | Amazon CloudWatch (Logs, Metrics, Alarms, Dashboard, Container Insights), AWS CloudTrail | CloudWatch collects logs and metrics from Glue runs, Lambda invocations, and the ECS service in one place. Alarms flag Lambda errors, unhealthy API tasks, server errors, and sustained high CPU, and a dashboard shows API traffic, latency, and task load. CloudTrail provides the audit trail of AWS API calls, such as who started a training job or changed an IAM role. It is part of the design but blocked in the Udacity lab account. |

```text
s3://<bucket>/
├── data/raw/            training data (Glue job input, cataloged by the crawler)
├── data/incoming/       drop new data here: triggers retraining
├── data/archive/        processed files, renamed <name>_retrain_<date>.csv
├── models/fraud_detection_model_latest/   model the API loads
├── models/archive/      dated copy of every trained model
└── scripts/             Glue job script
```

How the pieces connect:

1. The Glue job reads the CSV from S3, trains the Spark pipeline, and saves it as `models/fraud_detection_model_latest` plus a dated archive copy.
2. At startup, the API container downloads the latest model from S3 to `/tmp` and loads it with Spark. The ECS task role grants read-only access to `models/`.
3. A new `.csv` in `data/incoming/` triggers the Lambda, which moves it to `data/archive/` and starts the Glue job on it.
4. When the Glue job succeeds, EventBridge invokes the same Lambda, which forces a new ECS deployment so the API loads the new model.

IAM roles: `fraud-glue-training-role` (Glue), `fraud-refresh-lambda-role` (Lambda), `fraud-ecs-task-execution-role` (ECS pulls the image and writes logs), `fraud-ecs-task-role` (API reads the model).

### Deploying

Requires the AWS CLI, Docker, and Python. Put credentials in `starter/fraud_detection_api/.env` (see `.env.example`), and the dataset at `starter/data/creditcard.csv` ([Kaggle](https://www.kaggle.com/datasets/mlg-ulb/creditcardfraud)).

```bash
bash infra/deploy.sh                 # everything
bash infra/deploy.sh api monitoring  # or only some stages
bash infra/teardown.sh               # delete everything, including the bucket
```

Stages: `storage iam training catalog image api refresh monitoring`. Each one skips resources that already exist, so a stage can be re-run after an error or expired credentials.

### Deploying with CloudFormation

[`infra/cloudformation/fraud-pipeline.yaml`](infra/cloudformation/fraud-pipeline.yaml) defines the same architecture as infrastructure as code: the bucket, IAM roles, Glue job, crawler and database, ECR repository, ECS cluster and service, load balancer, auto scaling, Lambda with its S3 and EventBridge triggers, and the CloudWatch alarms and dashboard. Resource names come from the stack name, so a stack can run alongside the CLI deployment.

```bash
bash infra/cloudformation/deploy-cfn.sh     # STACK_NAME defaults to fraud-pipeline-cfn
bash infra/cloudformation/teardown-cfn.sh   # empties the buckets, then deletes the stack
```

The script packages the Glue script and Lambda code with `aws cloudformation package`, creates the stack with 0 API tasks, pushes the image, uploads the data, runs the first training job, and then updates the stack to 1 task. The API cannot start until a model exists, so this order keeps the first deployment from failing.

### Code changes

Every local-only path in the starter code was replaced with an S3 location for deployed execution. Bucket names and paths are passed in as job arguments or environment variables, not hard-coded.

| File | Submitted? | What changed? |
| --- | --- | --- |
| `starter/fraud_detection_pipeline/fraud_detector_model_trainer.py` | Yes | Converted to an AWS Glue job. The local `SparkSession` and `__main__` block were replaced by a Glue entry point (`GlueContext`, `Job`) that reads `JOB_NAME`, `DATA_URL`, and `MODEL_SAVE_PATH` with `getResolvedOptions`. The local input file `../data/credit_card_transaction_data_labeled.csv` became an S3 path, read as a DynamicFrame. `MyTransform` now takes a `DynamicFrameCollection`, converts it to a DataFrame for training, and returns a `DynamicFrameCollection`. The local save path `../fraud_detection_api/model/...` was replaced by S3: the model is saved as `models/fraud_detection_model_latest` (what the API loads) plus a dated copy in `models/archive/`. `Class` is cast to an integer because the CSV quotes it. The `try/except` that printed and swallowed errors was removed, so a failed run shows as Failed in Glue and CloudWatch. |
| `starter/fraud_detection_api/main.py` | Yes | The local model path `model/fraud_detection_model_latest` was replaced by a download from S3 (`MODEL_S3_BUCKET`, `MODEL_S3_PREFIX`) to an intermediate local folder (`LOCAL_MODEL_PATH`, default `/tmp`), because Spark loads a saved model from a filesystem path. AWS credentials come from the ECS task role, not from code. The copy bundled in the image is used only when no bucket is set, for local development. Startup moved from the deprecated `@app.on_event('startup')` to a FastAPI `lifespan` handler. A `GET /health` endpoint was added for load balancer health checks, and an unused import was removed. |
| `starter/refresh_function/refresh_function.py` | Yes | Rewritten as an AWS Lambda handler. The infinite loop polling a local folder (`/Users/jonathandyer/...`) every 10 seconds was replaced by an S3 `ObjectCreated` trigger on `data/incoming/`. The local `os.rename` became an S3 copy-and-delete into `data/archive/`, keeping the `<name>_retrain_<date>.csv` naming. Training no longer runs inside the function: Lambda cannot run Spark, so the function starts the Glue job through boto3 (`start_job_run`) on the archived file. A second trigger, an EventBridge rule for "Glue job succeeded", makes the same function force a new ECS deployment so the API loads the new model. The function's nested copy of the training code was removed because it is no longer imported, and its `Pipfile` now lists only `boto3`. |
| Deployment files | Yes | **`fraud_detection_api/Dockerfile`:** the base image changed from the retired `apache/spark-py:v3.3.1` (Python 3.8) to `python:3.14-slim` with Java 21, which current PySpark needs. **`fraud_detection_api/requirements.txt`:** recreated with pinned versions and `boto3` added for S3 access. **`fraud_detection_api/.dockerignore`:** new; keeps `.env` and other local files out of the image. **`fraud_detection_api/.env.example`:** new; documents the S3 and region settings, with credential slots for local development only. **`infra/config.sh`, `infra/deploy.sh`, `infra/teardown.sh`:** new; AWS CLI scripts that create, and delete, the S3 bucket, IAM roles, Glue job and crawler, ECR repository, ECS service, load balancer, auto scaling, Lambda triggers, and CloudWatch alarms and dashboard. **`infra/cloudformation/`:** new; the same architecture as a CloudFormation template, with deploy and teardown scripts. **`docs/architecture.svg`, `docs/architecture.png`:** new; architecture diagram. **`.gitignore`:** keeps the 144 MB dataset, `.env`, and build files out of git. **`README.md`:** architecture, deployment, and change notes (this section). |

## License

[License](../LICENSE.txt)
