-- =============================================================================
-- health.v_health_insert_timing
-- Current INSERT execution timing per tracked source table.
-- Reads the most recent row per table from mat_health_insert_timing.
--
-- recent_mean_ms = mean INSERT time over the last ~30s refresh window,
-- derived from pg_stat_statements deltas.  This is the direct signal for
-- BEFORE INSERT trigger slowness (e.g. unbounded queries scanning S3-tiered
-- chunks); v_health_base_table only infers this from row count changes.
--
-- Severity (based on recent_mean_ms):
--   0 = Normal    < 50 ms
--   1 = Elevated  50 – 500 ms
--   2 = Slow      500 – 5 000 ms
--   3 = Critical  ≥ 5 000 ms    (is_red = TRUE)
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

DROP VIEW IF EXISTS health.v_health_insert_timing CASCADE;
CREATE OR REPLACE VIEW health.v_health_insert_timing AS

SELECT
    m.schema_name,
    m.table_name,
    m.recent_mean_ms,
    m.calls_per_min,
    m.max_exec_ms,
    m.time AS refreshed_at,
    CASE
        WHEN m.recent_mean_ms IS NULL  THEN -1
        WHEN m.recent_mean_ms <    50  THEN  0
        WHEN m.recent_mean_ms <   500  THEN  1
        WHEN m.recent_mean_ms <  5000  THEN  2
        ELSE                                 3
    END AS severity,
    CASE
        WHEN m.recent_mean_ms IS NULL  THEN '—'
        WHEN m.recent_mean_ms <    50  THEN 'NORMAL'
        WHEN m.recent_mean_ms <   500  THEN 'ELEVATED'
        WHEN m.recent_mean_ms <  5000  THEN 'HIGH'
        ELSE                                'ANOMALY'
    END AS status,
    COALESCE(m.recent_mean_ms >= 5000, FALSE) AS is_red
FROM (
    SELECT DISTINCT ON (schema_name, table_name) *
    FROM health.mat_health_insert_timing
    ORDER BY schema_name, table_name, time DESC
) m
ORDER BY m.schema_name, m.table_name;
