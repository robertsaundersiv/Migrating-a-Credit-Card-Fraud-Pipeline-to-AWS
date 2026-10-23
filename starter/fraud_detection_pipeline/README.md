# Running the AWS Glue Job
## To run this script on AWS Glue, follow these steps:
- Upload Script to S3: Upload the modified script to an S3 bucket.
- Create an AWS Glue Job:
  - Go to the AWS Glue console.
  - Create a new job and configure it to use the uploaded script.
  - Set the required IAM role that has permissions to access the S3 buckets.
  - Provide the script arguments (JOB_NAME, DATA_URL, MODEL_SAVE_PATH).
- Run the Job:
    - Start the job from the AWS Glue console.
    - Monitor the job execution and logs from the console.
    - Example Script Arguments
        - JOB_NAME: Name of the AWS Glue job.
        - DATA_URL: S3 path to the credit card fraud dataset (e.g., s3://your-bucket/path/to/creditcard.csv).
        - MODEL_SAVE_PATH: S3 path where the model should be saved (e.g., s3://your-bucket/path/to/model).