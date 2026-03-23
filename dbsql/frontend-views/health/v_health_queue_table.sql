-- =============================================================================
-- health.v_health_queue_table
-- Queue health status with per-dimension severity (gap, util, failure)
--
-- OPTIMISED + HARDENED:
--   1. Loop-based dynamic SQL gathers current status per schema with a
--      time-bounded DISTINCT ON (avoids full-table scans into tiered storage).
--   2. 7-day P95 benchmarks pre-computed in mat_health_queue_benchmarks,
--      refreshed by refresh_mat_health_queue_benchmarks() (called via cronjob
--      as part of health.refresh_mat_health_all()).
--   3. Gap severity uses HYBRID scoring:
--      - capped dynamic baseline (prevents "P95 drift" after long incidents),
--      - absolute gap thresholds (queue-specific floors),
--      - passthrough from raw warning_level (warning/degraded/critical).
--   4. Thin VIEW wrapper preserves existing caller interface.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

-- ─── Materialized view: pre-computed 7-day P95 benchmarks ────────────────────
-- Created once; refreshed every ~30s by the cronjob via
-- health.refresh_mat_health_queue_benchmarks().

CREATE TABLE IF NOT EXISTS health.mat_health_queue_benchmarks (
    domain                       text    NOT NULL,
    queue_name                   text    NOT NULL,
    p95_staleness_7d             double precision,
    p95_utilization_pct_7d       double precision,
    p95_consecutive_failures_7d  double precision,
    refreshed_at                 timestamptz DEFAULT NOW(),
    PRIMARY KEY (domain, queue_name)
);

-- ─── Procedure: refresh the benchmarks (called by refresh_mat_health_all) ────
CREATE OR REPLACE PROCEDURE health.refresh_mat_health_queue_benchmarks()
LANGUAGE plpgsql
AS $proc$
DECLARE
    _schema RECORD;
