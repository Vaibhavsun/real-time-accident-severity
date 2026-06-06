"""
Job 2 — Severity vs environmental conditions (single stream: accident-raw)

DAILY aggregation by (event_date, weather, light, road_surface, speed_limit).
Pattern: stateless stream → batch-aggregate → READ-MERGE-WRITE UPSERT.

Note: stores `severity_sum` (sum of severity scores) and `accident_count`.
Dashboard computes avg_severity = severity_sum::float / accident_count.
"""
import sys
from awsglue.utils import getResolvedOptions
from pyspark.sql.functions import col, when, sum as _sum, count as _count, to_date

from common import (
    build_spark, read_kafka_stream, parse_json, get_pg_props, merge_then_upsert,
)
from schemas import ACCIDENT_SCHEMA

args = getResolvedOptions(sys.argv, [
    "JOB_NAME", "EH_BOOTSTRAP", "EH_SECRET_ID", "PG_SECRET_ID",
    "S3_OUTPUT_BUCKET", "S3_OUTPUT_PREFIX", "CHECKPOINT_PREFIX",
])

spark = build_spark(args["JOB_NAME"])
_, pg_props = get_pg_props(args["PG_SECRET_ID"])

raw = read_kafka_stream(spark, args["EH_BOOTSTRAP"], args["EH_SECRET_ID"], "accident-raw")

severity_score = (when(col("Accident_Severity") == "Fatal", 3)
                  .when(col("Accident_Severity") == "Serious", 2)
                  .otherwise(1))

events = (parse_json(raw, ACCIDENT_SCHEMA)
          .withColumn("event_date", to_date(col("Date"), "yyyy-MM-dd"))
          .filter(col("event_date").isNotNull())
          .withColumn("severity_score", severity_score)
          .filter(col("Weather_Conditions").isNotNull()
                  & col("Light_Conditions").isNotNull()
                  & col("Road_Surface_Conditions").isNotNull()
                  & col("Speed_limit").isNotNull()))


def handle_batch(batch_df, _batch_id):
    if batch_df.rdd.isEmpty():
        return

    batch_agg = (batch_df
                 .groupBy(
                     "event_date",
                     col("Weather_Conditions").alias("weather_conditions"),
                     col("Light_Conditions").alias("light_conditions"),
                     col("Road_Surface_Conditions").alias("road_surface_conditions"),
                     col("Speed_limit").cast("int").alias("speed_limit"),
                 )
                 .agg(
                     _count("*").cast("long").alias("accident_count"),
                     _sum(col("severity_score").cast("long"))
                         .cast("long").alias("severity_sum"),
                     _sum(when(col("Accident_Severity") == "Fatal", 1).otherwise(0))
                         .cast("long").alias("fatal_count"),
                 ))

    merge_then_upsert(
        batch_agg, pg_props, "accident_conditions",
        conflict_keys=[
            "event_date", "weather_conditions", "light_conditions",
            "road_surface_conditions", "speed_limit",
        ],
        sum_cols=["accident_count", "severity_sum", "fatal_count"],
    )


chk = f"s3://{args['S3_OUTPUT_BUCKET']}/{args['CHECKPOINT_PREFIX']}/accident_conditions/"

(events.writeStream
    .outputMode("append")
    .foreachBatch(handle_batch)
    .option("checkpointLocation", chk)
    .trigger(processingTime="1 minute")
    .start()
    .awaitTermination())
