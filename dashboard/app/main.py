"""
Accident Severity Dashboard — FastAPI backend.

Reads from the 5 Postgres tables populated by the Glue Streaming jobs.
Exposes:
  - HTTP /api/* endpoints for initial page load + ad-hoc fetches
  - WebSocket /ws — server pushes a stats snapshot every 10 seconds

Run:
    cd dashboard
    pip install -r requirements.txt
    export DB_PASS='your-rds-password'
    uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload

Open: http://localhost:8000
"""
import asyncio
import json
import os
from contextlib import asynccontextmanager
from datetime import date, datetime
from decimal import Decimal

import asyncpg
import httpx
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

# Remote ml_predict microservice (runs in its own container)
ML_PREDICT_URL = os.getenv("ML_PREDICT_URL", "http://ml-predict:8001")

DB_HOST = os.getenv("DB_HOST", "accident-severity-dev-pg.cctwww0wsavn.us-east-1.rds.amazonaws.com")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "dashboard")
DB_USER = os.getenv("DB_USER", "dashboard_admin")
DB_PASS = os.environ.get("DB_PASS", "")

POLL_INTERVAL_SEC = 10
DEFAULT_LIMIT = 50

pool: asyncpg.Pool | None = None
clients: set[WebSocket] = set()


def _json_default(o):
    if isinstance(o, (date, datetime)):
        return o.isoformat()
    if isinstance(o, Decimal):
        return float(o)
    raise TypeError(f"not serializable: {type(o)}")


def _rows(records) -> list[dict]:
    return [dict(r) for r in records]


@asynccontextmanager
async def lifespan(_app: FastAPI):
    global pool
    if not DB_PASS:
        raise RuntimeError("Set DB_PASS env var to RDS password")
    pool = await asyncpg.create_pool(
        host=DB_HOST, port=DB_PORT, database=DB_NAME,
        user=DB_USER, password=DB_PASS,
        min_size=2, max_size=10,
        command_timeout=10,
    )
    broadcaster_task = asyncio.create_task(_broadcaster())
    try:
        yield
    finally:
        broadcaster_task.cancel()
        await pool.close()


app = FastAPI(title="Accident Severity Dashboard", lifespan=lifespan)


# ─────────────────────────  HTTP endpoints  ─────────────────────────

@app.get("/")
async def root():
    return FileResponse("static/index.html")


@app.get("/api/stats")
async def get_stats():
    async with pool.acquire() as conn:
        row = await conn.fetchrow("""
            SELECT
                (SELECT COALESCE(SUM(accident_count), 0) FROM accident_kpi_geo)  AS total_accidents,
                (SELECT COALESCE(SUM(fatal_count), 0)    FROM accident_kpi_geo)  AS total_fatal,
                (SELECT COALESCE(SUM(serious_count), 0)  FROM accident_kpi_geo)  AS total_serious,
                (SELECT COALESCE(SUM(slight_count), 0)   FROM accident_kpi_geo)  AS total_slight,
                (SELECT COALESCE(SUM(total_casualties), 0) FROM accident_kpi_geo) AS total_casualties,
                (SELECT COALESCE(SUM(total_vehicles), 0)   FROM accident_kpi_geo) AS total_vehicles,
                (SELECT count(*) FROM accident_kpi_geo)                AS rows_kpi_geo,
                (SELECT count(*) FROM accident_conditions)             AS rows_conditions,
                (SELECT count(*) FROM accident_hotspots)               AS rows_hotspots,
                (SELECT count(*) FROM vehicle_profile)                 AS rows_vehicle_profile,
                (SELECT count(*) FROM accident_vehicle_demographics)   AS rows_demographics,
                (SELECT max(inserted_at) FROM accident_kpi_geo)        AS last_update
        """)
        return dict(row)


