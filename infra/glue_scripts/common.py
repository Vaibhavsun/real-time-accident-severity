"""
Shared helpers for all Glue Streaming jobs.

Pattern: STATELESS Spark + READ-MERGE-WRITE UPSERT.
  1. Spark stream passes raw enriched events to foreachBatch (no windowed agg).
  2. foreachBatch aggregates current batch in Spark.
  3. Read existing PG rows matching batch's keys.
  4. Sum batch + existing per key (in memory).
  5. UPSERT merged result back to PG.

Why this pattern:
  - Each batch independent — no Spark state to corrupt
  - PG is single source of truth for accumulated state
  - Resilient to checkpoint loss (PG state survives)
  - Caveat: Spark at-least-once → on retry, same batch added twice
    (rare; acceptable for prototype). For exact-once add batch_id tracking.

Job parameters (passed by Glue TF):
  --JOB_NAME
  --EH_BOOTSTRAP, --EH_SECRET_ID
  --PG_SECRET_ID
  --S3_OUTPUT_BUCKET, --S3_OUTPUT_PREFIX  (used only by job5 for archive)
  --CHECKPOINT_PREFIX
"""
import json
import boto3
import psycopg2
import psycopg2.extras
from pyspark.sql import SparkSession
from pyspark.sql.functions import col, from_json, current_timestamp
from pyspark.sql.types import StructType, StructField, StringType, LongType


def get_secret(secret_id: str) -> str:
    client = boto3.client("secretsmanager")
    return client.get_secret_value(SecretId=secret_id)["SecretString"]


def get_pg_props(pg_secret_id: str):
    raw = get_secret(pg_secret_id)
    s = json.loads(raw)
    jdbc_url = f"jdbc:postgresql://{s['host']}:{s.get('port', 5432)}/{s['db']}"
    props = {
        "user": s["user"],
        "password": s["password"],
        "driver": "org.postgresql.Driver",
        "host": s["host"],
        "port": s.get("port", 5432),
        "db": s["db"],
    }
    return jdbc_url, props


def build_spark(app_name: str) -> SparkSession:
    return (
        SparkSession.builder.appName(app_name)
        .config("spark.sql.session.timeZone", "UTC")
        .getOrCreate()
    )


def read_kafka_stream(spark: SparkSession, bootstrap: str, eh_secret_id: str, topic: str):
    eh_conn = get_secret(eh_secret_id)
    jaas = (
        'org.apache.kafka.common.security.plain.PlainLoginModule required '
        f'username="$ConnectionString" password="{eh_conn}";'
    )
    return (
        spark.readStream.format("kafka")
        .option("kafka.bootstrap.servers", bootstrap)
        .option("subscribe", topic)
        .option("kafka.security.protocol", "SASL_SSL")
        .option("kafka.sasl.mechanism", "PLAIN")
        .option("kafka.sasl.jaas.config", jaas)
        .option("startingOffsets", "latest")
        .option("failOnDataLoss", "false")
        # Cap each microbatch — prevents death-spiral on backlog or producer spikes.
        # With producer at ~100 msg/s, normal per-min volume ~6K — 10K gives 1.5× headroom.
        .option("maxOffsetsPerTrigger", 10000)
        .load()
    )


def parse_json(kafka_df, payload_schema):
    """Producer envelope: {seq, stream, event_time, ingest_time, payload: {<csv row>}}."""
    wrapper = StructType([
        StructField("seq", LongType()),
        StructField("stream", StringType()),
        StructField("event_time", StringType()),
        StructField("ingest_time", StringType()),
        StructField("payload", payload_schema),
    ])
    return (
        kafka_df.selectExpr("CAST(value AS STRING) AS json_str", "timestamp AS kafka_ts")
        .select(from_json(col("json_str"), wrapper).alias("d"), col("kafka_ts"))
        .select("d.payload.*", col("d.event_time").alias("event_time_str"), "kafka_ts")
        .withColumn("processing_time", current_timestamp())
    )


def merge_then_upsert(batch_agg_df, pg_props, table, conflict_keys, sum_cols):
    """
    READ-MERGE-WRITE UPSERT.

    Steps:
      1. Collect pre-aggregated batch DataFrame.
      2. Read PG rows matching batch's conflict_keys.
      3. For each batch row: merged_value = batch_value + existing_value (per sum_col).
      4. UPSERT merged rows (ON CONFLICT DO UPDATE — overwrite with merged values).

    Args:
        batch_agg_df : Spark DataFrame already grouped by conflict_keys with sum_cols computed
        pg_props     : dict with host/port/db/user/password
        table        : Postgres table name
        conflict_keys: list of column names defining row identity (must match table UNIQUE constraint)
        sum_cols     : list of column names that are additive (counts, sums)

    Skipped: rows where any conflict_key is NULL (PG would treat NULL!=NULL anyway).
    """
    batch_rows = [r.asDict() for r in batch_agg_df.collect()
                  if all(r[k] is not None for k in conflict_keys)]
    if not batch_rows:
        return

    # Chunk the IN-clause SELECT — Postgres parser stack overflows for thousands
    # of key tuples in one query. 200 keys/chunk is a safe ceiling.
    CHUNK = 200

    conn = psycopg2.connect(
        host=pg_props["host"],
        port=pg_props["port"],
        dbname=pg_props["db"],
        user=pg_props["user"],
        password=pg_props["password"],
        connect_timeout=10,
    )
    try:
        with conn.cursor() as cur:
            # === Step 2: Read existing PG rows (chunked) ===
            keys_select = ", ".join(conflict_keys)
            value_tuple = "(" + ", ".join(["%s"] * len(conflict_keys)) + ")"
            select_cols = conflict_keys + sum_cols

            existing_dict = {}
            for i in range(0, len(batch_rows), CHUNK):
                chunk = batch_rows[i:i + CHUNK]
                in_clause = ", ".join([value_tuple] * len(chunk))
                flat_keys = [r[k] for r in chunk for k in conflict_keys]
                cur.execute(
                    f"SELECT {', '.join(select_cols)} FROM {table} "
                    f"WHERE ({keys_select}) IN ({in_clause})",
                    flat_keys,
                )
                for row in cur.fetchall():
                    key = tuple(row[j] for j in range(len(conflict_keys)))
                    existing_dict[key] = {
                        sum_cols[k]: row[len(conflict_keys) + k] or 0
                        for k in range(len(sum_cols))
                    }

            # === Step 3: Merge in memory ===
            merged_rows = []
            for br in batch_rows:
                key = tuple(br[k] for k in conflict_keys)
                merged = {**br}
                if key in existing_dict:
                    for c in sum_cols:
                        merged[c] = (br[c] or 0) + existing_dict[key][c]
                merged_rows.append(merged)

            # === Step 4: UPSERT merged rows (overwrite — values already include sum) ===
            columns = conflict_keys + sum_cols
            col_list = ", ".join(columns)
            value_placeholders = ", ".join(["%s"] * len(columns))
            conflict_list = ", ".join(conflict_keys)
            update_clause = ", ".join([f"{c} = EXCLUDED.{c}" for c in sum_cols])

            sql = f"""
                INSERT INTO {table} ({col_list}, inserted_at)
                VALUES ({value_placeholders}, now())
                ON CONFLICT ({conflict_list}) DO UPDATE
                SET {update_clause}, inserted_at = now()
            """
            psycopg2.extras.execute_batch(
                cur, sql,
                [[r[c] for c in columns] for r in merged_rows],
                page_size=500,
            )
        conn.commit()
    finally:
        conn.close()
