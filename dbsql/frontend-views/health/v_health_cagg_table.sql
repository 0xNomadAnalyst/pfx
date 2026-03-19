-- =============================================================================
-- health._fn_cagg_table  (onyc)
-- Reads pre-materialised health.mat_health_cagg_status.
-- No dynamic SQL / loop — pure SELECT from intermediate table.
--
-- Depends on: health.mat_health_cagg_status
--             (refreshed by health.refresh_mat_health_all)
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

DROP VIEW  IF EXISTS health.v_health_cagg_table CASCADE;
DROP FUNCTION IF EXISTS health._fn_cagg_table();

CREATE OR REPLACE FUNCTION health._fn_cagg_table()
RETURNS TABLE (
    view_schema        text,
    view_name          text,
    source_table       text,
    cagg_latest        timestamptz,
    source_latest      timestamptz,
    cagg_age_mins      double precision,
    source_age_mins    double precision,
    refresh_lag_mins   double precision,
    expected_gap_mins  double precision,
    status             text,
    severity           integer,
    is_red             boolean
)
LANGUAGE sql STABLE
AS $fn$
    SELECT
        s.view_schema,
        s.view_name,
        s.source_table,
        s.cagg_latest,
        s.source_latest,
        EXTRACT(EPOCH FROM (NOW() - s.cagg_latest))   / 60.0,
        EXTRACT(EPOCH FROM (NOW() - s.source_latest))  / 60.0,
        EXTRACT(EPOCH FROM (s.source_latest - s.cagg_latest)) / 60.0,
        s.expected_gap_mins,
        CASE
            WHEN s.cagg_latest IS NULL AND s.source_latest IS NULL THEN 'No data'
            WHEN s.source_latest IS NULL
                 OR (EXTRACT(EPOCH FROM (NOW() - s.source_latest)) / 60.0) > s.expected_gap_mins * 2.0
                 THEN 'Source Stale'
            WHEN (EXTRACT(EPOCH FROM (s.source_latest - s.cagg_latest)) / 60.0) > 15 THEN 'Refresh Broken'
            WHEN (EXTRACT(EPOCH FROM (s.source_latest - s.cagg_latest)) / 60.0) > 5  THEN 'Refresh Delayed'
            ELSE 'Refresh OK'
        END,
        CASE
            WHEN s.cagg_latest IS NULL AND s.source_latest IS NULL THEN -1
            WHEN s.source_latest IS NULL THEN 3
            WHEN (EXTRACT(EPOCH FROM (NOW() - s.source_latest)) / 60.0) > s.expected_gap_mins * 5.0 THEN 3
            WHEN (EXTRACT(EPOCH FROM (NOW() - s.source_latest)) / 60.0) > s.expected_gap_mins * 2.0 THEN 2
            WHEN (EXTRACT(EPOCH FROM (s.source_latest - s.cagg_latest)) / 60.0) > 15 THEN 3
            WHEN (EXTRACT(EPOCH FROM (s.source_latest - s.cagg_latest)) / 60.0) > 5  THEN 1
            ELSE 0
        END,
        CASE
            WHEN s.source_latest IS NULL THEN TRUE
            WHEN (EXTRACT(EPOCH FROM (NOW() - s.source_latest)) / 60.0) > s.expected_gap_mins * 5.0 THEN TRUE
            WHEN (EXTRACT(EPOCH FROM (NOW() - s.source_latest)) / 60.0) <= s.expected_gap_mins * 2.0
                 AND (EXTRACT(EPOCH FROM (s.source_latest - s.cagg_latest)) / 60.0) > 15 THEN TRUE
            ELSE FALSE
        END
    FROM health.mat_health_cagg_status s
    ORDER BY s.view_schema, s.view_name;
$fn$;

CREATE OR REPLACE VIEW health.v_health_cagg_table AS
SELECT * FROM health._fn_cagg_table();
