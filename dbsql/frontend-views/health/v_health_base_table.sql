-- =============================================================================
-- health._fn_base_table  (onyc)
-- Reads pre-materialised health.mat_health_base_activity + base_hourly.
-- No dynamic SQL / loop — pure SELECT from intermediate tables.
--
-- Depends on: health.mat_health_base_activity, health.mat_health_base_hourly
--             (both refreshed by health.refresh_mat_health_all)
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

DROP VIEW  IF EXISTS health.v_health_base_table CASCADE;
DROP FUNCTION IF EXISTS health._fn_base_table();

CREATE OR REPLACE FUNCTION health._fn_base_table()
RETURNS TABLE (
    schema_name        text,
    table_name         text,
    latest_time        timestamptz,
    minutes_since_latest double precision,
    rows_last_hour     bigint,
    rows_last_24h      bigint,
    avg_rows_per_hour  double precision,
    sample_count       bigint,
    p5_hourly_count    double precision,
    p95_hourly_count   double precision,
    expected_gap_mins  double precision,
    gap_ratio          double precision,
    severity           integer,
    status             text,
    is_red             boolean
)
LANGUAGE sql STABLE
AS $fn$
    WITH hourly_stats AS (
        SELECT
            h.schema_name,
            h.table_name,
            PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY h.row_count) AS p5,
            PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY h.row_count) AS p95
        FROM health.mat_health_base_hourly h
        WHERE h.hour > NOW() - INTERVAL '7 days'
        GROUP BY h.schema_name, h.table_name
    ),
    enriched AS (
        SELECT
            a.schema_name,
            a.table_name,
            a.latest_time,
            EXTRACT(EPOCH FROM (NOW() - a.latest_time)) / 60.0 AS msl,
            a.rows_last_hour,
            a.rows_last_24h,
            a.avg_rows_per_hour,
            a.sample_count,
            COALESCE(hs.p5, 0)  AS p5,
            COALESCE(hs.p95, 0) AS p95,
            a.expected_gap_mins AS egm,
            CASE WHEN a.expected_gap_mins IS NOT NULL AND a.expected_gap_mins > 0
                 THEN (EXTRACT(EPOCH FROM (NOW() - a.latest_time)) / 60.0) / a.expected_gap_mins
                 ELSE NULL
            END AS gr
        FROM health.mat_health_base_activity a
        LEFT JOIN hourly_stats hs
            ON a.schema_name = hs.schema_name AND a.table_name = hs.table_name
        WHERE a.latest_time IS NOT NULL
    )
    SELECT
        e.schema_name,
        e.table_name,
        e.latest_time,
        e.msl,
        e.rows_last_hour,
        e.rows_last_24h,
        e.avg_rows_per_hour,
        e.sample_count,
        e.p5,
        e.p95,
        e.egm,
        e.gr,
        CASE
            WHEN e.egm IS NOT NULL AND e.egm > 0 THEN
                CASE WHEN e.gr <= 2.0 THEN 0 WHEN e.gr <= 5.0 THEN 1
                     WHEN e.gr <= 10.0 THEN 2 ELSE 3 END
            WHEN e.msl <= 1440 THEN 0 WHEN e.msl <= 4320 THEN 1
            WHEN e.msl <= 10080 THEN 2 ELSE 3
        END,
        CASE
            WHEN e.egm IS NOT NULL AND e.egm > 0 THEN
                CASE WHEN e.gr <= 2.0 THEN 'Active' WHEN e.gr <= 5.0 THEN 'Check'
                     WHEN e.gr <= 10.0 THEN 'Stale' ELSE 'ANOMALY' END
            WHEN e.msl <= 1440 THEN 'Active' WHEN e.msl <= 4320 THEN 'Quiet'
            WHEN e.msl <= 10080 THEN 'Check' ELSE 'Stale'
        END,
        CASE
            WHEN e.egm IS NOT NULL AND e.egm > 0 THEN e.gr > 10.0
            ELSE e.msl > 10080
        END
    FROM enriched e
    ORDER BY e.schema_name, e.msl DESC;
$fn$;

CREATE OR REPLACE VIEW health.v_health_base_table AS
SELECT * FROM health._fn_base_table();
