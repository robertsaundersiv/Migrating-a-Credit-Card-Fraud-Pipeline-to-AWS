import os
import shutil
from contextlib import asynccontextmanager

import boto3
from fastapi import FastAPI
from pydantic import BaseModel
from pyspark.sql import SparkSession
from pyspark.ml import PipelineModel


class InputData(BaseModel):
    features: list[float]

# Initialize Spark session
spark = SparkSession.builder.appName("FraudDetectionAPI").getOrCreate()

model = None

# Cloud storage location of the trained model; unset means use the copy bundled in the image
MODEL_S3_BUCKET = os.environ.get('MODEL_S3_BUCKET')
MODEL_S3_PREFIX = os.environ.get('MODEL_S3_PREFIX', 'models/fraud_detection_model_latest')
# Intermediate storage: local folder the model is downloaded to before Spark loads it
LOCAL_MODEL_PATH = os.environ.get('LOCAL_MODEL_PATH', '/tmp/fraud_detection_model_latest')


def download_model(bucket, prefix, local_path):
    # Spark saves a model as a folder of files, so copy every object under the prefix
    shutil.rmtree(local_path, ignore_errors=True)
    s3 = boto3.client('s3')
    prefix = prefix.rstrip('/') + '/'
    for page in s3.get_paginator('list_objects_v2').paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get('Contents', []):
            target = os.path.join(local_path, obj['Key'][len(prefix):])
            os.makedirs(os.path.dirname(target), exist_ok=True)
            s3.download_file(bucket, obj['Key'], target)
    return local_path

@asynccontextmanager
async def lifespan(app: FastAPI):
    global model
    if MODEL_S3_BUCKET:
        model_path = download_model(MODEL_S3_BUCKET, MODEL_S3_PREFIX, LOCAL_MODEL_PATH)
        print(f'Loaded model from s3://{MODEL_S3_BUCKET}/{MODEL_S3_PREFIX}')
    else:
        model_path = 'model/fraud_detection_model_latest'

    # Load the PySpark model
    model = PipelineModel.load(model_path)
    yield

app = FastAPI(lifespan=lifespan)

@app.get('/health')
def health():
    return {'status': 'ok'}

@app.post('/predict/')
def predict(data: InputData):
    # Declaring Feature Columns
    columns = ['Time', 'V1', 'V2', 'V3', 'V4', 'V5', 'V6', 'V7', 'V8', 'V9', 'V10', 'V11', 'V12', 'V13', 'V14', 'V15', 'V16', 'V17', 'V18', 'V19', 'V20', 'V21', 'V22', 'V23', 'V24', 'V25', 'V26', 'V27', 'V28', 'Amount']

    # Create a Spark DataFrame for prediction
    df = spark.createDataFrame([data.features], columns)

    # Make prediction
    predictions = model.transform(df)

    prediction = predictions.select("prediction").collect()[0][0]
    
    return {'prediction': prediction}
