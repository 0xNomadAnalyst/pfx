-- get_view_xp_timeseries: Cross-protocol timeseries re-bucketing function.
-- Reads from mat_xp_ts_1m (1-minute grain) and aggregates to the requested
-- bucket interval. Serves the time-series charts on the global ecosystem page.
--
-- TVL columns use LOCF (last-observation-carried-forward) because the source
-- mat tables are sparse: Kamino updates ~55% of minutes and Exponent ~6%.
-- Zeros in the 1m table represent missing data, not actual zero balances.

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
    kam_usdc_borrow_apy      NUMERIC,
    kam_usdg_borrow_apy      NUMERIC,
    kam_usds_borrow_apy      NUMERIC,
    exp_weighted_implied_apy NUMERIC
) AS $$
DECLARE
    v_interval       INTERVAL;
    v_prev_dex_tvl   NUMERIC;
    v_prev_kam_tvl   NUMERIC;
    v_prev_exp_tvl   NUMERIC;
    v_prev_kam_apy   NUMERIC;
    v_prev_usdc_apy  NUMERIC;
    v_prev_usdg_apy  NUMERIC;
    v_prev_usds_apy  NUMERIC;
    v_prev_exp_apy   NUMERIC;
BEGIN
    BEGIN
        v_interval := bucket_interval::INTERVAL;
    EXCEPTION WHEN OTHERS THEN
        v_interval := INTERVAL '1 minute';
    END;

    -- Seed LOCF: last known non-zero TVL and non-null yields before the window
    SELECT m.onyc_in_dexes INTO v_prev_dex_tvl
    FROM cross_protocol.mat_xp_ts_1m m
    WHERE m.bucket_time < from_ts AND m.onyc_in_dexes > 0
    ORDER BY m.bucket_time DESC LIMIT 1;

    SELECT m.onyc_in_kamino INTO v_prev_kam_tvl
    FROM cross_protocol.mat_xp_ts_1m m
    WHERE m.bucket_time < from_ts AND m.onyc_in_kamino > 0
    ORDER BY m.bucket_time DESC LIMIT 1;

    SELECT m.onyc_in_exponent INTO v_prev_exp_tvl
    FROM cross_protocol.mat_xp_ts_1m m
    WHERE m.bucket_time < from_ts AND m.onyc_in_exponent > 0
    ORDER BY m.bucket_time DESC LIMIT 1;

    SELECT m.kam_onyc_supply_apy INTO v_prev_kam_apy
    FROM cross_protocol.mat_xp_ts_1m m
    WHERE m.bucket_time < from_ts AND m.kam_onyc_supply_apy IS NOT NULL
    ORDER BY m.bucket_time DESC LIMIT 1;

    SELECT m.kam_usdc_borrow_apy INTO v_prev_usdc_apy
    FROM cross_protocol.mat_xp_ts_1m m
    WHERE m.bucket_time < from_ts AND m.kam_usdc_borrow_apy IS NOT NULL
    ORDER BY m.bucket_time DESC LIMIT 1;

    SELECT m.kam_usdg_borrow_apy INTO v_prev_usdg_apy
    FROM cross_protocol.mat_xp_ts_1m m
    WHERE m.bucket_time < from_ts AND m.kam_usdg_borrow_apy IS NOT NULL
    ORDER BY m.bucket_time DESC LIMIT 1;

    SELECT m.kam_usds_borrow_apy INTO v_prev_usds_apy
    FROM cross_protocol.mat_xp_ts_1m m
    WHERE m.bucket_time < from_ts AND m.kam_usds_borrow_apy IS NOT NULL
    ORDER BY m.bucket_time DESC LIMIT 1;

    SELECT m.exp_weighted_implied_apy INTO v_prev_exp_apy
    FROM cross_protocol.mat_xp_ts_1m m
    WHERE m.bucket_time < from_ts AND m.exp_weighted_implied_apy IS NOT NULL
    ORDER BY m.bucket_time DESC LIMIT 1;

    RETURN QUERY
    WITH rebucketed AS (
        SELECT
            time_bucket(v_interval, m.bucket_time) AS bt,
            -- TVL: latest non-zero value within each bucket (zeros are data gaps)
            (array_agg(m.onyc_in_dexes ORDER BY m.bucket_time DESC)
                FILTER (WHERE m.onyc_in_dexes > 0))[1] AS onyc_in_dexes,
            (array_agg(m.onyc_in_kamino ORDER BY m.bucket_time DESC)
                FILTER (WHERE m.onyc_in_kamino > 0))[1] AS onyc_in_kamino,
            (array_agg(m.onyc_in_exponent ORDER BY m.bucket_time DESC)
                FILTER (WHERE m.onyc_in_exponent > 0))[1] AS onyc_in_exponent,
            -- Activity: sum within the larger bucket
            SUM(m.dex_swap_volume)    AS dex_swap_volume,
            SUM(m.dex_lp_volume)      AS dex_lp_volume,
            SUM(m.dex_total_volume)   AS dex_total_volume,
            SUM(m.kam_total_volume)   AS kam_total_volume,
            SUM(m.exp_total_volume)   AS exp_total_volume,
            SUM(m.all_protocol_volume) AS all_protocol_volume,
            -- Yields: latest non-null value within each bucket
            (array_agg(m.kam_onyc_supply_apy ORDER BY m.bucket_time DESC)
                FILTER (WHERE m.kam_onyc_supply_apy IS NOT NULL))[1] AS kam_supply_apy,
            (array_agg(m.kam_usdc_borrow_apy ORDER BY m.bucket_time DESC)
                FILTER (WHERE m.kam_usdc_borrow_apy IS NOT NULL))[1] AS usdc_apy,
            (array_agg(m.kam_usdg_borrow_apy ORDER BY m.bucket_time DESC)
                FILTER (WHERE m.kam_usdg_borrow_apy IS NOT NULL))[1] AS usdg_apy,
            (array_agg(m.kam_usds_borrow_apy ORDER BY m.bucket_time DESC)
                FILTER (WHERE m.kam_usds_borrow_apy IS NOT NULL))[1] AS usds_apy,
            (array_agg(m.exp_weighted_implied_apy ORDER BY m.bucket_time DESC)
                FILTER (WHERE m.exp_weighted_implied_apy IS NOT NULL))[1] AS exp_implied_apy
        FROM cross_protocol.mat_xp_ts_1m m
        WHERE m.bucket_time >= from_ts
          AND m.bucket_time <  to_ts
        GROUP BY bt
    ),
    -- LOCF: carry forward TVL and yields across buckets that have no data
    locf_groups AS (
        SELECT r.*,
            COUNT(r.onyc_in_dexes) OVER (ORDER BY r.bt)    AS grp_dex,
            COUNT(r.onyc_in_kamino) OVER (ORDER BY r.bt)    AS grp_kam_tvl,
            COUNT(r.onyc_in_exponent) OVER (ORDER BY r.bt)  AS grp_exp_tvl,
            COUNT(r.kam_supply_apy) OVER (ORDER BY r.bt)    AS grp_kam_apy,
            COUNT(r.usdc_apy) OVER (ORDER BY r.bt)          AS grp_usdc_apy,
            COUNT(r.usdg_apy) OVER (ORDER BY r.bt)          AS grp_usdg_apy,
            COUNT(r.usds_apy) OVER (ORDER BY r.bt)          AS grp_usds_apy,
            COUNT(r.exp_implied_apy) OVER (ORDER BY r.bt)   AS grp_exp_apy
        FROM rebucketed r
    ),
    filled AS (
        SELECT g.*,
            COALESCE(
                FIRST_VALUE(g.onyc_in_dexes) OVER (PARTITION BY g.grp_dex ORDER BY g.bt),
                v_prev_dex_tvl, 0
            ) AS dex_tvl_filled,
            COALESCE(
                FIRST_VALUE(g.onyc_in_kamino) OVER (PARTITION BY g.grp_kam_tvl ORDER BY g.bt),
                v_prev_kam_tvl, 0
            ) AS kam_tvl_filled,
            COALESCE(
                FIRST_VALUE(g.onyc_in_exponent) OVER (PARTITION BY g.grp_exp_tvl ORDER BY g.bt),
                v_prev_exp_tvl, 0
            ) AS exp_tvl_filled,
            COALESCE(
                FIRST_VALUE(g.kam_supply_apy) OVER (PARTITION BY g.grp_kam_apy ORDER BY g.bt),
                v_prev_kam_apy
            ) AS kam_apy_filled,
            COALESCE(
                FIRST_VALUE(g.usdc_apy) OVER (PARTITION BY g.grp_usdc_apy ORDER BY g.bt),
                v_prev_usdc_apy
            ) AS usdc_apy_filled,
            COALESCE(
                FIRST_VALUE(g.usdg_apy) OVER (PARTITION BY g.grp_usdg_apy ORDER BY g.bt),
                v_prev_usdg_apy
            ) AS usdg_apy_filled,
            COALESCE(
                FIRST_VALUE(g.usds_apy) OVER (PARTITION BY g.grp_usds_apy ORDER BY g.bt),
                v_prev_usds_apy
            ) AS usds_apy_filled,
            COALESCE(
                FIRST_VALUE(g.exp_implied_apy) OVER (PARTITION BY g.grp_exp_apy ORDER BY g.bt),
                v_prev_exp_apy
            ) AS exp_apy_filled
        FROM locf_groups g
    )
    SELECT
        f.bt,
        f.dex_tvl_filled,
        f.kam_tvl_filled,
        f.exp_tvl_filled,
        f.dex_tvl_filled + f.kam_tvl_filled + f.exp_tvl_filled,
        -- Re-derive percentages from the LOCF'd TVL totals
        ROUND(COALESCE(f.dex_tvl_filled / NULLIF(f.dex_tvl_filled + f.kam_tvl_filled + f.exp_tvl_filled, 0) * 100, 0)::NUMERIC, 1),
        ROUND(COALESCE(f.kam_tvl_filled / NULLIF(f.dex_tvl_filled + f.kam_tvl_filled + f.exp_tvl_filled, 0) * 100, 0)::NUMERIC, 1),
        ROUND(COALESCE(f.exp_tvl_filled / NULLIF(f.dex_tvl_filled + f.kam_tvl_filled + f.exp_tvl_filled, 0) * 100, 0)::NUMERIC, 1),
        f.dex_swap_volume,
        f.dex_lp_volume,
        f.dex_total_volume,
        f.kam_total_volume,
        f.exp_total_volume,
        f.all_protocol_volume,
        ROUND(COALESCE(f.dex_total_volume / NULLIF(f.all_protocol_volume, 0) * 100, 0)::NUMERIC, 1),
        ROUND(COALESCE(f.kam_total_volume / NULLIF(f.all_protocol_volume, 0) * 100, 0)::NUMERIC, 1),
        ROUND(COALESCE(f.exp_total_volume / NULLIF(f.all_protocol_volume, 0) * 100, 0)::NUMERIC, 1),
        ROUND(COALESCE(f.kam_apy_filled * 100, 0)::NUMERIC, 2),
        ROUND(COALESCE(f.usdc_apy_filled * 100, 0)::NUMERIC, 2),
        ROUND(COALESCE(f.usdg_apy_filled * 100, 0)::NUMERIC, 2),
        ROUND(COALESCE(f.usds_apy_filled * 100, 0)::NUMERIC, 2),
        ROUND(COALESCE(f.exp_apy_filled * 100, 0)::NUMERIC, 2)
    FROM filled f
    ORDER BY f.bt;
END;
$$ LANGUAGE plpgsql STABLE;
