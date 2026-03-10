-- =============================================================================
-- health.v_health_cagg_table
-- CAGG refresh health — compares CAGG bucket times to base table times
--
-- OPTIMISED: reads pre-computed stats from mat_health_cagg_status instead
-- of running 45 separate MAX()/COUNT(DISTINCT) queries per request.
-- Status/severity logic applied as a thin computation over the mat table.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

DROP VIEW IF EXISTS health.v_health_cagg_table CASCADE;
DROP FUNCTION IF EXISTS health._fn_cagg_table() CASCADE;

CREATE OR REPLACE VIEW health.v_health_cagg_table AS
SELECT
    c.view_schema,
    c.view_name,
    c.source_table,
    c.cagg_latest,
    c.source_latest,
    c.cagg_age_mins,
    c.source_age_mins,
    c.refresh_lag_mins,
    c.expected_gap_mins,
    CASE
        WHEN c.cagg_age_mins IS NULL AND c.source_age_mins IS NULL THEN 'No data'
        WHEN c.source_age_mins IS NULL OR c.source_age_mins > c.expected_gap_mins * 2.0 THEN 'Source Stale'
        WHEN c.refresh_lag_mins IS NOT NULL AND c.refresh_lag_mins > 15 THEN 'Refresh Broken'
        WHEN c.refresh_lag_mins IS NOT NULL AND c.refresh_lag_mins > 5  THEN 'Refresh Delayed'
        ELSE 'Refresh OK'
    END AS status,
    CASE
        WHEN c.cagg_age_mins IS NULL AND c.source_age_mins IS NULL THEN -1
        WHEN c.source_age_mins IS NULL OR c.source_age_mins > c.expected_gap_mins * 2.0 THEN 1
        WHEN c.refresh_lag_mins IS NOT NULL AND c.refresh_lag_mins > 15 THEN 3
        WHEN c.refresh_lag_mins IS NOT NULL AND c.refresh_lag_mins > 5  THEN 1
        ELSE 0
    END AS severity,
    (c.source_age_mins IS NOT NULL
        AND c.source_age_mins <= c.expected_gap_mins * 2.0
        AND c.refresh_lag_mins IS NOT NULL
        AND c.refresh_lag_mins > 15) AS is_red
FROM health.mat_health_cagg_status c;
