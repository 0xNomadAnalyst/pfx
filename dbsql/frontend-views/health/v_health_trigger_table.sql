-- =============================================================================
-- health.v_health_trigger_table
-- Trigger function health — checks if PostgreSQL triggers are firing correctly
--
-- OPTIMISED: reads pre-computed stats from mat_health_trigger_stats instead
-- of scanning 7 days of dexes.src_tx_events per request.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

DROP VIEW IF EXISTS health.v_health_trigger_table CASCADE;
CREATE OR REPLACE VIEW health.v_health_trigger_table AS

SELECT
    m.domain,
    m.trigger_name,
    m.description,
    m.source_latest,
    m.derived_latest,
    m.source_rows_1h,
    m.derived_rows_1h,
    EXTRACT(EPOCH FROM (m.source_latest - m.derived_latest)) / 60.0 AS lag_mins,
    CASE WHEN m.source_rows_1h > 0
         THEN m.derived_rows_1h::float / m.source_rows_1h
         ELSE NULL
    END AS coverage_ratio,
    CASE
        WHEN m.source_latest IS NULL              THEN -1
        WHEN m.derived_latest IS NULL             THEN 3
        WHEN EXTRACT(EPOCH FROM (m.source_latest - m.derived_latest)) / 60.0 > 10 THEN 1
        WHEN m.source_rows_1h > 0
             AND m.derived_rows_1h < m.source_rows_1h * 0.5 THEN 2
        ELSE 0
    END AS severity,
    CASE
        WHEN m.source_latest IS NULL              THEN 'No source data'
        WHEN m.derived_latest IS NULL             THEN 'Trigger not firing'
        WHEN EXTRACT(EPOCH FROM (m.source_latest - m.derived_latest)) / 60.0 > 10 THEN 'Lagging'
        WHEN m.source_rows_1h > 0
             AND m.derived_rows_1h < m.source_rows_1h * 0.5 THEN 'Low coverage'
        ELSE 'Healthy'
    END AS status,
    (m.source_latest IS NOT NULL AND m.derived_latest IS NULL) AS is_red
FROM health.mat_health_trigger_stats m
ORDER BY m.domain, m.trigger_name;
