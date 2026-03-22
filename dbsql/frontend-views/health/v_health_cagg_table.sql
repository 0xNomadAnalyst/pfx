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
    WITH base AS (
        SELECT
            s.view_schema,
            s.view_name,
            s.source_table,
            s.cagg_latest,
            s.source_latest,
            EXTRACT(EPOCH FROM (NOW() - s.cagg_latest))   / 60.0 AS cagg_age_mins,
            EXTRACT(EPOCH FROM (NOW() - s.source_latest)) / 60.0 AS source_age_mins,
            EXTRACT(EPOCH FROM (s.source_latest - s.cagg_latest)) / 60.0 AS refresh_lag_mins,
            s.expected_gap_mins,
            (
                (s.cagg_latest IS NULL OR (EXTRACT(EPOCH FROM (NOW() - s.cagg_latest)) / 60.0) > 1440.0)
                AND
                (s.source_latest IS NULL OR (EXTRACT(EPOCH FROM (NOW() - s.source_latest)) / 60.0) > 1440.0)
            ) AS no_recent,
            GREATEST(COALESCE(s.expected_gap_mins, 120.0), 15.0) AS dormancy_lag_thresh
        FROM health.mat_health_cagg_status s
    )
    SELECT
        b.view_schema,
        b.view_name,
        b.source_table,
        b.cagg_latest,
        b.source_latest,
        b.cagg_age_mins,
        b.source_age_mins,
        b.refresh_lag_mins,
        b.expected_gap_mins,
        CASE
            WHEN b.cagg_latest IS NULL AND b.source_latest IS NULL THEN 'No data ever'
            WHEN b.no_recent
                 AND b.cagg_latest IS NOT NULL
                 AND b.source_latest IS NOT NULL
                 AND COALESCE(b.refresh_lag_mins, 0) <= b.dormancy_lag_thresh
                 THEN 'Dormant (expected)'
            WHEN b.no_recent THEN 'Dormant (lagging)'
            WHEN b.source_latest IS NULL THEN 'Source Stale'
            WHEN b.source_age_mins > GREATEST(COALESCE(b.expected_gap_mins, 120.0) * 2.0, 120.0)
                 THEN 'Source Stale'
            WHEN b.refresh_lag_mins IS NOT NULL
                 AND b.refresh_lag_mins > 15
                 AND (b.expected_gap_mins IS NULL OR b.refresh_lag_mins > b.expected_gap_mins)
                 THEN 'Refresh Broken'
            WHEN b.refresh_lag_mins IS NOT NULL
                 AND b.refresh_lag_mins > 5
                 AND (b.expected_gap_mins IS NULL OR b.refresh_lag_mins > b.expected_gap_mins)
                 THEN 'Refresh Delayed'
            ELSE 'Refresh OK'
        END AS status,
        CASE
            WHEN b.cagg_latest IS NULL AND b.source_latest IS NULL THEN -1
            WHEN b.no_recent
                 AND b.cagg_latest IS NOT NULL
                 AND b.source_latest IS NOT NULL
                 AND COALESCE(b.refresh_lag_mins, 0) <= b.dormancy_lag_thresh
                 THEN 0
            WHEN b.no_recent THEN 3
            WHEN b.source_latest IS NULL THEN 3
            WHEN b.source_age_mins > GREATEST(COALESCE(b.expected_gap_mins, 120.0) * 5.0, 360.0) THEN 3
            WHEN b.source_age_mins > GREATEST(COALESCE(b.expected_gap_mins, 120.0) * 2.0, 120.0) THEN 2
            WHEN b.refresh_lag_mins IS NOT NULL
                 AND b.refresh_lag_mins > 15
                 AND (b.expected_gap_mins IS NULL OR b.refresh_lag_mins > b.expected_gap_mins)
                 THEN 3
            WHEN b.refresh_lag_mins IS NOT NULL
                 AND b.refresh_lag_mins > 5
                 AND (b.expected_gap_mins IS NULL OR b.refresh_lag_mins > b.expected_gap_mins)
                 THEN 1
            ELSE 0
        END AS severity,
        CASE
            WHEN b.cagg_latest IS NULL AND b.source_latest IS NULL THEN FALSE
            WHEN b.no_recent
                 AND b.cagg_latest IS NOT NULL
                 AND b.source_latest IS NOT NULL
                 AND COALESCE(b.refresh_lag_mins, 0) <= b.dormancy_lag_thresh
                 THEN FALSE
            WHEN b.no_recent THEN TRUE
            WHEN b.source_latest IS NULL THEN TRUE
            WHEN b.source_age_mins > GREATEST(COALESCE(b.expected_gap_mins, 120.0) * 5.0, 360.0) THEN TRUE
            WHEN b.source_age_mins <= GREATEST(COALESCE(b.expected_gap_mins, 120.0) * 2.0, 120.0)
                 AND b.refresh_lag_mins IS NOT NULL
                 AND b.refresh_lag_mins > 15
                 AND (b.expected_gap_mins IS NULL OR b.refresh_lag_mins > b.expected_gap_mins)
                 THEN TRUE
            ELSE FALSE
        END AS is_red
    FROM base b
    ORDER BY b.view_schema, b.view_name;
$fn$;

CREATE OR REPLACE VIEW health.v_health_cagg_table AS
SELECT * FROM health._fn_cagg_table();
