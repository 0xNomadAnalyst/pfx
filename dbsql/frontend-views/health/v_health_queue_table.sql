-- =============================================================================
-- health.v_health_queue_table
-- Queue health status with per-dimension severity (gap, util, failure)
--
-- OPTIMISED:
--   1. Loop-based dynamic SQL gathers current status per schema (resilient to
--      missing schemas via EXCEPTION WHEN undefined_table).
--   2. 7-day P95 benchmarks pre-computed in mat_health_queue_benchmarks,
--      refreshed by health.refresh_queue_benchmarks() (called by cronjob).
--   3. Thin VIEW wrapper preserves existing caller interface.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

-- ─── Materialized view: pre-computed 7-day P95 benchmarks ────────────────────
-- Refreshed by health.refresh_queue_benchmarks() which the cronjob calls.

CREATE MATERIALIZED VIEW IF NOT EXISTS health.mat_health_queue_benchmarks AS
SELECT domain, queue_name, p95_staleness_7d, p95_utilization_pct_7d, p95_consecutive_failures_7d
FROM (VALUES (NULL::text, NULL::text, NULL::float8, NULL::float8, NULL::float8)) AS seed(domain, queue_name, p95_staleness_7d, p95_utilization_pct_7d, p95_consecutive_failures_7d)
WHERE false;

CREATE UNIQUE INDEX IF NOT EXISTS mat_health_queue_benchmarks_pk
    ON health.mat_health_queue_benchmarks (domain, queue_name);


-- ─── Helper: refresh the benchmarks mat view ─────────────────────────────────
CREATE OR REPLACE FUNCTION health.refresh_queue_benchmarks()
RETURNS void
LANGUAGE plpgsql VOLATILE
AS $rfn$
DECLARE
    _schema RECORD;
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS _bm_staging (
        domain                       text,
        queue_name                   text,
        p95_staleness_7d             double precision,
        p95_utilization_pct_7d       double precision,
        p95_consecutive_failures_7d  double precision
    ) ON COMMIT DROP;
    TRUNCATE _bm_staging;

    FOR _schema IN
        SELECT * FROM (VALUES
            ('dexes'), ('exponent'), ('kamino_lend'), ('solstice_proprietary')
        ) AS s(name)
    LOOP
        BEGIN
            EXECUTE format(
                $q$INSERT INTO _bm_staging
                 SELECT %L, queue_name,
                        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY seconds_since_last_write),
                        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY queue_utilization_pct),
                        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY consecutive_failures)
                 FROM %I.queue_health
                 WHERE time > NOW() - INTERVAL '7 days'
                   AND seconds_since_last_write IS NOT NULL
                 GROUP BY queue_name$q$,
                _schema.name, _schema.name
            );
        EXCEPTION WHEN undefined_table THEN
            NULL;
        END;
    END LOOP;

    -- Replace mat view contents atomically
    DELETE FROM health.mat_health_queue_benchmarks;
    INSERT INTO health.mat_health_queue_benchmarks
        SELECT * FROM _bm_staging;
END;
$rfn$;


-- ─── Main function ───────────────────────────────────────────────────────────

DROP VIEW IF EXISTS health.v_health_queue_table CASCADE;
DROP FUNCTION IF EXISTS health._fn_queue_table();

CREATE OR REPLACE FUNCTION health._fn_queue_table()
RETURNS TABLE (
    domain                       text,
    queue_name                   text,
    queue_size                   integer,
    max_queue_size               integer,
    queue_utilization_pct        double precision,
    p95_utilization_pct_7d       double precision,
    write_rate_per_min           double precision,
    seconds_since_last_write     double precision,
    p95_staleness_7d             double precision,
    consecutive_failures         integer,
    p95_consecutive_failures_7d  double precision,
    gap_severity                 integer,
    util_severity                integer,
    fail_severity                integer,
    summary_severity             integer,
    gap_status                   text,
    util_status                  text,
    fail_status                  text,
    summary_status               text,
    is_red                       boolean,
    snapshot_time                timestamptz
)
LANGUAGE plpgsql VOLATILE
AS $fn$
#variable_conflict use_column
DECLARE
    _schema RECORD;