@app.get("/api/kpi-geo")
async def get_kpi_geo(limit: int = DEFAULT_LIMIT):
    async with pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT event_date, lat_grid, lon_grid,
                   accident_count, fatal_count, serious_count, slight_count,
                   total_casualties, total_vehicles, inserted_at
            FROM accident_kpi_geo
            ORDER BY inserted_at DESC
            LIMIT $1
        """, limit)
        return _rows(rows)


@app.get("/api/conditions")
async def get_conditions(limit: int = DEFAULT_LIMIT):
    """Latest rows + computed avg_severity."""
    async with pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT event_date, weather_conditions, light_conditions,
                   road_surface_conditions, speed_limit,
                   accident_count, fatal_count, severity_sum,
                   ROUND(severity_sum::numeric / NULLIF(accident_count, 0), 3) AS avg_severity,
                   inserted_at
            FROM accident_conditions
            ORDER BY inserted_at DESC
            LIMIT $1
        """, limit)
        return _rows(rows)


@app.get("/api/conditions/top-weather")
async def get_top_weather(limit: int = 10):
    """Top weather conditions by total accident_count (all dates)."""
    async with pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT weather_conditions,
                   SUM(accident_count) AS accidents,
                   SUM(fatal_count)    AS fatal
            FROM accident_conditions
            WHERE weather_conditions IS NOT NULL
            GROUP BY weather_conditions
            ORDER BY accidents DESC
            LIMIT $1
        """, limit)
        return _rows(rows)


@app.get("/api/hotspots")
async def get_hotspots(limit: int = DEFAULT_LIMIT):
    async with pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT event_date, local_authority_district, road_type,
                   urban_or_rural_area, weighted_count, accident_count, inserted_at
            FROM accident_hotspots
            ORDER BY inserted_at DESC
            LIMIT $1
        """, limit)
        return _rows(rows)


@app.get("/api/hotspots/top-districts")
async def get_top_districts(limit: int = 10):
    """Top districts by total weighted_count."""
    async with pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT local_authority_district AS district,
                   SUM(weighted_count) AS weighted,
                   SUM(accident_count) AS accidents
            FROM accident_hotspots
            WHERE local_authority_district IS NOT NULL
            GROUP BY local_authority_district
            ORDER BY weighted DESC
            LIMIT $1
        """, limit)
        return _rows(rows)


@app.get("/api/vehicle-profile")
async def get_vehicle_profile(limit: int = DEFAULT_LIMIT):
    async with pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT year, age_band_of_driver, sex_of_driver, vehicle_type,
                   vehicle_count, age_of_vehicle_sum, age_of_vehicle_count,
                   ROUND(age_of_vehicle_sum::numeric / NULLIF(age_of_vehicle_count, 0), 2) AS avg_age,
                   inserted_at
            FROM vehicle_profile
            ORDER BY inserted_at DESC
            LIMIT $1
        """, limit)
        return _rows(rows)


@app.get("/api/vehicle-profile/by-age-band")
async def get_vehicle_by_age(limit: int = 10):
    async with pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT age_band_of_driver AS age_band,
                   SUM(vehicle_count) AS vehicles
            FROM vehicle_profile
            WHERE age_band_of_driver IS NOT NULL
              AND age_band_of_driver != 'Data missing or out of range'
            GROUP BY age_band_of_driver
            ORDER BY vehicles DESC
            LIMIT $1
        """, limit)
        return _rows(rows)


@app.get("/api/demographics")
async def get_demographics(limit: int = DEFAULT_LIMIT):
    async with pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT processing_date, age_band_of_driver, sex_of_driver,
                   vehicle_type, accident_severity, joined_count, inserted_at
            FROM accident_vehicle_demographics
            ORDER BY inserted_at DESC
            LIMIT $1
        """, limit)
        return _rows(rows)


# ─────────────────────────  ML prediction  ─────────────────────────

class PredictRequest(BaseModel):
    age_band_of_driver: str
    sex_of_driver: str
    vehicle_type: str


@app.get("/api/predict/features")
async def get_predict_features():
    """Proxy to ml_predict microservice."""
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.get(f"{ML_PREDICT_URL}/features")
            if r.status_code != 200:
                raise HTTPException(status_code=r.status_code, detail=r.json().get("detail", r.text))
            return r.json()
    except httpx.RequestError as e:
        raise HTTPException(status_code=503, detail=f"ml_predict unreachable: {e}")