BEGIN
    TRUNCATE health.mat_health_queue_benchmarks;

    FOR _schema IN
        SELECT * FROM (VALUES
            ('dexes'), ('exponent'), ('kamino_lend')
        ) AS s(name)
    LOOP
        BEGIN
            EXECUTE format(
                $q$INSERT INTO health.mat_health_queue_benchmarks
                   (domain, queue_name, p95_staleness_7d,
                    p95_utilization_pct_7d, p95_consecutive_failures_7d, refreshed_at)
                 SELECT %L, queue_name,
                        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY seconds_since_last_write),
                        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY queue_utilization_pct),
                        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY consecutive_failures),
                        NOW()
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
END;
$proc$;


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
    -- Time-bounded DISTINCT ON avoids scanning into tiered/OSM storage.
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
        warning_message         text,
        snapshot_time           timestamptz
    ) ON COMMIT DROP;
    TRUNCATE _qt_current;

    FOR _schema IN
        SELECT * FROM (VALUES
            ('dexes'), ('exponent'), ('kamino_lend')
        ) AS s(name)
    LOOP
        BEGIN
            EXECUTE format(
                $q$INSERT INTO _qt_current
                 SELECT %L, sub.queue_name, sub.queue_size, sub.max_queue_size, sub.queue_utilization_pct,
                        sub.write_rate_per_min, sub.seconds_since_last_write, sub.consecutive_failures,
                        sub.warning_level, sub.warning_message, sub.time
                 FROM (
                     SELECT DISTINCT ON (queue_name) *
                     FROM %I.queue_health
                     WHERE time > NOW() - INTERVAL '1 hour'
                     ORDER BY queue_name, time DESC
                 ) sub$q$,
                _schema.name, _schema.name
            );
        EXCEPTION WHEN undefined_table THEN
            NULL;
        END;
    END LOOP;

    -- ── Inject synthetic rows for known queues with no recent data ────────
    -- If a process dies, it stops writing to queue_health entirely.
    -- Benchmarks retain the historical queue list; any queue present there
    -- but absent from _qt_current is likely a dead process.
    INSERT INTO _qt_current (domain, queue_name, snapshot_time)
    SELECT b.domain, b.queue_name, NULL
    FROM health.mat_health_queue_benchmarks b
    WHERE NOT EXISTS (
        SELECT 1 FROM _qt_current c
        WHERE c.domain = b.domain AND c.queue_name = b.queue_name
    );

    -- ── Final result: join live current with pre-computed benchmarks ──────
    RETURN QUERY
    WITH merged AS (
        SELECT
            c.*,
            COALESCE(b.p95_staleness_7d, 0)             AS _p95_staleness_7d,
            COALESCE(b.p95_utilization_pct_7d, 0)       AS _p95_utilization_pct_7d,
            COALESCE(b.p95_consecutive_failures_7d, 0)  AS _p95_consecutive_failures_7d,
            c.seconds_since_last_write
                / NULLIF(
                    LEAST(
                        COALESCE(b.p95_staleness_7d, 0),
                        CASE
                            WHEN LOWER(COALESCE(c.queue_name, '')) LIKE '%event%'
                                 OR LOWER(COALESCE(c.queue_name, '')) LIKE '%txn%'
                                 OR LOWER(COALESCE(c.queue_name, '')) LIKE '%transaction%'
                            THEN 86400.0  -- 24h cap for sparse event-driven queues
                            ELSE 3600.0   -- 1h cap for state/write-on-difference queues
                        END
                    ),
                    0
                ) AS staleness_ratio
        FROM _qt_current c
        LEFT JOIN health.mat_health_queue_benchmarks b
            ON c.domain = b.domain AND c.queue_name = b.queue_name
    ),
    with_severity AS (
        SELECT *,
            CASE
                WHEN m.snapshot_time IS NULL THEN 3
                -- Idle-safe mode:
                -- For write-on-difference pipelines, long periods with no writes
                -- are normal when queues are empty and there are no failures.
                -- Event/txn queues intentionally do not use this bypass.
                WHEN COALESCE(m.queue_size, 0) = 0
                     AND COALESCE(m.consecutive_failures, 0) = 0
                     AND NOT (
                         LOWER(COALESCE(m.queue_name, '')) LIKE '%event%'
                         OR LOWER(COALESCE(m.queue_name, '')) LIKE '%txn%'
                         OR LOWER(COALESCE(m.queue_name, '')) LIKE '%transaction%'
                     )
                     AND (
                         LOWER(COALESCE(m.warning_level, 'ok')) NOT IN ('degraded', 'critical', 'error')
                         OR (
                             LOWER(COALESCE(m.warning_level, 'ok')) = 'warning'
                             AND COALESCE(m.write_rate_per_min, 0) = 0
                             AND COALESCE(m.warning_message, '') ILIKE 'No writes for %'
                         )
                     )
                THEN 0
                ELSE GREATEST(
                    -- Dynamic baseline signal (queue-type cap to avoid desensitisation)
                    CASE
                        WHEN staleness_ratio IS NULL THEN 0
                        WHEN staleness_ratio <= 1.25 THEN 0
                        WHEN staleness_ratio <= 3.0  THEN 1
                        WHEN staleness_ratio <= 10.0 THEN 2
                        ELSE 3
                    END,
                    -- Absolute wall-clock guardrails (queue-specific)
                    CASE
                        WHEN COALESCE(m.seconds_since_last_write, 0) >=
                             CASE
                                 WHEN LOWER(COALESCE(m.queue_name, '')) LIKE '%event%'
                                      OR LOWER(COALESCE(m.queue_name, '')) LIKE '%txn%'
                                      OR LOWER(COALESCE(m.queue_name, '')) LIKE '%transaction%'
                                 THEN 345600.0 ELSE 3600.0 END THEN 3
                        WHEN COALESCE(m.seconds_since_last_write, 0) >=
                             CASE
                                 WHEN LOWER(COALESCE(m.queue_name, '')) LIKE '%event%'
                                      OR LOWER(COALESCE(m.queue_name, '')) LIKE '%txn%'
                                      OR LOWER(COALESCE(m.queue_name, '')) LIKE '%transaction%'
                                 THEN 172800.0 ELSE 900.0 END THEN 2
                        WHEN COALESCE(m.seconds_since_last_write, 0) >=
                             CASE
                                 WHEN LOWER(COALESCE(m.queue_name, '')) LIKE '%event%'
                                      OR LOWER(COALESCE(m.queue_name, '')) LIKE '%txn%'
                                      OR LOWER(COALESCE(m.queue_name, '')) LIKE '%transaction%'
                                 THEN 86400.0 ELSE 300.0 END THEN 1
                        ELSE 0
                    END,
                    -- Raw queue warning passthrough
                    CASE LOWER(COALESCE(m.warning_level, 'ok'))
                        WHEN 'warning' THEN
                            CASE
                                WHEN COALESCE(m.queue_size, 0) = 0
                                     AND COALESCE(m.consecutive_failures, 0) = 0
                                     AND COALESCE(m.write_rate_per_min, 0) = 0
                                     AND COALESCE(m.warning_message, '') ILIKE 'No writes for %'
                                THEN 0
                                ELSE 1
                            END
                        WHEN 'critical' THEN 3
                        WHEN 'error'    THEN 3
                        WHEN 'degraded' THEN 2
                        ELSE 0
                    END
                )
            END AS _gap_severity,
            CASE
                WHEN m.snapshot_time IS NULL THEN 3
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
                WHEN m.snapshot_time IS NULL THEN 3
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
