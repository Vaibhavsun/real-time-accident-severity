"""
Job 1 — Accident KPI + Geo grid (single stream: accident-raw)

DAILY aggregation by (event_date, lat_grid, lon_grid).
Pattern: stateless stream → batch-aggregate in foreachBatch → READ-MERGE-WRITE UPSERT.
"""
import sys
from awsglue.utils import getResolvedOptions
from pyspark.sql.functions import (
    col, round as spark_round, when, sum as _sum, count as _count, to_date,
)

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

# Enrich raw events with dimensions — NO streaming aggregation here.
events = (parse_json(raw, ACCIDENT_SCHEMA)
          .withColumn("event_date", to_date(col("Date"), "yyyy-MM-dd"))
          .filter(col("event_date").isNotNull())
          .withColumn("lat_grid", spark_round(col("Latitude").cast("double"), 1))
          .withColumn("lon_grid", spark_round(col("Longitude").cast("double"), 1))
          .filter(col("lat_grid").isNotNull() & col("lon_grid").isNotNull()))


def handle_batch(batch_df, batch_id):
    if batch_df.rdd.isEmpty():
        return

    # 1. Aggregate batch (Spark batch-mode groupBy, no streaming state)
    batch_agg = (batch_df
                 .groupBy("event_date", "lat_grid", "lon_grid")
                 .agg(
                     _count("*").cast("long").alias("accident_count"),
                     _sum(when(col("Accident_Severity") == "Fatal", 1).otherwise(0))
                         .cast("long").alias("fatal_count"),
                     _sum(when(col("Accident_Severity") == "Serious", 1).otherwise(0))
                         .cast("long").alias("serious_count"),
                     _sum(when(col("Accident_Severity") == "Slight", 1).otherwise(0))
                         .cast("long").alias("slight_count"),
                     _sum(col("Number_of_Casualties").cast("long"))
                         .cast("long").alias("total_casualties"),
                     _sum(col("Number_of_Vehicles").cast("long"))
                         .cast("long").alias("total_vehicles"),
                 ))

    # 2-4. Read PG → merge → UPSERT
    merge_then_upsert(
        batch_agg, pg_props, "accident_kpi_geo",
        conflict_keys=["event_date", "lat_grid", "lon_grid"],
        sum_cols=[
            "accident_count", "fatal_count", "serious_count", "slight_count",
            "total_casualties", "total_vehicles",
        ],
    )


chk = f"s3://{args['S3_OUTPUT_BUCKET']}/{args['CHECKPOINT_PREFIX']}/accident_kpi_geo/"

(events.writeStream
    .outputMode("append")
    .foreachBatch(handle_batch)
    .option("checkpointLocation", chk)
    .trigger(processingTime="1 minute")
    .start()
    .awaitTermination())