BEGIN
    -- ── Temp table for live current status ────────────────────────────────
    CREATE TEMP TABLE IF NOT EXISTS _qt_current (
        domain                  text,
        queue_name              text,
        queue_size              integer,
        max_queue_size          integer,
        queue_utilization_pct   double precision,
        write_rate_per_min      double precision,
        seconds_since_last_write double precision,
        consecutive_failures    integer,
        warning_level           text,
        snapshot_time           timestamptz
    ) ON COMMIT DROP;
    TRUNCATE _qt_current;

    FOR _schema IN
        SELECT * FROM (VALUES
            ('dexes'), ('exponent'), ('kamino_lend'), ('solstice_proprietary')
        ) AS s(name)
    LOOP
        BEGIN
            EXECUTE format(
                $q$INSERT INTO _qt_current
                 SELECT %L, queue_name, queue_size, max_queue_size, queue_utilization_pct,
                        write_rate_per_min, seconds_since_last_write, consecutive_failures, warning_level, time
                 FROM %I.queue_health_current$q$,
                _schema.name, _schema.name
            );
        EXCEPTION WHEN undefined_table THEN
            NULL;
        END;
    END LOOP;

    -- ── Final result: join live current with pre-computed benchmarks ──────
    RETURN QUERY
    WITH merged AS (
        SELECT
            c.*,
            COALESCE(b.p95_staleness_7d, 0)             AS _p95_staleness_7d,
            COALESCE(b.p95_utilization_pct_7d, 0)       AS _p95_utilization_pct_7d,
            COALESCE(b.p95_consecutive_failures_7d, 0)  AS _p95_consecutive_failures_7d,
            c.seconds_since_last_write / NULLIF(b.p95_staleness_7d, 0) AS staleness_ratio
        FROM _qt_current c
        LEFT JOIN health.mat_health_queue_benchmarks b
            ON c.domain = b.domain AND c.queue_name = b.queue_name
    ),
    with_severity AS (
        SELECT *,
            CASE
                WHEN _p95_staleness_7d = 0 OR staleness_ratio IS NULL THEN 0
                WHEN staleness_ratio <= 1.0  THEN 0
                WHEN staleness_ratio <= 3.0  THEN 1
                WHEN staleness_ratio <= 10.0 THEN 2
                ELSE 3
            END AS _gap_severity,
            CASE
                WHEN COALESCE(m.queue_utilization_pct, 0) < 10 THEN 0
                WHEN _p95_utilization_pct_7d > 0 THEN
                    CASE
                        WHEN m.queue_utilization_pct / _p95_utilization_pct_7d <= 2 THEN 0
                        WHEN m.queue_utilization_pct / _p95_utilization_pct_7d <= 4 THEN 1
                        WHEN m.queue_utilization_pct / _p95_utilization_pct_7d <= 8 THEN 2
                        ELSE 3
                    END
                WHEN m.queue_utilization_pct > 80 THEN 3
                WHEN m.queue_utilization_pct > 50 THEN 2
                WHEN m.queue_utilization_pct > 25 THEN 1
                ELSE 0
            END AS _util_severity,
            CASE
                WHEN COALESCE(m.consecutive_failures, 0) = 0 THEN 0
                WHEN _p95_consecutive_failures_7d > 0 THEN
                    CASE
                        WHEN m.consecutive_failures::float / _p95_consecutive_failures_7d <= 2 THEN 0
                        WHEN m.consecutive_failures::float / _p95_consecutive_failures_7d <= 4 THEN 1
                        WHEN m.consecutive_failures::float / _p95_consecutive_failures_7d <= 8 THEN 2
                        ELSE 3
                    END
                WHEN m.consecutive_failures > 5 THEN 3
                WHEN m.consecutive_failures > 3 THEN 2
                ELSE 1
            END AS _fail_severity
        FROM merged m
    )
    SELECT
        ws.domain,
        ws.queue_name,
        ws.queue_size,
        ws.max_queue_size,
        ws.queue_utilization_pct,
        ws._p95_utilization_pct_7d,
        ws.write_rate_per_min,
        ws.seconds_since_last_write,
        ws._p95_staleness_7d,
        ws.consecutive_failures,
        ws._p95_consecutive_failures_7d,
        ws._gap_severity,
        ws._util_severity,
        ws._fail_severity,
        GREATEST(ws._gap_severity, ws._util_severity, ws._fail_severity),
        CASE ws._gap_severity  WHEN 0 THEN 'NORMAL' WHEN 1 THEN 'ELEVATED' WHEN 2 THEN 'HIGH' ELSE 'ANOMALY' END,
        CASE ws._util_severity WHEN 0 THEN 'NORMAL' WHEN 1 THEN 'ELEVATED' WHEN 2 THEN 'HIGH' ELSE 'ANOMALY' END,
        CASE ws._fail_severity WHEN 0 THEN 'NORMAL' WHEN 1 THEN 'ELEVATED' WHEN 2 THEN 'HIGH' ELSE 'ANOMALY' END,
        CASE GREATEST(ws._gap_severity, ws._util_severity, ws._fail_severity)
            WHEN 0 THEN 'NORMAL' WHEN 1 THEN 'ELEVATED' WHEN 2 THEN 'HIGH' ELSE 'ANOMALY'
        END,
        GREATEST(ws._gap_severity, ws._util_severity, ws._fail_severity) >= 3,
        ws.snapshot_time
    FROM with_severity ws
    ORDER BY ws.domain, ws.queue_name;
END;
$fn$;

-- Thin wrapper VIEW so existing callers work unchanged
CREATE OR REPLACE VIEW health.v_health_queue_table AS
SELECT * FROM health._fn_queue_table();
