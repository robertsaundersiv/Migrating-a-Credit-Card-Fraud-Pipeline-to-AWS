import sys
from datetime import datetime, timezone

from awsglue.context import GlueContext
from awsglue.dynamicframe import DynamicFrame, DynamicFrameCollection
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.ml.feature import VectorAssembler, StandardScaler, StringIndexer
from pyspark.ml.classification import RandomForestClassifier
from pyspark.ml import Pipeline
from pyspark.sql.functions import col, when
from pyspark.sql.types import DoubleType, IntegerType


def MyTransform(glueContext, dfc, model_save_path) -> DynamicFrameCollection:
    # Convert DynamicFrameCollection to DataFrame for Glue
    df = dfc.select(list(dfc.keys())[0]).toDF()

    # Class arrives quoted in the CSV; make it numeric so the weight lookup below works
    df = df.withColumn("Class", col("Class").cast(IntegerType()))

    # Convert all columns except 'Class' to DoubleType
    numeric_columns = [col for col in df.columns if col != 'Class']
    for column in numeric_columns:
        df = df.withColumn(column, col(column).cast(DoubleType()))

    # Normalize numeric features
    assembler = VectorAssembler(inputCols=numeric_columns, outputCol="numericFeatures")
    scaler = StandardScaler(inputCol="numericFeatures", outputCol="scaledFeatures", withStd=True, withMean=True)

    # Combine scaled numeric features
    finalAssembler = VectorAssembler(inputCols=["scaledFeatures"], outputCol="features")

    # Handle class imbalance by adjusting class weights
    class_counts = df.groupBy("Class").count().collect()
    total_count = sum([row['count'] for row in class_counts])
    weight_dict = {row['Class']: total_count / row['count'] for row in class_counts}

    # Add class weights to the DataFrame
    df = df.withColumn("weight", when(col("Class") == 0, weight_dict[0]).otherwise(weight_dict[1]))

    # Convert Class to numeric and create class weights
    indexer = StringIndexer(inputCol="Class", outputCol="label")

    # Define the RandomForestClassifier with class weights
    rf = RandomForestClassifier(labelCol="label", featuresCol="features", numTrees=100,
                                maxDepth=10, weightCol="weight")

    # Create a pipeline
    pipeline = Pipeline(stages=[assembler, scaler, finalAssembler, indexer, rf])

    # Fit the model
    model = pipeline.fit(df)

    # Save the model to S3 as "latest" (what the API loads) and as a dated archive copy
    latest_path = f"{model_save_path.rstrip('/')}/fraud_detection_model_latest"
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    archive_path = f"{model_save_path.rstrip('/')}/archive/fraud_detection_model_{timestamp}"
    model.write().overwrite().save(latest_path)
    model.write().overwrite().save(archive_path)

    print(f'Model trained and saved to {latest_path} (archive: {archive_path})')

    # Convert DataFrame back to DynamicFrame and return DynamicFrameCollection for Glue
    trained = DynamicFrame.fromDF(df, glueContext, "trained_data")
    return DynamicFrameCollection({"trained_data": trained}, glueContext)


# Glue job entry point
args = getResolvedOptions(sys.argv, ['JOB_NAME', 'DATA_URL', 'MODEL_SAVE_PATH'])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

# Extract the raw data from S3
raw = glueContext.create_dynamic_frame.from_options(
    connection_type="s3",
    connection_options={"paths": [args['DATA_URL']]},
    format="csv",
    format_options={"withHeader": True},
)

# Run the transformation and training
MyTransform(glueContext, DynamicFrameCollection({"raw_data": raw}, glueContext), args['MODEL_SAVE_PATH'])

job.commit()
