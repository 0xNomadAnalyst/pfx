-- get_view_xp_timeseries: Cross-protocol timeseries re-bucketing function.
-- Reads from mat_xp_ts_1m (1-minute grain) and aggregates to the requested
-- bucket interval. Serves the time-series charts on the global ecosystem page.
--
-- Parameters:
--   bucket_interval  TEXT  e.g. '2 minutes', '1 hour', '1 day'
--   from_ts          TIMESTAMPTZ  start of window (default NOW() - 1 hour)
--   to_ts            TIMESTAMPTZ  end of window   (default NOW())

CREATE OR REPLACE FUNCTION cross_protocol.get_view_xp_timeseries(
    bucket_interval TEXT DEFAULT '1 minute',
    from_ts TIMESTAMPTZ DEFAULT NOW() - INTERVAL '1 hour',
    to_ts   TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
    bucket_time              TIMESTAMPTZ,
    -- TVL
    onyc_in_dexes            NUMERIC,
    onyc_in_kamino           NUMERIC,
    onyc_in_exponent         NUMERIC,
    onyc_tracked_total       NUMERIC,
    onyc_in_dexes_pct        NUMERIC,
    onyc_in_kamino_pct       NUMERIC,
    onyc_in_exponent_pct     NUMERIC,
    -- DEX activity
    dex_swap_volume          NUMERIC,
    dex_lp_volume            NUMERIC,
    dex_total_volume         NUMERIC,
    -- Kamino activity
    kam_total_volume         NUMERIC,
    -- Exponent activity
    exp_total_volume         NUMERIC,
    -- Cross-protocol totals
    all_protocol_volume      NUMERIC,
    dex_volume_pct           NUMERIC,
    kam_volume_pct           NUMERIC,
    exp_volume_pct           NUMERIC,
    -- Yields
    kam_onyc_supply_apy      NUMERIC,
    exp_weighted_implied_apy NUMERIC
) AS $$
DECLARE
    v_interval INTERVAL;
BEGIN
    BEGIN
        v_interval := bucket_interval::INTERVAL;
    EXCEPTION WHEN OTHERS THEN
        v_interval := INTERVAL '1 minute';
    END;

    RETURN QUERY
    WITH rebucketed AS (
        SELECT
            time_bucket(v_interval, m.bucket_time) AS bt,
            -- TVL: take last value within the larger bucket
            LAST(m.onyc_in_dexes,    m.bucket_time) AS onyc_in_dexes,
            LAST(m.onyc_in_kamino,   m.bucket_time) AS onyc_in_kamino,
            LAST(m.onyc_in_exponent, m.bucket_time) AS onyc_in_exponent,
            LAST(m.onyc_tracked_total, m.bucket_time) AS onyc_tracked_total,
            -- Activity: sum within the larger bucket
            SUM(m.dex_swap_volume)    AS dex_swap_volume,
            SUM(m.dex_lp_volume)      AS dex_lp_volume,
            SUM(m.dex_total_volume)   AS dex_total_volume,
            SUM(m.kam_total_volume)   AS kam_total_volume,
            SUM(m.exp_total_volume)   AS exp_total_volume,
            SUM(m.all_protocol_volume) AS all_protocol_volume,
            -- Yields: last value
            LAST(m.kam_onyc_supply_apy,        m.bucket_time) AS kam_supply_apy,
            LAST(m.exp_weighted_implied_apy,   m.bucket_time) AS exp_implied_apy
        FROM cross_protocol.mat_xp_ts_1m m
        WHERE m.bucket_time >= from_ts
          AND m.bucket_time <  to_ts
        GROUP BY bt
    )
    SELECT
        r.bt,
        r.onyc_in_dexes,
        r.onyc_in_kamino,
        r.onyc_in_exponent,
        r.onyc_tracked_total,
        -- Re-derive percentages from the rebucketed TVL totals
        ROUND(COALESCE(r.onyc_in_dexes    / NULLIF(r.onyc_tracked_total, 0) * 100, 0)::NUMERIC, 1),
        ROUND(COALESCE(r.onyc_in_kamino   / NULLIF(r.onyc_tracked_total, 0) * 100, 0)::NUMERIC, 1),
        ROUND(COALESCE(r.onyc_in_exponent / NULLIF(r.onyc_tracked_total, 0) * 100, 0)::NUMERIC, 1),
        r.dex_swap_volume,
        r.dex_lp_volume,
        r.dex_total_volume,
        r.kam_total_volume,
        r.exp_total_volume,
        r.all_protocol_volume,
        ROUND(COALESCE(r.dex_total_volume / NULLIF(r.all_protocol_volume, 0) * 100, 0)::NUMERIC, 1),
        ROUND(COALESCE(r.kam_total_volume / NULLIF(r.all_protocol_volume, 0) * 100, 0)::NUMERIC, 1),
        ROUND(COALESCE(r.exp_total_volume / NULLIF(r.all_protocol_volume, 0) * 100, 0)::NUMERIC, 1),
        r.kam_supply_apy,
        r.exp_implied_apy
    FROM rebucketed r
    ORDER BY r.bt;
END;
$$ LANGUAGE plpgsql STABLE;
