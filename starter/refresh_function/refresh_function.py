import os
import datetime
import urllib.parse

import boto3

# Initiate the AWS SDK clients
s3 = boto3.client('s3')
glue = boto3.client('glue')
ecs = boto3.client('ecs')

GLUE_JOB_NAME = os.environ['GLUE_JOB_NAME']
MODEL_SAVE_PATH = os.environ['MODEL_SAVE_PATH']
ARCHIVE_PREFIX = os.environ.get('ARCHIVE_PREFIX', 'data/archive/')
ECS_CLUSTER = os.environ.get('ECS_CLUSTER')
ECS_SERVICE = os.environ.get('ECS_SERVICE')


def retrain_on_new_data(event):
    # Triggered by an S3 ObjectCreated event when new data lands in the incoming prefix
    run_ids = []
    for record in event.get('Records', []):
        bucket = record['s3']['bucket']['name']
        key = urllib.parse.unquote_plus(record['s3']['object']['key'])
        file = os.path.basename(key)
        if not file.endswith('.csv') or 'retrain' in file:
            print(f"Skipping {key}")
            continue
        print(f"New data detected: s3://{bucket}/{key}")

        # Move the file to the archive prefix, labeled with the retrain date
        current_date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d")
        retrain_key = f"{ARCHIVE_PREFIX}{os.path.splitext(file)[0]}_retrain_{current_date}.csv"
        s3.copy_object(Bucket=bucket, Key=retrain_key, CopySource={'Bucket': bucket, 'Key': key})
        s3.delete_object(Bucket=bucket, Key=key)
        print(f"Moved processed file to: s3://{bucket}/{retrain_key}")

        # Kick off the Glue training job on the archived file
        run = glue.start_job_run(
            JobName=GLUE_JOB_NAME,
            Arguments={
                '--DATA_URL': f"s3://{bucket}/{retrain_key}",
                '--MODEL_SAVE_PATH': MODEL_SAVE_PATH,
            },
        )
        print(f"Started Glue job {GLUE_JOB_NAME}: {run['JobRunId']}")
        run_ids.append(run['JobRunId'])
    return {'started_job_runs': run_ids}


def redeploy_api(event):
    # Triggered by EventBridge when the Glue job finishes; restart the API so it loads the new model
    detail = event['detail']
    if detail.get('jobName') != GLUE_JOB_NAME or detail.get('state') != 'SUCCEEDED':
        print(f"Ignoring Glue event: {detail.get('jobName')} {detail.get('state')}")
        return {'redeployed': False}
    try:
        ecs.update_service(cluster=ECS_CLUSTER, service=ECS_SERVICE, forceNewDeployment=True)
    except (ecs.exceptions.ClusterNotFoundException, ecs.exceptions.ServiceNotFoundException):
        # Nothing to redeploy yet: the API's first deployment loads the latest model itself
        print(f"API service {ECS_CLUSTER}/{ECS_SERVICE} does not exist yet; skipping redeploy")
        return {'redeployed': False}
    print(f"Glue run {detail.get('jobRunId')} succeeded; redeploying {ECS_SERVICE} to load the new model")
    return {'redeployed': True}


def lambda_handler(event, context):
    if event.get('source') == 'aws.glue':
        return redeploy_api(event)
    return retrain_on_new_data(event)
