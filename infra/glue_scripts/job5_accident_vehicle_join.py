"""
Job 5 — Extract both streams to separate S3 Parquet files (no join).

accident-raw  → s3://<bucket>/processed/accidents/
vehicles-raw  → s3://<bucket>/processed/vehicles/

train.py reads both folders and joins them in pandas on Accident_Index.
"""
import sys
from awsglue.utils import getResolvedOptions
from pyspark.sql.functions import col

from common import build_spark, read_kafka_stream, parse_json
from schemas import ACCIDENT_SCHEMA, VEHICLE_SCHEMA

args = getResolvedOptions(sys.argv, [
    "JOB_NAME", "EH_BOOTSTRAP", "EH_SECRET_ID",
    "S3_OUTPUT_BUCKET", "S3_OUTPUT_PREFIX", "CHECKPOINT_PREFIX",
])

spark = build_spark(args["JOB_NAME"])

acc_raw = read_kafka_stream(spark, args["EH_BOOTSTRAP"], args["EH_SECRET_ID"], "accident-raw")
veh_raw = read_kafka_stream(spark, args["EH_BOOTSTRAP"], args["EH_SECRET_ID"], "vehicles-raw")

accidents = (parse_json(acc_raw, ACCIDENT_SCHEMA)
             .select(
                 col("Accident_Index"),
                 col("Accident_Severity"),
             ))

vehicles = (parse_json(veh_raw, VEHICLE_SCHEMA)
            .select(
                col("Accident_Index"),
                col("Age_Band_of_Driver"),
                col("Sex_of_Driver"),
                col("Vehicle_Type"),
            ))

acc_path = f"s3://{args['S3_OUTPUT_BUCKET']}/{args['S3_OUTPUT_PREFIX']}/accidents/"
veh_path = f"s3://{args['S3_OUTPUT_BUCKET']}/{args['S3_OUTPUT_PREFIX']}/vehicles/"
acc_chk  = f"s3://{args['S3_OUTPUT_BUCKET']}/{args['CHECKPOINT_PREFIX']}/job5_accidents/"
veh_chk  = f"s3://{args['S3_OUTPUT_BUCKET']}/{args['CHECKPOINT_PREFIX']}/job5_vehicles/"

acc_query = (accidents.writeStream
    .outputMode("append")
    .format("parquet")
    .option("path", acc_path)
    .option("checkpointLocation", acc_chk)
    .trigger(processingTime="1 minute")
    .start())

veh_query = (vehicles.writeStream
    .outputMode("append")
    .format("parquet")
    .option("path", veh_path)
    .option("checkpointLocation", veh_chk)
    .trigger(processingTime="1 minute")
    .start())

spark.streams.awaitAnyTermination()
