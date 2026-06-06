"""
ml_predict — standalone microservice for accident-severity inference.

Endpoints:
  GET  /health
  GET  /features              — dropdown options + model metadata
  POST /predict               — predict severity

Runs on port 8001 by default (override with PORT env var).
"""
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from . import predict as ml

app = FastAPI(title="ml_predict — accident severity inference")


class PredictRequest(BaseModel):
    age_band_of_driver: str
    sex_of_driver: str
    vehicle_type: str


@app.get("/health")
async def health():
    return ml.health()


@app.get("/features")
async def features():
    try:
        return ml.feature_options()
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"model not available: {e}")


@app.post("/predict")
async def post_predict(body: PredictRequest):
    try:
        return ml.predict(
            age_band_of_driver=body.age_band_of_driver,
            sex_of_driver=body.sex_of_driver,
            vehicle_type=body.vehicle_type,
        )
    except FileNotFoundError:
        raise HTTPException(status_code=503, detail="model not trained yet")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
