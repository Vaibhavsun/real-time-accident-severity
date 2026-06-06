-- Dashboard schema — READ-MERGE-WRITE UPSERT pattern.
-- Each Glue job aggregates a microbatch, reads existing PG rows matching the batch's keys,
-- sums batch + existing per key in memory, then UPSERT (overwrite) with merged values.
--
-- Average columns are NOT stored directly — we keep their numerator (`*_sum`) and
-- denominator (`accident_count` or `*_count`) so dashboard can compute averages:
--     SELECT severity_sum::float / NULLIF(accident_count, 0) AS avg_severity ...
--     SELECT age_of_vehicle_sum::float / NULLIF(age_of_vehicle_count, 0) AS avg_age ...

-- ─────────────────────────────────────────────────────────────────
-- Job 1: KPI + Geo grid (daily windows)
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS accident_kpi_geo (
    event_date            DATE         NOT NULL,
    lat_grid              NUMERIC(5,2) NOT NULL,
    lon_grid              NUMERIC(5,2) NOT NULL,
    accident_count        BIGINT       NOT NULL DEFAULT 0,
    fatal_count           BIGINT       NOT NULL DEFAULT 0,
    serious_count         BIGINT       NOT NULL DEFAULT 0,
    slight_count          BIGINT       NOT NULL DEFAULT 0,
    total_casualties      BIGINT       NOT NULL DEFAULT 0,
    total_vehicles        BIGINT       NOT NULL DEFAULT 0,
    inserted_at           TIMESTAMP    DEFAULT now(),
    CONSTRAINT uq_kpi_geo UNIQUE (event_date, lat_grid, lon_grid)
);
CREATE INDEX IF NOT EXISTS idx_kpi_geo_date ON accident_kpi_geo (event_date DESC);


-- ─────────────────────────────────────────────────────────────────
-- Job 2: Conditions (daily windows)
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS accident_conditions (
    event_date              DATE     NOT NULL,
    weather_conditions      TEXT     NOT NULL,
    light_conditions        TEXT     NOT NULL,
    road_surface_conditions TEXT     NOT NULL,
    speed_limit             INTEGER  NOT NULL,
    accident_count          BIGINT   NOT NULL DEFAULT 0,
    severity_sum            BIGINT   NOT NULL DEFAULT 0,
    fatal_count             BIGINT   NOT NULL DEFAULT 0,
    inserted_at             TIMESTAMP DEFAULT now(),
    CONSTRAINT uq_conditions UNIQUE (event_date, weather_conditions, light_conditions, road_surface_conditions, speed_limit)
);
CREATE INDEX IF NOT EXISTS idx_conditions_date ON accident_conditions (event_date DESC);


-- ─────────────────────────────────────────────────────────────────
-- Job 3: Hotspots (daily windows)
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS accident_hotspots (
    event_date                DATE      NOT NULL,
    local_authority_district  TEXT      NOT NULL,
    road_type                 TEXT      NOT NULL,
    urban_or_rural_area       TEXT      NOT NULL,
    weighted_count            BIGINT    NOT NULL DEFAULT 0,
    accident_count            BIGINT    NOT NULL DEFAULT 0,
    inserted_at               TIMESTAMP DEFAULT now(),
    CONSTRAINT uq_hotspots UNIQUE (event_date, local_authority_district, road_type, urban_or_rural_area)
);
CREATE INDEX IF NOT EXISTS idx_hotspots_date ON accident_hotspots (event_date DESC);


-- ─────────────────────────────────────────────────────────────────
-- Job 4: Vehicle / Driver profile (yearly — Vehicle CSV has only Year)
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS vehicle_profile (
    year                    INTEGER  NOT NULL,
    age_band_of_driver      TEXT     NOT NULL,
    sex_of_driver           TEXT     NOT NULL,
    vehicle_type            TEXT     NOT NULL,
    vehicle_count           BIGINT   NOT NULL DEFAULT 0,
    age_of_vehicle_sum      BIGINT   NOT NULL DEFAULT 0,
    age_of_vehicle_count    BIGINT   NOT NULL DEFAULT 0,
    inserted_at             TIMESTAMP DEFAULT now(),
    CONSTRAINT uq_vehicle_profile UNIQUE (year, age_band_of_driver, sex_of_driver, vehicle_type)
);
CREATE INDEX IF NOT EXISTS idx_vprofile_year ON vehicle_profile (year DESC);


-- ─────────────────────────────────────────────────────────────────
-- Job 5: Stream-stream join → demographics (by processing date)
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS accident_vehicle_demographics (
    processing_date      DATE      NOT NULL,
    age_band_of_driver   TEXT      NOT NULL,
    sex_of_driver        TEXT      NOT NULL,
    vehicle_type         TEXT      NOT NULL,
    accident_severity    TEXT      NOT NULL,
    joined_count         BIGINT    NOT NULL DEFAULT 0,
    inserted_at          TIMESTAMP DEFAULT now(),
    CONSTRAINT uq_demographics UNIQUE (processing_date, age_band_of_driver, sex_of_driver, vehicle_type, accident_severity)
);
CREATE INDEX IF NOT EXISTS idx_demog_date ON accident_vehicle_demographics (processing_date DESC);
CREATE INDEX IF NOT EXISTS idx_demog_severity ON accident_vehicle_demographics (accident_severity);
