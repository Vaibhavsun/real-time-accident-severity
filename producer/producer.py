#!/usr/bin/env python3
"""
Multiprocessing producer: streams the accident + vehicle CSVs out of S3 and
replays them into Kafka as a time-indexed event stream.

One child process per stream:
    accidents/Accident_Information.csv  ->  topic "accident-raw"
    vehicles/Vehicle_Information.csv     ->  topic "vehicles-raw"

Rows are never fully loaded into memory: each S3 object is read line-by-line via
the streaming body, so a 700 MB file uses a few MB of RAM.

Config is via environment variables (see README), overridable with CLI flags.
"""

import os
import csv
import sys
import json
import time
import signal
import logging
import argparse
from datetime import datetime, timezone
from multiprocessing import Process

import boto3
from kafka import KafkaProducer
from kafka.errors import KafkaError

LOG_FORMAT = "%(asctime)s %(processName)s %(levelname)s %(message)s"
logging.basicConfig(level=logging.INFO, format=LOG_FORMAT)

# --- Stream definitions ------------------------------------------------------
# ts_cols: columns combined into the event_time; None means the stream has no
# native timestamp (vehicles join to accidents by Accident_Index downstream).
STREAMS = [
    {
        "name": "accidents",
        "s3_key": "accidents/Accident_Information.csv",
        "topic": "accident-raw",
        "ts_cols": ("Date", "Time"),
    },
    {
        "name": "vehicles",
        "s3_key": "vehicles/Vehicle_Information.csv",
        "topic": "vehicles-raw",
        "ts_cols": None,
    },
]

KEY_COLUMN = "Accident_Index"  # partition key — keeps an accident + its vehicles together


def s3_csv_rows(bucket, key, region):
    """Yield CSV rows from an S3 object as dicts, streaming line-by-line."""
    s3 = boto3.client("s3", region_name=region)
    resp = s3.get_object(Bucket=bucket, Key=key)
    text_lines = (line.decode("utf-8") for line in resp["Body"].iter_lines())
    reader = csv.DictReader(text_lines)
    for row in reader:
        yield row


def build_event_time(stream, row):
    """Best-effort ISO event_time from the row's native timestamp columns."""
    cols = stream["ts_cols"]
    if not cols:
        return None
    parts = [row.get(c, "").strip() for c in cols]
    parts = [p for p in parts if p]
    return " ".join(parts) if parts else None


def make_producer(brokers):
    kwargs = dict(
        bootstrap_servers=brokers,
        value_serializer=lambda v: json.dumps(v).encode("utf-8"),
        key_serializer=lambda k: k.encode("utf-8") if k else None,
        acks="all",
        retries=5,
        linger_ms=50,
        batch_size=64 * 1024,
        # Azure Event Hubs' Kafka surface speaks the Kafka 1.0/2.0 protocol;
        # pinning api_version avoids kafka-python advertising newer features
        # (idempotent producer, message format v2.5) that EH rejects.
        api_version=(2, 0, 0),
        # NOTE: enable_idempotence isn't released in kafka-python / kafka-python-ng
        # yet (only on master). For exact-once we'd switch to confluent-kafka
        # (librdkafka binding). For the prototype, Spark's read-merge-write
        # UPSERT pattern in foreachBatch already handles retry-duplicates.
    )
    # Azure Event Hubs Kafka surface uses SASL_SSL + PLAIN. Username is the
    # literal string "$ConnectionString" (hardcoded — systemd EnvironmentFile=
    # would otherwise expand $ConnectionString to empty). Password is the full
    # connection string from `terraform output -raw eventhub_connection_string`.
    sasl_password = os.environ.get("KAFKA_SASL_PASSWORD")
    if sasl_password:
        kwargs.update(
            security_protocol="SASL_SSL",
            sasl_mechanism="PLAIN",
            sasl_plain_username="$ConnectionString",
            sasl_plain_password=sasl_password,
        )
    return KafkaProducer(**kwargs)


def run_stream(stream, brokers, bucket, region, rate, max_records, flush_every):
    """Child-process entry point: stream one CSV into one Kafka topic."""
    log = logging.getLogger(stream["name"])
    log.info("starting -> topic=%s key=%s", stream["topic"], stream["s3_key"])

    producer = make_producer(brokers)
    topic = stream["topic"]
    sleep_per_msg = (1.0 / rate) if rate and rate > 0 else 0.0

    sent = 0
    errors = 0
    started = time.monotonic()

    def on_error(exc):
        nonlocal errors
        errors += 1
        log.error("send failed: %s", exc)

    try:
        for seq, row in enumerate(s3_csv_rows(bucket, stream["s3_key"], region)):
            event = {
                "seq": seq,                                   # monotonic time index
                "stream": stream["name"],
                "event_time": build_event_time(stream, row),  # native event timestamp
                "ingest_time": datetime.now(timezone.utc).isoformat(),
                "payload": row,
            }
            key = row.get(KEY_COLUMN)
            producer.send(topic, key=key, value=event).add_errback(on_error)
            sent += 1

            if sent % flush_every == 0:
                producer.flush()
                rate_now = sent / (time.monotonic() - started)
                log.info("sent=%d errors=%d (%.0f msg/s)", sent, errors, rate_now)

            if sleep_per_msg:
                time.sleep(sleep_per_msg)
            if max_records and sent >= max_records:
                log.info("reached --max-records=%d, stopping", max_records)
                break
    finally:
        producer.flush()
        producer.close()
        elapsed = time.monotonic() - started
        log.info("DONE topic=%s sent=%d errors=%d in %.1fs", topic, sent, errors, elapsed)


def parse_args(argv):
    p = argparse.ArgumentParser(description="S3 -> Kafka multiprocessing producer")
    p.add_argument("--bucket", default=os.environ.get("S3_BUCKET", "accident-severity-dev-data"))
    p.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    p.add_argument(
        "--brokers",
        default=os.environ.get("KAFKA_BROKERS", "localhost:9092"),
        help="comma-separated Kafka bootstrap brokers",
    )
    p.add_argument(
        "--rate", type=float, default=float(os.environ.get("RATE", "0")),
        help="messages/sec per stream (0 = as fast as possible)",
    )
    p.add_argument(
        "--max-records", type=int, default=int(os.environ.get("MAX_RECORDS", "0")),
        help="stop each stream after N records (0 = whole file); handy for smoke tests",
    )
    p.add_argument("--flush-every", type=int, default=10000)
    p.add_argument(
        "--only", choices=[s["name"] for s in STREAMS],
        help="run a single stream instead of all",
    )
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv or sys.argv[1:])
    brokers = [b.strip() for b in args.brokers.split(",") if b.strip()]
    streams = [s for s in STREAMS if (args.only is None or s["name"] == args.only)]

    logging.info("bucket=%s region=%s brokers=%s rate=%s", args.bucket, args.region, brokers, args.rate)

    procs = []
    for stream in streams:
        proc = Process(
            target=run_stream,
            name=f"producer-{stream['name']}",
            args=(stream, brokers, args.bucket, args.region,
                  args.rate, args.max_records, args.flush_every),
        )
        proc.start()
        procs.append(proc)

    # Forward Ctrl-C to children for a clean shutdown.
    def shutdown(signum, frame):
        logging.info("signal %s -> terminating children", signum)
        for proc in procs:
            proc.terminate()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    for proc in procs:
        proc.join()

if __name__ == "__main__":
    main()
