-- get_view_dex_timeseries: Re-bucketed read from mat_dex_timeseries_1m
-- Same signature and output schema as the original (dexes/dbsql/views/get_view_dex_timeseries.sql)
-- but reads from the pre-joined 1-minute materialized table instead of joining 4 CAGGs at query time.

CREATE OR REPLACE FUNCTION dexes.get_view_dex_timeseries(
    p_protocol TEXT,
    p_token_pair TEXT,
    p_interval TEXT DEFAULT '1 minute',
    p_rows INTEGER DEFAULT 100
)
RETURNS TABLE (
    "time" TIMESTAMPTZ,
    pool_address TEXT,
    protocol TEXT,
    token_pair TEXT,
    symbols_t0_t1 TEXT[],
    swap_count BIGINT,
    swap_t0_in BIGINT,
    swap_t0_out BIGINT,
    swap_t0_net BIGINT,
    swap_t1_in BIGINT,
    swap_t1_out BIGINT,
    swap_t1_net BIGINT,
    lp_count BIGINT,
    lp_t0_in BIGINT,
    lp_t0_out BIGINT,
    lp_t0_net BIGINT,
    lp_t1_in BIGINT,
    lp_t1_out BIGINT,
    lp_t1_net BIGINT,
    swap_t0_in_pct_reserve NUMERIC(10,4),
    swap_t0_out_pct_reserve NUMERIC(10,4),
    swap_t0_net_pct_reserve NUMERIC(10,4),
    swap_t1_in_pct_reserve NUMERIC(10,4),
    swap_t1_out_pct_reserve NUMERIC(10,4),
    swap_t1_net_pct_reserve NUMERIC(10,4),
    lp_t0_in_pct_reserve NUMERIC(10,4),
    lp_t0_out_pct_reserve NUMERIC(10,4),
    lp_t0_net_pct_reserve NUMERIC(10,4),
    lp_t1_in_pct_reserve NUMERIC(10,4),
    lp_t1_out_pct_reserve NUMERIC(10,4),
    lp_t1_net_pct_reserve NUMERIC(10,4),
    last_vwap_buy_t0 NUMERIC(20,8),
    last_vwap_sell_t0 NUMERIC(20,8),
    last_vwap_spread_bps NUMERIC(10,2),
    avg_vwap_buy_t0_w_last NUMERIC(20,8),
    avg_vwap_sell_t0_w_last NUMERIC(20,8),
    avg_vwap_spread_bps_w_last NUMERIC(10,2),
    last_avg_vwap_buy_t0_w_last NUMERIC(20,8),
    last_avg_vwap_sell_t0_w_last NUMERIC(20,8),
    avg_est_swap_impact_bps NUMERIC(20,6),
    min_est_swap_impact_bps_t0_sell NUMERIC(20,4),
    avg_est_swap_impact_bps_all NUMERIC(20,4),
    current_tick INTEGER,
    current_tick_float NUMERIC(20,4),
    sqrt_price_x64 NUMERIC(40,0),
    price_t1_per_t0 NUMERIC(20,8),
    impact_t0_quantities DOUBLE PRECISION[],
    impact_from_t0_sell1_bps NUMERIC(10,2),
    impact_from_t0_sell2_bps NUMERIC(10,2),
    impact_from_t0_sell3_bps NUMERIC(10,2),
    impact_bps_targets DOUBLE PRECISION[],
    sell_t0_for_impact1 BIGINT,
    sell_t0_for_impact2 BIGINT,
    sell_t0_for_impact3 BIGINT,
    sell_t0_for_impact1_avg_w_last BIGINT,
    sell_t0_for_impact2_avg_w_last BIGINT,
    sell_t0_for_impact3_avg_w_last BIGINT,
    impact_from_t0_sell1_bps_avg_w_last NUMERIC(10,2),
    impact_from_t0_sell2_bps_avg_w_last NUMERIC(10,2),
    impact_from_t0_sell3_bps_avg_w_last NUMERIC(10,2),
    t0_reserve BIGINT,
    t1_reserve BIGINT,
    reserve_t0_pct NUMERIC(10,1),
    reserve_t1_pct NUMERIC(10,1),
    tvl_in_t1_units BIGINT,
    t0_reserve_pct_tvl NUMERIC(10,4),
    t1_reserve_pct_tvl NUMERIC(10,4),
    concentration_avg_peg_pct_1 NUMERIC(10,4),
    concentration_avg_peg_pct_2 NUMERIC(10,4),
    concentration_avg_peg_pct_3 NUMERIC(10,4),
    concentration_avg_peg_halfspread_bps_array INTEGER[],
    concentration_avg_active_pct_1 NUMERIC(10,4),
    concentration_avg_active_pct_2 NUMERIC(10,4),
    concentration_avg_active_pct_3 NUMERIC(10,4),
    concentration_avg_active_halfspread_bps_array INTEGER[],
    concentration_avg_peg_pct_1_last NUMERIC(10,4),
    concentration_avg_peg_pct_2_last NUMERIC(10,4),
    concentration_avg_peg_pct_3_last NUMERIC(10,4),
    concentration_avg_peg_halfspread_bps_array_last INTEGER[],
    concentration_avg_active_pct_1_last NUMERIC(10,4),
    concentration_avg_active_pct_2_last NUMERIC(10,4),
    concentration_avg_active_pct_3_last NUMERIC(10,4),
    concentration_avg_active_halfspread_bps_array_last INTEGER[],
    tick_cross_count BIGINT,
    avg_liquidity_pct_change_per_tick_cross NUMERIC(10,4)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_interval INTERVAL;
    v_lookback_time TIMESTAMPTZ;
BEGIN
    BEGIN
        v_interval := p_interval::INTERVAL;
    EXCEPTION WHEN OTHERS THEN
        v_interval := INTERVAL '1 minute';
    END;

    IF p_rows IS NULL OR p_rows < 1 THEN
        p_rows := 100;
    END IF;

    v_lookback_time := NOW() - (v_interval * p_rows);

    RETURN QUERY
    WITH rebucketed AS (
        SELECT
            time_bucket(v_interval, m.bucket_time)   AS bt,
            m.pool_address,
            MAX(m.protocol)                           AS protocol,
            MAX(m.token_pair)                         AS token_pair,
            MAX(m.symbols_t0_t1)                      AS symbols_t0_t1,
            -- Event sums
            SUM(m.swap_count)::BIGINT                 AS swap_count,
            FLOOR(SUM(m.swap_t0_in))::BIGINT          AS swap_t0_in,
            FLOOR(SUM(m.swap_t0_out))::BIGINT         AS swap_t0_out,
            FLOOR(SUM(m.swap_t0_net))::BIGINT         AS swap_t0_net,
            FLOOR(SUM(m.swap_t1_in))::BIGINT          AS swap_t1_in,
            FLOOR(SUM(m.swap_t1_out))::BIGINT         AS swap_t1_out,
            FLOOR(SUM(m.swap_t1_net))::BIGINT         AS swap_t1_net,
            SUM(m.lp_count)::BIGINT                   AS lp_count,
            FLOOR(SUM(m.lp_t0_in))::BIGINT            AS lp_t0_in,
            FLOOR(SUM(m.lp_t0_out))::BIGINT           AS lp_t0_out,
            FLOOR(SUM(m.lp_t0_net))::BIGINT           AS lp_t0_net,
            FLOOR(SUM(m.lp_t1_in))::BIGINT            AS lp_t1_in,
            FLOOR(SUM(m.lp_t1_out))::BIGINT           AS lp_t1_out,
            FLOOR(SUM(m.lp_t1_net))::BIGINT           AS lp_t1_net,
            -- VWAP: LAST within rebucket (already LOCF'd in mat table)
            LAST(m.vwap_buy_t0, m.bucket_time)        AS vwap_buy_t0,
            LAST(m.vwap_sell_t0, m.bucket_time)        AS vwap_sell_t0,
            -- Impact from events
            AVG(m.avg_est_swap_impact_bps) FILTER (WHERE m.avg_est_swap_impact_bps IS NOT NULL) AS avg_est_swap_impact_bps,
            MIN(m.min_est_swap_impact_bps_t0_sell)    AS min_est_swap_impact_bps_t0_sell,
            AVG(m.avg_est_swap_impact_bps_all) FILTER (WHERE m.avg_est_swap_impact_bps_all IS NOT NULL) AS avg_est_swap_impact_bps_all,
            -- State: LAST within rebucket (LOCF'd)
            LAST(m.current_tick, m.bucket_time)       AS current_tick,
            LAST(m.current_tick_float, m.bucket_time) AS current_tick_float,
            LAST(m.sqrt_price_x64, m.bucket_time)     AS sqrt_price_x64,
            LAST(m.price_t1_per_t0, m.bucket_time)    AS price_t1_per_t0,
            -- Impact from tickarrays: AVG
            AVG(m.impact_from_t0_sell1_avg)           AS impact_from_t0_sell1_avg,
            AVG(m.impact_from_t0_sell2_avg)           AS impact_from_t0_sell2_avg,
            AVG(m.impact_from_t0_sell3_avg)           AS impact_from_t0_sell3_avg,
            AVG(m.sell_t0_for_impact1_avg)            AS sell_t0_for_impact1_avg,
            AVG(m.sell_t0_for_impact2_avg)            AS sell_t0_for_impact2_avg,
            AVG(m.sell_t0_for_impact3_avg)            AS sell_t0_for_impact3_avg,
            -- Concentration: AVG
            AVG(m.concentration_peg_pct_1)            AS concentration_peg_pct_1,
            AVG(m.concentration_peg_pct_2)            AS concentration_peg_pct_2,
            AVG(m.concentration_peg_pct_3)            AS concentration_peg_pct_3,
            LAST(m.concentration_peg_halfspread_bps_array, m.bucket_time) AS concentration_peg_halfspread_bps_array,
            AVG(m.concentration_active_pct_1)         AS concentration_active_pct_1,
            AVG(m.concentration_active_pct_2)         AS concentration_active_pct_2,
            AVG(m.concentration_active_pct_3)         AS concentration_active_pct_3,
            LAST(m.concentration_active_halfspread_bps_array, m.bucket_time) AS concentration_active_halfspread_bps_array,
            -- Reserves: LAST
            LAST(m.t0_reserve, m.bucket_time)         AS t0_reserve,
            LAST(m.t1_reserve, m.bucket_time)         AS t1_reserve,
            -- Tick crossings: SUM
            SUM(m.tick_cross_count)::BIGINT           AS tick_cross_count,
            LAST(m.poolstate_current_liquidity_t1_units, m.bucket_time) AS current_liquidity_t1_units,
            FIRST(m.poolstate_first_liquidity_t1_units, m.bucket_time) AS first_liquidity_t1_units
        FROM dexes.mat_dex_timeseries_1m m
        WHERE m.protocol = p_protocol
          AND m.token_pair = p_token_pair
          AND m.bucket_time >= v_lookback_time
        GROUP BY time_bucket(v_interval, m.bucket_time), m.pool_address
    ),
    numbered AS (
        SELECT
            r.*,
            ROW_NUMBER() OVER (PARTITION BY r.pool_address ORDER BY r.bt DESC) AS rn,
            COUNT(*) OVER (PARTITION BY r.pool_address) AS total_rows
        FROM rebucketed r
    )
    SELECT
        n.bt                                          AS "time",
        n.pool_address,
        n.protocol,
        n.token_pair,
        n.symbols_t0_t1,
        n.swap_count,
        n.swap_t0_in, n.swap_t0_out, n.swap_t0_net,
        n.swap_t1_in, n.swap_t1_out, n.swap_t1_net,
        n.lp_count,
        n.lp_t0_in, n.lp_t0_out, n.lp_t0_net,
        n.lp_t1_in, n.lp_t1_out, n.lp_t1_net,
        -- Swap flows as % of reserves
        ROUND(CASE WHEN n.t0_reserve > 0 THEN n.swap_t0_in::NUMERIC / n.t0_reserve * 100 ELSE 0 END, 4)::NUMERIC(10,4),
        ROUND(CASE WHEN n.t0_reserve > 0 THEN n.swap_t0_out::NUMERIC / n.t0_reserve * 100 ELSE 0 END, 4)::NUMERIC(10,4),
        ROUND(CASE WHEN n.t0_reserve > 0 THEN n.swap_t0_net::NUMERIC / n.t0_reserve * 100 ELSE 0 END, 4)::NUMERIC(10,4),
        ROUND(CASE WHEN n.t1_reserve > 0 THEN n.swap_t1_in::NUMERIC / n.t1_reserve * 100 ELSE 0 END, 4)::NUMERIC(10,4),
        ROUND(CASE WHEN n.t1_reserve > 0 THEN n.swap_t1_out::NUMERIC / n.t1_reserve * 100 ELSE 0 END, 4)::NUMERIC(10,4),
        ROUND(CASE WHEN n.t1_reserve > 0 THEN n.swap_t1_net::NUMERIC / n.t1_reserve * 100 ELSE 0 END, 4)::NUMERIC(10,4),
        -- LP flows as % of reserves
        ROUND(CASE WHEN n.t0_reserve > 0 THEN n.lp_t0_in::NUMERIC / n.t0_reserve * 100 ELSE 0 END, 4)::NUMERIC(10,4),
        ROUND(CASE WHEN n.t0_reserve > 0 THEN n.lp_t0_out::NUMERIC / n.t0_reserve * 100 ELSE 0 END, 4)::NUMERIC(10,4),
        ROUND(CASE WHEN n.t0_reserve > 0 THEN n.lp_t0_net::NUMERIC / n.t0_reserve * 100 ELSE 0 END, 4)::NUMERIC(10,4),
        ROUND(CASE WHEN n.t1_reserve > 0 THEN n.lp_t1_in::NUMERIC / n.t1_reserve * 100 ELSE 0 END, 4)::NUMERIC(10,4),
        ROUND(CASE WHEN n.t1_reserve > 0 THEN n.lp_t1_out::NUMERIC / n.t1_reserve * 100 ELSE 0 END, 4)::NUMERIC(10,4),
        ROUND(CASE WHEN n.t1_reserve > 0 THEN n.lp_t1_net::NUMERIC / n.t1_reserve * 100 ELSE 0 END, 4)::NUMERIC(10,4),
        -- VWAP: LOCF'd from mat table
        ROUND(n.vwap_buy_t0, 8)::NUMERIC(20,8),
        ROUND(n.vwap_sell_t0, 8)::NUMERIC(20,8),
        ROUND(CASE WHEN n.vwap_buy_t0 > 0 AND n.vwap_sell_t0 > 0
                   THEN (n.vwap_buy_t0 - n.vwap_sell_t0) / n.vwap_sell_t0 * 10000
                   ELSE NULL END, 2)::NUMERIC(10,2),
        -- avg_w_last: AVG for historical, LAST for most recent
        ROUND(CASE WHEN n.rn = 1 THEN n.vwap_buy_t0
                   ELSE AVG(n.vwap_buy_t0) OVER (PARTITION BY n.pool_address) END, 8)::NUMERIC(20,8),
        ROUND(CASE WHEN n.rn = 1 THEN n.vwap_sell_t0
                   ELSE AVG(n.vwap_sell_t0) OVER (PARTITION BY n.pool_address) END, 8)::NUMERIC(20,8),
        ROUND(CASE WHEN n.rn = 1
                   THEN CASE WHEN n.vwap_buy_t0 > 0 AND n.vwap_sell_t0 > 0
                             THEN (n.vwap_buy_t0 - n.vwap_sell_t0) / n.vwap_sell_t0 * 10000
                             ELSE NULL END
                   ELSE NULL END, 2)::NUMERIC(10,2),
        -- LOCF'd avg_w_last VWAP (same as last_vwap for simplicity since LOCF already applied)
        ROUND(n.vwap_buy_t0, 8)::NUMERIC(20,8),
        ROUND(n.vwap_sell_t0, 8)::NUMERIC(20,8),
        -- Impact metrics
        ROUND(n.avg_est_swap_impact_bps, 6)::NUMERIC(20,6),
        ROUND(n.min_est_swap_impact_bps_t0_sell, 4)::NUMERIC(20,4),
        ROUND(n.avg_est_swap_impact_bps_all, 4)::NUMERIC(20,4),
        -- State metrics (LOCF'd)
        n.current_tick,
        ROUND(n.current_tick_float, 4)::NUMERIC(20,4),
        n.sqrt_price_x64,
        ROUND(n.price_t1_per_t0, 8)::NUMERIC(20,8),
        -- Impact arrays (NULL — computed live in original, not pre-materialized)
        NULL::DOUBLE PRECISION[],
        ROUND(n.impact_from_t0_sell1_avg, 2)::NUMERIC(10,2),
        ROUND(n.impact_from_t0_sell2_avg, 2)::NUMERIC(10,2),
        ROUND(n.impact_from_t0_sell3_avg, 2)::NUMERIC(10,2),
        NULL::DOUBLE PRECISION[],
        FLOOR(n.sell_t0_for_impact1_avg)::BIGINT,
        FLOOR(n.sell_t0_for_impact2_avg)::BIGINT,
        FLOOR(n.sell_t0_for_impact3_avg)::BIGINT,
        -- avg_w_last impact (same pattern: AVG for historical, LAST for most recent)
        FLOOR(CASE WHEN n.rn = 1 THEN n.sell_t0_for_impact1_avg
                   ELSE AVG(n.sell_t0_for_impact1_avg) OVER (PARTITION BY n.pool_address) END)::BIGINT,
        FLOOR(CASE WHEN n.rn = 1 THEN n.sell_t0_for_impact2_avg
                   ELSE AVG(n.sell_t0_for_impact2_avg) OVER (PARTITION BY n.pool_address) END)::BIGINT,
        FLOOR(CASE WHEN n.rn = 1 THEN n.sell_t0_for_impact3_avg
                   ELSE AVG(n.sell_t0_for_impact3_avg) OVER (PARTITION BY n.pool_address) END)::BIGINT,
        ROUND(CASE WHEN n.rn = 1 THEN n.impact_from_t0_sell1_avg
                   ELSE AVG(n.impact_from_t0_sell1_avg) OVER (PARTITION BY n.pool_address) END, 2)::NUMERIC(10,2),
        ROUND(CASE WHEN n.rn = 1 THEN n.impact_from_t0_sell2_avg
                   ELSE AVG(n.impact_from_t0_sell2_avg) OVER (PARTITION BY n.pool_address) END, 2)::NUMERIC(10,2),
        ROUND(CASE WHEN n.rn = 1 THEN n.impact_from_t0_sell3_avg
                   ELSE AVG(n.impact_from_t0_sell3_avg) OVER (PARTITION BY n.pool_address) END, 2)::NUMERIC(10,2),
        -- Reserves
        FLOOR(n.t0_reserve)::BIGINT,
        FLOOR(n.t1_reserve)::BIGINT,
        -- Reserve composition %
        ROUND(CASE WHEN (n.t0_reserve + n.t1_reserve) > 0 THEN n.t0_reserve / (n.t0_reserve + n.t1_reserve) * 100 ELSE NULL END, 1)::NUMERIC(10,1),
        ROUND(CASE WHEN (n.t0_reserve + n.t1_reserve) > 0 THEN n.t1_reserve / (n.t0_reserve + n.t1_reserve) * 100 ELSE NULL END, 1)::NUMERIC(10,1),
        -- TVL
        FLOOR(COALESCE(n.t0_reserve * n.price_t1_per_t0, 0) + COALESCE(n.t1_reserve, 0))::BIGINT,
        -- Reserve % of TVL
        ROUND(CASE WHEN (COALESCE(n.t0_reserve * n.price_t1_per_t0, 0) + COALESCE(n.t1_reserve, 0)) > 0
                   THEN (n.t0_reserve * n.price_t1_per_t0) / (n.t0_reserve * n.price_t1_per_t0 + n.t1_reserve) * 100
                   ELSE NULL END, 4)::NUMERIC(10,4),
        ROUND(CASE WHEN (COALESCE(n.t0_reserve * n.price_t1_per_t0, 0) + COALESCE(n.t1_reserve, 0)) > 0
                   THEN n.t1_reserve / (n.t0_reserve * n.price_t1_per_t0 + n.t1_reserve) * 100
                   ELSE NULL END, 4)::NUMERIC(10,4),
        -- Concentration (AVG'd, may have NULLs)
        ROUND(n.concentration_peg_pct_1, 4)::NUMERIC(10,4),
        ROUND(n.concentration_peg_pct_2, 4)::NUMERIC(10,4),
        ROUND(n.concentration_peg_pct_3, 4)::NUMERIC(10,4),
        n.concentration_peg_halfspread_bps_array,
        ROUND(n.concentration_active_pct_1, 4)::NUMERIC(10,4),
        ROUND(n.concentration_active_pct_2, 4)::NUMERIC(10,4),
        ROUND(n.concentration_active_pct_3, 4)::NUMERIC(10,4),
        n.concentration_active_halfspread_bps_array,
        -- Concentration with LOCF (same since mat table already LOCF'd)
        ROUND(n.concentration_peg_pct_1, 4)::NUMERIC(10,4),
        ROUND(n.concentration_peg_pct_2, 4)::NUMERIC(10,4),
        ROUND(n.concentration_peg_pct_3, 4)::NUMERIC(10,4),
        n.concentration_peg_halfspread_bps_array,
        ROUND(n.concentration_active_pct_1, 4)::NUMERIC(10,4),
        ROUND(n.concentration_active_pct_2, 4)::NUMERIC(10,4),
        ROUND(n.concentration_active_pct_3, 4)::NUMERIC(10,4),
        n.concentration_active_halfspread_bps_array,
        -- Tick crossings
        n.tick_cross_count,
        ROUND(dexes.calculate_avg_liquidity_change_per_cross(
            n.tick_cross_count,
            n.current_liquidity_t1_units,
            n.first_liquidity_t1_units
        ), 4)::NUMERIC(10,4)
    FROM numbered n
    ORDER BY n.bt;
END;
$$;
