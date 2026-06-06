"""
Bootstrap trainer — reads local CSVs directly (no Glue / S3 parquet needed).
Joins Accident + Vehicle on Accident_Index, trains the same pipeline as
train.py, and uploads models/severity_classifier.joblib to S3.

Usage:
    pip install pandas scikit-learn joblib boto3 pyarrow
    python ml_accidental_severity/train_local.py
"""
import io
import os
import sys

import boto3
import joblib
import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import classification_report
from sklearn.model_selection import train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder
from datetime import datetime, timezone

S3_BUCKET    = os.getenv("S3_BUCKET",    "accident-severity-dev-data")
DATA_PREFIX  = os.getenv("DATA_PREFIX",  "processed").rstrip("/")
MODEL_KEY    = os.getenv("MODEL_KEY",    "models/severity_classifier.joblib")

ACCIDENT_CSV = os.path.join(os.path.dirname(__file__), "../data/Accident_Information.csv")
VEHICLE_CSV  = os.path.join(os.path.dirname(__file__), "../data/Vehicle_Information.csv")

FEATURE_COLS = ["age_band_of_driver", "sex_of_driver", "vehicle_type"]
TARGET_COL   = "accident_severity"


def load_and_join() -> pd.DataFrame:
    print("loading Accident_Information.csv …")
    acc = pd.read_csv(
        ACCIDENT_CSV,
        usecols=["Accident_Index", "Accident_Severity"],
        low_memory=False,
    )
    acc.columns = ["accident_index", "accident_severity"]

    print("loading Vehicle_Information.csv …")
    veh = pd.read_csv(
        VEHICLE_CSV,
        usecols=["Accident_Index", "Age_Band_of_Driver", "Sex_of_Driver", "Vehicle_Type"],
        low_memory=False,
    )
    veh.columns = ["accident_index", "age_band_of_driver", "sex_of_driver", "vehicle_type"]

    print("joining …")
    df = veh.merge(acc, on="accident_index", how="inner")
    print(f"joined rows: {len(df):,}")
    return df


def clean(df: pd.DataFrame) -> pd.DataFrame:
    df = df.dropna(subset=[TARGET_COL] + FEATURE_COLS)
    bad = {"Data missing or out of range", "Not known", "Unknown", "-1", "Other"}
    for c in FEATURE_COLS:
        df = df[~df[c].isin(bad)]
    return df.reset_index(drop=True)


def main():
    df = load_and_join()
    df = clean(df)
    print(f"clean rows: {len(df):,}")

    if len(df) < 100:
        print("ERROR: too few rows after cleaning")
        sys.exit(1)

    print(f"target distribution:\n{df[TARGET_COL].value_counts(normalize=True).round(3)}")

    X = df[FEATURE_COLS]
    y = df[TARGET_COL]

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42, stratify=y,
    )

    pipeline = Pipeline([
        ("preprocess", ColumnTransformer([
            ("ohe", OneHotEncoder(handle_unknown="ignore", sparse_output=False), FEATURE_COLS),
        ])),
        ("clf", LogisticRegression(max_iter=2000, class_weight="balanced", n_jobs=-1)),
    ])

    print("training …")
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
        "model": pipeline,
        "feature_columns": FEATURE_COLS,
        "classes": [str(c) for c in pipeline.classes_],
        "feature_options": feature_options,
        "trained_at": datetime.now(timezone.utc).isoformat(),
        "n_samples": int(len(df)),
        "n_samples_train": int(len(X_train)),
        "n_samples_test": int(len(X_test)),
        "accuracy_train": float(train_acc),
        "accuracy_test": float(test_acc),
        "target_distribution": {
            str(k): float(v) for k, v in y.value_counts(normalize=True).items()
        },
    }

    buf = io.BytesIO()
    joblib.dump(artifact, buf, compress=3)
    buf.seek(0)

    print(f"uploading to s3://{S3_BUCKET}/{MODEL_KEY} …")
    boto3.client("s3").put_object(Bucket=S3_BUCKET, Key=MODEL_KEY, Body=buf.read())
    print("done — restart ml-predict container to pick up the new model")


if __name__ == "__main__":
    main()
