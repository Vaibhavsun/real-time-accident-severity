"""
Train accident severity classifier — runs as AWS Glue Python Shell job
scheduled every 15 minutes by aws_glue_trigger.ml_train_schedule.

Reads:
  s3://<bucket>/processed/accidents/   <- written by Glue job5 (accident-raw stream)
  s3://<bucket>/processed/vehicles/    <- written by Glue job5 (vehicles-raw stream)

Joins both on Accident_Index in pandas, then trains:
  Features: age_band_of_driver, sex_of_driver, vehicle_type
  Target:   accident_severity  (Fatal / Serious / Slight)

Writes: s3://<bucket>/models/severity_classifier.joblib
"""
import io
import os
import sys
from datetime import datetime, timezone

import boto3
import joblib
import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import classification_report
from sklearn.model_selection import train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder


def _resolve_config() -> dict:
    defaults = {
        "S3_BUCKET":   "accident-severity-dev-data",
        "DATA_PREFIX": "processed",
        "MODEL_KEY":   "models/severity_classifier.joblib",
    }
    try:
        from awsglue.utils import getResolvedOptions  # type: ignore
        args = getResolvedOptions(sys.argv, ["S3_BUCKET", "DATA_PREFIX", "MODEL_KEY"])
        return {k: args.get(k) or defaults[k] for k in defaults}
    except BaseException:
        return {k: os.getenv(k, v) for k, v in defaults.items()}


_cfg        = _resolve_config()
S3_BUCKET   = _cfg["S3_BUCKET"]
DATA_PREFIX = _cfg["DATA_PREFIX"].rstrip("/")
MODEL_KEY   = _cfg["MODEL_KEY"]

ACC_PREFIX = f"{DATA_PREFIX}/accidents/"
VEH_PREFIX = f"{DATA_PREFIX}/vehicles/"

FEATURE_COLS = ["age_band_of_driver", "sex_of_driver", "vehicle_type"]
TARGET_COL   = "accident_severity"


def list_parquet_keys(s3, bucket: str, prefix: str) -> list:
    keys = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            if obj["Key"].endswith(".parquet"):
                keys.append(obj["Key"])
    return keys


def load_parquet(s3, bucket: str, prefix: str) -> pd.DataFrame:
    keys = list_parquet_keys(s3, bucket, prefix)
    if not keys:
        return pd.DataFrame()
    print(f"loading {len(keys)} parquet files from s3://{bucket}/{prefix}")
    frames = []
    for i, key in enumerate(keys):
        try:
            obj = s3.get_object(Bucket=bucket, Key=key)
            frames.append(pd.read_parquet(io.BytesIO(obj["Body"].read())))
        except Exception as e:
            print(f"  skip {key}: {e}")
        if (i + 1) % 50 == 0:
            print(f"  {i + 1}/{len(keys)} loaded")
    return pd.concat(frames, ignore_index=True) if frames else pd.DataFrame()


def clean(df: pd.DataFrame) -> pd.DataFrame:
    df = df.dropna(subset=[TARGET_COL] + FEATURE_COLS)
    bad = {"Data missing or out of range", "Not known", "Unknown", "-1", "Other"}
    for c in FEATURE_COLS:
        df = df[~df[c].isin(bad)]
    return df.reset_index(drop=True)


def train_and_save():
    s3 = boto3.client("s3")

    acc = load_parquet(s3, S3_BUCKET, ACC_PREFIX)
    veh = load_parquet(s3, S3_BUCKET, VEH_PREFIX)

    if acc.empty or veh.empty:
        print(f"ERROR: accidents empty={acc.empty}  vehicles empty={veh.empty}")
        sys.exit(1)

    print(f"accidents rows: {len(acc):,}   vehicles rows: {len(veh):,}")

    acc.columns = [c.lower() for c in acc.columns]
    veh.columns = [c.lower() for c in veh.columns]

    df = veh.merge(acc, on="accident_index", how="inner")
    print(f"joined rows: {len(df):,}")

    df = clean(df)
    print(f"clean rows:  {len(df):,}")

    if len(df) < 100:
        print("ERROR: too few clean rows (<100) — sort the CSVs and re-upload")
        sys.exit(1)

    print(f"target distribution:\n{df[TARGET_COL].value_counts(normalize=True).round(3)}")

    X = df[FEATURE_COLS]
    y = df[TARGET_COL]

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42,
        stratify=y if y.nunique() > 1 else None,
    )

    pipeline = Pipeline([
        ("preprocess", ColumnTransformer([
            ("ohe", OneHotEncoder(handle_unknown="ignore", sparse_output=False), FEATURE_COLS),
        ])),
        ("clf", LogisticRegression(max_iter=2000, class_weight="balanced", n_jobs=-1)),
    ])

    print("training ...")
    pipeline.fit(X_train, y_train)

    train_acc = pipeline.score(X_train, y_train)
    test_acc  = pipeline.score(X_test,  y_test)
    print(f"accuracy — train: {train_acc:.3f}  test: {test_acc:.3f}")
    print(classification_report(y_test, pipeline.predict(X_test)))

    ohe = pipeline.named_steps["preprocess"].named_transformers_["ohe"]
    feature_options = {
        FEATURE_COLS[i]: sorted([str(v) for v in ohe.categories_[i]])
        for i in range(len(FEATURE_COLS))
    }

    artifact = {
        "model":               pipeline,
        "feature_columns":     FEATURE_COLS,
        "classes":             [str(c) for c in pipeline.classes_],
        "feature_options":     feature_options,
        "trained_at":          datetime.now(timezone.utc).isoformat(),
        "n_samples_total":     int(len(df)),
        "n_samples_train":     int(len(X_train)),
        "n_samples_test":      int(len(X_test)),
        "accuracy_train":      float(train_acc),
        "accuracy_test":       float(test_acc),
        "target_distribution": {str(k): float(v) for k, v in y.value_counts(normalize=True).items()},
    }

    buf = io.BytesIO()
    joblib.dump(artifact, buf, compress=3)
    buf.seek(0)
    s3.put_object(Bucket=S3_BUCKET, Key=MODEL_KEY, Body=buf.read())
    print(f"saved s3://{S3_BUCKET}/{MODEL_KEY}")


if __name__ == "__main__":
    train_and_save()
