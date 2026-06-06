"""
Job 3 — Hotspot leaderboard (single stream: accident-raw)

DAILY aggregation by (event_date, district, road_type, urban_or_rural_area).
Severity-weighted scoring.
Pattern: stateless stream → batch-aggregate → READ-MERGE-WRITE UPSERT.
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

severity_weight = (when(col("Accident_Severity") == "Fatal", 5)
                   .when(col("Accident_Severity") == "Serious", 3)
                   .otherwise(1))

events = (parse_json(raw, ACCIDENT_SCHEMA)
          .withColumn("event_date", to_date(col("Date"), "yyyy-MM-dd"))
          .filter(col("event_date").isNotNull())
          .withColumn("severity_weight", severity_weight)
          .filter(col("Local_Authority_(District)").isNotNull()
                  & col("Road_Type").isNotNull()
                  & col("Urban_or_Rural_Area").isNotNull()))


def handle_batch(batch_df, _batch_id):
    if batch_df.rdd.isEmpty():
        return

    batch_agg = (batch_df
                 .groupBy(
                     "event_date",
                     col("Local_Authority_(District)").alias("local_authority_district"),
                     col("Road_Type").alias("road_type"),
                     col("Urban_or_Rural_Area").alias("urban_or_rural_area"),
                 )
                 .agg(
                     _sum(col("severity_weight").cast("long"))
                         .cast("long").alias("weighted_count"),
                     _count("*").cast("long").alias("accident_count"),
                 ))

    merge_then_upsert(
        batch_agg, pg_props, "accident_hotspots",
        conflict_keys=[
            "event_date", "local_authority_district", "road_type", "urban_or_rural_area",
        ],
        sum_cols=["weighted_count", "accident_count"],
    )


chk = f"s3://{args['S3_OUTPUT_BUCKET']}/{args['CHECKPOINT_PREFIX']}/accident_hotspots/"

(events.writeStream
    .outputMode("append")
    .foreachBatch(handle_batch)
    .option("checkpointLocation", chk)
    .trigger(processingTime="1 minute")
    .start()
    .awaitTermination())
