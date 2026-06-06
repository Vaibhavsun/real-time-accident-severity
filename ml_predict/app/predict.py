"""
Model loader + inference helper.
Pulls joblib pickle from S3 (written by the Glue training job), caches in memory.
"""
import io
import os
from datetime import datetime, timezone
from threading import Lock

import boto3
import joblib
import pandas as pd

S3_BUCKET = os.getenv("S3_BUCKET", "accident-severity-dev-data")
MODEL_KEY = os.getenv("MODEL_KEY", "models/severity_classifier.joblib")
CACHE_TTL_SEC = int(os.getenv("MODEL_CACHE_TTL_SEC", "300"))

_state = {"artifact": None, "loaded_at": None}
_lock = Lock()


def _fetch():
    s3 = boto3.client("s3")
    obj = s3.get_object(Bucket=S3_BUCKET, Key=MODEL_KEY)
    return joblib.load(io.BytesIO(obj["Body"].read()))


def _ensure_loaded():
    with _lock:
        now = datetime.now(timezone.utc)
        if _state["artifact"] is not None and _state["loaded_at"]:
            age = (now - _state["loaded_at"]).total_seconds()
            if age < CACHE_TTL_SEC:
                return _state["artifact"]
        artifact = _fetch()
        _state["artifact"] = artifact
        _state["loaded_at"] = now
        return artifact


def predict(age_band_of_driver: str, sex_of_driver: str, vehicle_type: str) -> dict:
    artifact = _ensure_loaded()
    X = pd.DataFrame([{
        "age_band_of_driver": age_band_of_driver,
        "sex_of_driver": sex_of_driver,
        "vehicle_type": vehicle_type,
    }])
    model = artifact["model"]
    proba = model.predict_proba(X)[0]
    pred = model.predict(X)[0]
    return {
        "predicted_severity": str(pred),
        "probabilities": {
            str(cls): float(p) for cls, p in zip(artifact["classes"], proba)
        },
        "model_trained_at": artifact["trained_at"],
        "model_n_samples": artifact["n_samples_total"],
        "model_accuracy_test": artifact["accuracy_test"],
    }


def feature_options() -> dict:
    artifact = _ensure_loaded()
    return {
        "feature_options": artifact["feature_options"],
        "classes": artifact["classes"],
        "trained_at": artifact["trained_at"],
        "n_samples": artifact["n_samples_total"],
        "accuracy_test": artifact["accuracy_test"],
    }


def health() -> dict:
    try:
        artifact = _ensure_loaded()
        return {
            "status": "ok",
            "model_trained_at": artifact["trained_at"],
            "loaded_from": f"s3://{S3_BUCKET}/{MODEL_KEY}",
        }
    except Exception as e:
        return {"status": "error", "detail": str(e)}