@app.post("/api/predict")
async def post_predict(body: PredictRequest):
    """Proxy to ml_predict microservice."""
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.post(f"{ML_PREDICT_URL}/predict", json=body.model_dump())
            if r.status_code != 200:
                raise HTTPException(status_code=r.status_code, detail=r.json().get("detail", r.text))
            return r.json()
    except httpx.RequestError as e:
        raise HTTPException(status_code=503, detail=f"ml_predict unreachable: {e}")


# ─────────────────────────  WebSocket + broadcaster  ─────────────────────────

async def _build_snapshot() -> str:
    async with pool.acquire() as conn:
        stats = await conn.fetchrow("""
            SELECT
                COALESCE(SUM(accident_count), 0)   AS total_accidents,
                COALESCE(SUM(fatal_count), 0)      AS total_fatal,
                COALESCE(SUM(serious_count), 0)    AS total_serious,
                COALESCE(SUM(slight_count), 0)     AS total_slight,
                COALESCE(SUM(total_casualties), 0) AS total_casualties,
                COALESCE(SUM(total_vehicles), 0)   AS total_vehicles,
                max(inserted_at) AS last_update
            FROM accident_kpi_geo
        """)
        recent_geo = await conn.fetch("""
            SELECT event_date, lat_grid, lon_grid, accident_count, fatal_count
            FROM accident_kpi_geo
            ORDER BY inserted_at DESC
            LIMIT 100
        """)
        top_districts = await conn.fetch("""
            SELECT local_authority_district AS district,
                   SUM(weighted_count) AS weighted,
                   SUM(accident_count) AS accidents
            FROM accident_hotspots
            WHERE local_authority_district IS NOT NULL
            GROUP BY local_authority_district
            ORDER BY weighted DESC
            LIMIT 10
        """)
        top_weather = await conn.fetch("""
            SELECT weather_conditions AS weather,
                   SUM(accident_count) AS accidents,
                   SUM(fatal_count) AS fatal
            FROM accident_conditions
            WHERE weather_conditions IS NOT NULL
            GROUP BY weather_conditions
            ORDER BY accidents DESC
            LIMIT 8
        """)
        age_bands = await conn.fetch("""
            SELECT age_band_of_driver AS age_band,
                   SUM(vehicle_count) AS vehicles
            FROM vehicle_profile
            WHERE age_band_of_driver IS NOT NULL
              AND age_band_of_driver != 'Data missing or out of range'
            GROUP BY age_band_of_driver
            ORDER BY vehicles DESC
        """)

    payload = {
        "type": "snapshot",
        "ts": datetime.utcnow().isoformat(),
        "stats": dict(stats),
        "recent_geo": _rows(recent_geo),
        "top_districts": _rows(top_districts),
        "top_weather": _rows(top_weather),
        "age_bands": _rows(age_bands),
    }
    return json.dumps(payload, default=_json_default)


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    clients.add(ws)
    try:
        # Send initial snapshot immediately
        try:
            await ws.send_text(await _build_snapshot())
        except Exception:
            pass
        # Keep connection alive — broadcaster pushes updates
        while True:
            await ws.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        clients.discard(ws)


async def _broadcaster():
    """Every POLL_INTERVAL_SEC seconds, push fresh snapshot to all connected clients."""
    while True:
        try:
            await asyncio.sleep(POLL_INTERVAL_SEC)
            if not clients:
                continue
            msg = await _build_snapshot()
            dead = set()
            for ws in list(clients):
                try:
                    await ws.send_text(msg)
                except Exception:
                    dead.add(ws)
            for ws in dead:
                clients.discard(ws)
        except asyncio.CancelledError:
            break
        except Exception as e:
            print(f"broadcaster error: {e}")


# Mount static last so /api routes win
app.mount("/static", StaticFiles(directory="static"), name="static")
