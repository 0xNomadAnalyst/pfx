-- =============================================================================
-- health.v_health_base_chart(p_schema, p_lookback, p_interval)
--
-- Returns time-bucketed row counts for base tables, categorised as
-- 'Transaction Events' vs 'Account Updates'.
--
-- OPTIMISED: reads pre-aggregated hourly counts from mat_health_base_hourly
-- instead of scanning multiple base tables per request. Re-buckets from
-- the 1-hour grain to the requested interval.
--
-- Parameters:
--   p_schema   TEXT — domain: 'dexes','exponent','kamino_lend'
--   p_lookback TEXT — history window, e.g. '7 days'
--   p_interval TEXT — bucket width, e.g. '1 hour', '4 hours'
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

DROP FUNCTION IF EXISTS health.v_health_base_chart(TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION health.v_health_base_chart(
    p_schema   TEXT,
    p_lookback TEXT DEFAULT '7 days',
    p_interval TEXT DEFAULT '1 hour'
)
RETURNS TABLE (
    bucket        TIMESTAMPTZ,
    category      TEXT,
    avg_row_count DOUBLE PRECISION
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _cutoff  TIMESTAMPTZ := NOW() - p_lookback::interval;
    _interval INTERVAL   := p_interval::interval;
BEGIN
    RETURN QUERY
    WITH hourly AS (
        SELECT
            h.category,
            h.hour,
            SUM(h.row_count) AS hourly_rows
        FROM health.mat_health_base_hourly h
        WHERE h.schema_name = p_schema
          AND h.hour >= _cutoff
        GROUP BY h.category, h.hour
    )
    SELECT
        time_bucket(_interval, hr.hour) AS bucket,
        hr.category,
        AVG(hr.hourly_rows) AS avg_row_count
    FROM hourly hr
    GROUP BY 1, 2
    ORDER BY 1, 2;
END;
$$;
