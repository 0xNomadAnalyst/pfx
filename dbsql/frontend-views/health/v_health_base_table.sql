-- =============================================================================
-- health.v_health_base_table
-- Base table activity with frequency-based staleness status
--
-- OPTIMISED: reads pre-computed stats from mat_health_base_activity instead
-- of looping over 21 tables with live MAX()/COUNT() queries per request.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

DROP VIEW IF EXISTS health.v_health_base_table CASCADE;
DROP FUNCTION IF EXISTS health._fn_base_table() CASCADE;

CREATE OR REPLACE VIEW health.v_health_base_table AS
SELECT
    b.schema_name,
    b.table_name,
    b.latest_time,
    b.minutes_since_latest,
    b.rows_last_hour,
    b.rows_last_24h,
    b.avg_rows_per_hour,
    b.sample_count,
    NULL::double precision AS p5_hourly_count,
    NULL::double precision AS p95_hourly_count,
    b.expected_gap_mins,
    b.gap_ratio,
    CASE
        WHEN b.expected_gap_mins IS NOT NULL AND b.expected_gap_mins > 0 THEN
            CASE
                WHEN b.gap_ratio <= 2.0  THEN 0
                WHEN b.gap_ratio <= 5.0  THEN 1
                WHEN b.gap_ratio <= 10.0 THEN 2
                ELSE 3
            END
        WHEN b.minutes_since_latest <= 1440  THEN 0
        WHEN b.minutes_since_latest <= 4320  THEN 1
        WHEN b.minutes_since_latest <= 10080 THEN 2
        ELSE 3
    END AS severity,
    CASE
        WHEN b.expected_gap_mins IS NOT NULL AND b.expected_gap_mins > 0 THEN
            CASE
                WHEN b.gap_ratio <= 2.0  THEN 'Active'
                WHEN b.gap_ratio <= 5.0  THEN 'Check'
                WHEN b.gap_ratio <= 10.0 THEN 'Stale'
                ELSE 'ANOMALY'
            END
        WHEN b.minutes_since_latest <= 1440  THEN 'Active'
        WHEN b.minutes_since_latest <= 4320  THEN 'Quiet'
        WHEN b.minutes_since_latest <= 10080 THEN 'Check'
        ELSE 'Stale'
    END AS status,
    CASE
        WHEN b.expected_gap_mins IS NOT NULL AND b.expected_gap_mins > 0 THEN b.gap_ratio > 10.0
        ELSE b.minutes_since_latest > 10080
    END AS is_red
FROM health.mat_health_base_activity b;
