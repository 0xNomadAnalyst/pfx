-- =============================================================================
-- health.v_health_queue_chart(p_schema, p_attribute, p_lookback, p_interval)
--
-- Returns time-bucketed queue health metrics for charting.
-- All aggregations use AVG within each bucket.
--
-- OPTIMISED: only scans the requested schema's queue_health table
-- instead of scanning ALL 4 schemas then filtering.
--
-- Parameters:
--   p_schema    TEXT  — domain to filter: 'dexes','exponent','kamino_lend'
--   p_attribute TEXT  — metric to chart: 'Queue Size','Write Rate','Gap Size','Failures'
--   p_lookback  TEXT  — history window as interval literal, e.g. '24 hours', '7 days'
--   p_interval  TEXT  — bucket width as interval literal, e.g. '1 minute', '5 minutes', '1 hour'
--
-- Example:
--   SELECT * FROM health.v_health_queue_chart('dexes', 'Gap Size', '24 hours', '5 minutes');
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

DROP FUNCTION IF EXISTS health.v_health_queue_chart(TEXT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION health.v_health_queue_chart(
    p_schema   TEXT,
    p_attribute TEXT,
    p_lookback TEXT DEFAULT '24 hours',
    p_interval TEXT DEFAULT '1 minute'
)
RETURNS TABLE (
    bucket      TIMESTAMPTZ,
    queue_name  TEXT,
    avg_value   DOUBLE PRECISION
)
LANGUAGE plpgsql VOLATILE
AS $$
DECLARE
    _cutoff   timestamptz := NOW() - p_lookback::interval;
    _interval interval    := p_interval::interval;
BEGIN
    -- ── Temp table for the single schema's raw data ──────────────────────
    CREATE TEMP TABLE IF NOT EXISTS _qch_raw (
        t          timestamptz,
        queue_name text,
        val        double precision
    ) ON COMMIT DROP;
    TRUNCATE _qch_raw;

    -- ── Only scan the requested schema ───────────────────────────────────
    IF p_schema = 'dexes' THEN
        INSERT INTO _qch_raw
        SELECT qh.time, qh.queue_name::text,
               CASE p_attribute
                   WHEN 'Queue Size'  THEN qh.queue_utilization_pct::double precision
                   WHEN 'Write Rate'  THEN qh.write_rate_per_min::double precision
                   WHEN 'Gap Size'    THEN qh.seconds_since_last_write::double precision
                   WHEN 'Failures'    THEN qh.consecutive_failures::double precision
               END
        FROM dexes.queue_health qh
        WHERE qh.time > _cutoff;

    ELSIF p_schema = 'exponent' THEN
        INSERT INTO _qch_raw
        SELECT qh.time, qh.queue_name,
               CASE p_attribute
                   WHEN 'Queue Size'  THEN qh.queue_utilization_pct::double precision
                   WHEN 'Write Rate'  THEN qh.write_rate_per_min::double precision
                   WHEN 'Gap Size'    THEN qh.seconds_since_last_write::double precision
                   WHEN 'Failures'    THEN qh.consecutive_failures::double precision
               END
        FROM exponent.queue_health qh
        WHERE qh.time > _cutoff;

    ELSIF p_schema = 'kamino_lend' THEN
        INSERT INTO _qch_raw
        SELECT qh.time, qh.queue_name,
               CASE p_attribute
                   WHEN 'Queue Size'  THEN qh.queue_utilization_pct::double precision
                   WHEN 'Write Rate'  THEN qh.write_rate_per_min::double precision
                   WHEN 'Gap Size'    THEN qh.seconds_since_last_write::double precision
                   WHEN 'Failures'    THEN qh.consecutive_failures::double precision
               END
        FROM kamino_lend.queue_health qh
        WHERE qh.time > _cutoff;

    END IF;

    -- ── Shared aggregation ───────────────────────────────────────────────
    RETURN QUERY
    SELECT
        time_bucket(_interval, r.t) AS bucket,
        r.queue_name,
        AVG(r.val) AS avg_value
    FROM _qch_raw r
    GROUP BY 1, 2
    ORDER BY 1, 2;
END;
$$;
