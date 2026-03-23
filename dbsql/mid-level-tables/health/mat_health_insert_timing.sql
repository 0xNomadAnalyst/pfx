-- =============================================================================
-- mat_health_insert_timing
-- Timeseries of INSERT execution timing for key source tables, derived from
-- pg_stat_statements deltas sampled on every refresh cycle (~30s).
--
-- Each row records the mean INSERT time (recent_mean_ms) and throughput
-- (calls_per_min) for a table over the window since the previous snapshot.
-- The raw pg_stat_statements accumulators (calls_snap, total_exec_snap) are
-- stored alongside so the next snapshot can compute its delta without a
-- separate state table.
--
-- Severity bands for recent_mean_ms:
--   Normal    < 50 ms
--   Elevated  50 – 500 ms
--   Slow      500 – 5 000 ms  (queue will back up)
--   Critical  ≥ 5 000 ms      (S3-scan territory)
--
-- max_exec_ms = all-time worst single call since pg_stat_statements last reset;
-- stored for reference, not used for severity.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

CREATE TABLE IF NOT EXISTS health.mat_health_insert_timing (
    time            TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
    schema_name     TEXT             NOT NULL,
    table_name      TEXT             NOT NULL,
    -- Computed window metrics (chart data)
    recent_mean_ms  DOUBLE PRECISION,
    calls_per_min   DOUBLE PRECISION,
    -- Raw accumulators from pg_stat_statements (retained for next delta)
    calls_snap      BIGINT,
    total_exec_snap DOUBLE PRECISION,
    max_exec_ms     DOUBLE PRECISION,
    PRIMARY KEY (time, schema_name, table_name)
);

SELECT create_hypertable(
    'health.mat_health_insert_timing', 'time',
    if_not_exists => TRUE
);

ALTER TABLE health.mat_health_insert_timing
    SET (timescaledb.compress, timescaledb.compress_segmentby = 'schema_name,table_name');

SELECT add_compression_policy(
    'health.mat_health_insert_timing',
    INTERVAL '1 day',
    if_not_exists => TRUE
);

SELECT add_retention_policy(
    'health.mat_health_insert_timing',
    INTERVAL '14 days',
    if_not_exists => TRUE
);

-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE health.refresh_mat_health_insert_timing()
LANGUAGE plpgsql AS $$
DECLARE
    _r             RECORD;
    _prev_calls    BIGINT;
    _prev_total_ms DOUBLE PRECISION;
    _prev_at       TIMESTAMPTZ;
    _mean_ms       DOUBLE PRECISION;
    _cpm           DOUBLE PRECISION;
    _elapsed_mins  DOUBLE PRECISION;
    _now           TIMESTAMPTZ := NOW();
BEGIN
    -- ── Discover all INSERT targets across monitored schemas ──────────────
    -- Extracts (schema, table) from pg_stat_statements query text dynamically
    -- so new tables are picked up automatically without code changes.
    FOR _r IN
        SELECT
            m[1]                 AS schema_name,
            m[2]                 AS table_name,
            SUM(calls)           AS calls_total,
            SUM(total_exec_time) AS total_exec_ms,
            MAX(max_exec_time)   AS max_exec_ms
        FROM pg_stat_statements pss
        CROSS JOIN LATERAL regexp_match(
            pss.query,
            'insert\s+into\s+"?(\w+)"?\."?(\w+)"?',
            'i'
        ) AS rm(m)
        WHERE pss.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
          AND m IS NOT NULL
          AND m[1] IN ('dexes', 'kamino_lend', 'exponent')
          AND m[2] LIKE 'src\_%'
        GROUP BY m[1], m[2]
    LOOP
        -- ── Previous snapshot (most recent row for this table) ────────────
        SELECT calls_snap, total_exec_snap, time
        INTO   _prev_calls, _prev_total_ms, _prev_at
        FROM health.mat_health_insert_timing
        WHERE schema_name = _r.schema_name
          AND table_name  = _r.table_name
          AND time > _now - INTERVAL '5 minutes'
        ORDER BY time DESC
        LIMIT 1;

        -- ── Compute delta metrics ─────────────────────────────────────────
        IF _prev_calls IS NOT NULL
           AND _r.calls_total > _prev_calls
           AND _prev_at IS NOT NULL
        THEN
            _elapsed_mins := EXTRACT(EPOCH FROM (_now - _prev_at)) / 60.0;
            _mean_ms := (_r.total_exec_ms - _prev_total_ms)
                        / NULLIF(_r.calls_total - _prev_calls, 0);
            _cpm     := (_r.calls_total - _prev_calls)
                        / NULLIF(_elapsed_mins, 0);
        ELSE
            _mean_ms := NULL;
            _cpm     := NULL;
        END IF;

        -- ── Append row to timeseries ──────────────────────────────────────
        INSERT INTO health.mat_health_insert_timing
            (time, schema_name, table_name,
             recent_mean_ms, calls_per_min,
             calls_snap, total_exec_snap, max_exec_ms)
        VALUES
            (_now, _r.schema_name, _r.table_name,
             _mean_ms, _cpm,
             _r.calls_total, _r.total_exec_ms, _r.max_exec_ms);
    END LOOP;
END;
$$;
