"""
Job 4 — Vehicle / driver profile (single stream: vehicles-raw)

YEARLY aggregation by (year, age_band_of_driver, sex_of_driver, vehicle_type).
(Vehicle CSV has only `Year`, no Date.)
Pattern: stateless stream → batch-aggregate → READ-MERGE-WRITE UPSERT.

Stores `age_of_vehicle_sum` + `age_of_vehicle_count` for weighted-avg recovery.
Dashboard: avg_age = age_of_vehicle_sum::float / NULLIF(age_of_vehicle_count, 0).
"""
import sys
from awsglue.utils import getResolvedOptions
from pyspark.sql.functions import col, count as _count, sum as _sum, when

from common import (
    build_spark, read_kafka_stream, parse_json, get_pg_props, merge_then_upsert,
)
from schemas import VEHICLE_SCHEMA

args = getResolvedOptions(sys.argv, [
    "JOB_NAME", "EH_BOOTSTRAP", "EH_SECRET_ID", "PG_SECRET_ID",
    "S3_OUTPUT_BUCKET", "S3_OUTPUT_PREFIX", "CHECKPOINT_PREFIX",
])

spark = build_spark(args["JOB_NAME"])
_, pg_props = get_pg_props(args["PG_SECRET_ID"])

raw = read_kafka_stream(spark, args["EH_BOOTSTRAP"], args["EH_SECRET_ID"], "vehicles-raw")

events = (parse_json(raw, VEHICLE_SCHEMA)
          .withColumn("year", col("Year").cast("int"))
          .filter(col("year").isNotNull())
          .filter(col("Age_Band_of_Driver").isNotNull()
                  & col("Sex_of_Driver").isNotNull()
                  & col("Vehicle_Type").isNotNull()))


def handle_batch(batch_df, _batch_id):
    if batch_df.rdd.isEmpty():
        return

    # Age_of_Vehicle can be null; track sum and non-null count separately for weighted avg
    age_long = col("Age_of_Vehicle").cast("long")
    batch_agg = (batch_df
                 .groupBy(
                     "year",
                     col("Age_Band_of_Driver").alias("age_band_of_driver"),
                     col("Sex_of_Driver").alias("sex_of_driver"),
                     col("Vehicle_Type").alias("vehicle_type"),
                 )
                 .agg(
                     _count("*").cast("long").alias("vehicle_count"),
                     _sum(when(age_long.isNotNull(), age_long).otherwise(0))
                         .cast("long").alias("age_of_vehicle_sum"),
                     _sum(when(age_long.isNotNull(), 1).otherwise(0))
                         .cast("long").alias("age_of_vehicle_count"),
                 ))

    merge_then_upsert(
        batch_agg, pg_props, "vehicle_profile",
        conflict_keys=["year", "age_band_of_driver", "sex_of_driver", "vehicle_type"],
        sum_cols=["vehicle_count", "age_of_vehicle_sum", "age_of_vehicle_count"],
    )


chk = f"s3://{args['S3_OUTPUT_BUCKET']}/{args['CHECKPOINT_PREFIX']}/vehicle_profile/"

(events.writeStream
    .outputMode("append")
    .foreachBatch(handle_batch)
    .option("checkpointLocation", chk)
    .trigger(processingTime="1 minute")
    .start()
    .awaitTermination())
