-- =============================================================================
-- health.v_health_insert_timing_chart(p_schema, p_attribute, p_lookback, p_interval)
--
-- Returns time-bucketed INSERT timing metrics for charting, matching the
-- calling convention of v_health_queue_chart.
--
-- Parameters:
--   p_schema    TEXT — domain: 'dexes', 'exponent', 'kamino_lend'
--   p_attribute TEXT — 'Mean Insert ms' or 'Calls/min'
--   p_lookback  TEXT — history window, e.g. '24 hours', '7 days'
--   p_interval  TEXT — bucket width, e.g. '1 minute', '5 minutes'
--
-- Example:
--   SELECT * FROM health.v_health_insert_timing_chart('dexes', 'Mean Insert ms', '24 hours', '5 minutes');
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

DROP FUNCTION IF EXISTS health.v_health_insert_timing_chart(TEXT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION health.v_health_insert_timing_chart(
    p_schema    TEXT,
    p_attribute TEXT DEFAULT 'Mean Insert ms',
    p_lookback  TEXT DEFAULT '24 hours',
    p_interval  TEXT DEFAULT '5 minutes'
)
RETURNS TABLE (
    bucket     TIMESTAMPTZ,
    table_name TEXT,
    avg_value  DOUBLE PRECISION
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _cutoff   TIMESTAMPTZ := NOW() - p_lookback::interval;
    _interval INTERVAL    := p_interval::interval;
BEGIN
    RETURN QUERY
    SELECT
        time_bucket(_interval, m.time) AS bucket,
        m.table_name,
        AVG(
            CASE p_attribute
                WHEN 'Mean Insert ms' THEN m.recent_mean_ms
                WHEN 'Calls/min'      THEN m.calls_per_min
            END
        )::DOUBLE PRECISION AS avg_value
    FROM health.mat_health_insert_timing m
    WHERE m.schema_name = p_schema
      AND m.time >= _cutoff
      AND m.recent_mean_ms IS NOT NULL   -- skip first-cycle rows with no delta yet
    GROUP BY 1, 2
    ORDER BY 1, 2;
END;
$$;
