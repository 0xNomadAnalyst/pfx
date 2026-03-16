-- get_view_dex_last: Direct read from mat_dex_last
-- Same signature and output schema as the original (dexes/dbsql/views/get_view_dex_last.sql)
-- but reads from the pre-computed snapshot table instead of scanning multiple source tables.
-- p_invert = TRUE swaps t0↔t1 perspective (inverts prices, swaps reserves/volumes/LP columns).

DROP FUNCTION IF EXISTS dexes.get_view_dex_last(TEXT, TEXT, INTERVAL) CASCADE;
CREATE OR REPLACE FUNCTION dexes.get_view_dex_last(
    protocol_param TEXT,
    pair_param TEXT,
    lookback_param INTERVAL,
    p_invert BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    pool_address TEXT,
    protocol TEXT,
    token_pair TEXT,
    symbols_t0_t1 TEXT[],
    liq_query_id BIGINT,
    price_t1_per_t0 NUMERIC,
    impact_t0_quantities DOUBLE PRECISION[],
    impact_from_t0_sell1_bps NUMERIC,
    impact_from_t0_sell2_bps NUMERIC,
    impact_from_t0_sell3_bps NUMERIC,
    t0_reserve BIGINT,
    t1_reserve BIGINT,
    tvl_in_t1_units BIGINT,
    reserve_t0_t1_millions NUMERIC[],
    reserve_t0_t1_balance_pct NUMERIC[],
    swap_count_period BIGINT,
    lp_in_count_period BIGINT,
    lp_out_count_period BIGINT,
    swap_vol_in_t1_units BIGINT,
    swap_vol_in_t0_units BIGINT,
    swap_vol_in_t1_units_pct_reserve NUMERIC,
    swap_vol_in_t0_units_pct_reserve NUMERIC,
    swap_vol_out_t1_units BIGINT,
    swap_vol_out_t0_units BIGINT,
    swap_vol_out_t1_units_pct_reserve NUMERIC,
    swap_vol_out_t0_units_pct_reserve NUMERIC,
    swap_vol_period_t0_in BIGINT,
    swap_vol_period_t0_out BIGINT,
    swap_vol_period_t1_in BIGINT,
    swap_vol_period_t1_out BIGINT,
    lp_token0_in_period_sum BIGINT,
    lp_token0_out_period_sum BIGINT,
    lp_token1_in_period_sum BIGINT,
    lp_token1_out_period_sum BIGINT,
    lp_token0_in_period_sum_pct_reserve NUMERIC,
    lp_token0_out_period_sum_pct_reserve NUMERIC,
    lp_token1_in_period_sum_pct_reserve NUMERIC,
    lp_token1_out_period_sum_pct_reserve NUMERIC,
    swap_token1_in_max BIGINT,
    swap_token1_in_max_t0_complement BIGINT,
    swap_token1_out_max BIGINT,
    swap_token1_out_max_t0_complement BIGINT,
    swap_token0_in_max BIGINT,
    swap_token0_out_max BIGINT,
    swap_token0_in_avg NUMERIC,
    swap_token0_out_avg NUMERIC,
    swap_token1_in_avg NUMERIC,
    swap_token1_out_avg NUMERIC,
    swap_token1_in_max_pct_reserve NUMERIC,
    swap_token1_out_max_pct_reserve NUMERIC,
    swap_token1_in_max_impact_bps NUMERIC,
    swap_token1_out_max_impact_bps NUMERIC,
    swap_token0_in_max_impact_bps NUMERIC,
    swap_token0_out_max_impact_bps NUMERIC,
    swap_token0_in_avg_impact_bps NUMERIC,
    swap_token0_out_avg_impact_bps NUMERIC,
    swap_token1_in_avg_impact_bps NUMERIC,
    swap_token1_out_avg_impact_bps NUMERIC,
    vwap_buy_t0_avg NUMERIC,
    vwap_sell_t0_avg NUMERIC,
    price_t1_per_t0_avg NUMERIC,
    spread_vwap_avg_bps NUMERIC,
    price_t1_per_t0_max NUMERIC,
    price_t1_per_t0_min NUMERIC,
    price_t1_per_t0_std NUMERIC,
    swap_vol_t1_total_24h BIGINT,
    swap_vol_t1_total_24h_pct_tvl_in_t1 NUMERIC,
    swap_count_24h BIGINT,
    max_1h_t0_sell_pressure_pct_reserve NUMERIC,
    max_1h_t0_sell_pressure_start TIMESTAMPTZ,
    max_1h_t0_sell_pressure_in_period BIGINT,
    max_1h_t0_sell_pressure_in_period_impact_bps NUMERIC,
    max_1h_t0_buy_pressure_in_period BIGINT,
    max_1h_t0_buy_pressure_in_period_impact_bps NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        ml.pool_address,
        ml.protocol,
        ml.token_pair,
        CASE WHEN p_invert THEN ARRAY[ml.symbols_t0_t1[2], ml.symbols_t0_t1[1]]
             ELSE ml.symbols_t0_t1 END,
        ml.liq_query_id,
        CASE WHEN p_invert THEN ROUND(1.0 / NULLIF(ml.price_t1_per_t0, 0), 8)
             ELSE ml.price_t1_per_t0 END,
        CASE WHEN p_invert THEN COALESCE(ml.impact_t1_quantities, ml.impact_t0_quantities)
             ELSE ml.impact_t0_quantities END,
        CASE WHEN p_invert THEN COALESCE(-1 * ml.impact_from_t1_sell1_bps, -1 * ml.impact_from_t0_sell1_bps)
             ELSE ml.impact_from_t0_sell1_bps END,
        CASE WHEN p_invert THEN COALESCE(-1 * ml.impact_from_t1_sell2_bps, -1 * ml.impact_from_t0_sell2_bps)
             ELSE ml.impact_from_t0_sell2_bps END,
        CASE WHEN p_invert THEN COALESCE(-1 * ml.impact_from_t1_sell3_bps, -1 * ml.impact_from_t0_sell3_bps)
             ELSE ml.impact_from_t0_sell3_bps END,
        CASE WHEN p_invert THEN ml.t1_reserve ELSE ml.t0_reserve END,
        CASE WHEN p_invert THEN ml.t0_reserve ELSE ml.t1_reserve END,
        CASE WHEN p_invert
             THEN (ROUND(COALESCE(ml.t1_reserve::NUMERIC / NULLIF(ml.price_t1_per_t0, 0), 0)
                       + COALESCE(ml.t0_reserve, 0)))::BIGINT
             ELSE ml.tvl_in_t1_units END,
        CASE WHEN p_invert THEN ARRAY[ml.reserve_t0_t1_millions[2], ml.reserve_t0_t1_millions[1]]
             ELSE ml.reserve_t0_t1_millions END,
        CASE WHEN p_invert THEN ARRAY[ml.reserve_t0_t1_balance_pct[2], ml.reserve_t0_t1_balance_pct[1]]
             ELSE ml.reserve_t0_t1_balance_pct END,
        ml.swap_count_period,
        ml.lp_in_count_period,
        ml.lp_out_count_period,
        CASE WHEN p_invert THEN ml.swap_vol_in_t0_units  ELSE ml.swap_vol_in_t1_units END,
        CASE WHEN p_invert THEN ml.swap_vol_in_t1_units  ELSE ml.swap_vol_in_t0_units END,
        CASE WHEN p_invert THEN ml.swap_vol_in_t0_units_pct_reserve  ELSE ml.swap_vol_in_t1_units_pct_reserve END,
        CASE WHEN p_invert THEN ml.swap_vol_in_t1_units_pct_reserve  ELSE ml.swap_vol_in_t0_units_pct_reserve END,
        CASE WHEN p_invert THEN ml.swap_vol_out_t0_units ELSE ml.swap_vol_out_t1_units END,
        CASE WHEN p_invert THEN ml.swap_vol_out_t1_units ELSE ml.swap_vol_out_t0_units END,
        CASE WHEN p_invert THEN ml.swap_vol_out_t0_units_pct_reserve ELSE ml.swap_vol_out_t1_units_pct_reserve END,
        CASE WHEN p_invert THEN ml.swap_vol_out_t1_units_pct_reserve ELSE ml.swap_vol_out_t0_units_pct_reserve END,
        CASE WHEN p_invert THEN ml.swap_vol_period_t1_in  ELSE ml.swap_vol_period_t0_in END,
        CASE WHEN p_invert THEN ml.swap_vol_period_t1_out ELSE ml.swap_vol_period_t0_out END,
        CASE WHEN p_invert THEN ml.swap_vol_period_t0_in  ELSE ml.swap_vol_period_t1_in END,
        CASE WHEN p_invert THEN ml.swap_vol_period_t0_out ELSE ml.swap_vol_period_t1_out END,
        CASE WHEN p_invert THEN ml.lp_token1_in_period_sum  ELSE ml.lp_token0_in_period_sum END,
        CASE WHEN p_invert THEN ml.lp_token1_out_period_sum ELSE ml.lp_token0_out_period_sum END,
        CASE WHEN p_invert THEN ml.lp_token0_in_period_sum  ELSE ml.lp_token1_in_period_sum END,
        CASE WHEN p_invert THEN ml.lp_token0_out_period_sum ELSE ml.lp_token1_out_period_sum END,
        CASE WHEN p_invert THEN ml.lp_token1_in_period_sum_pct_reserve  ELSE ml.lp_token0_in_period_sum_pct_reserve END,
        CASE WHEN p_invert THEN ml.lp_token1_out_period_sum_pct_reserve ELSE ml.lp_token0_out_period_sum_pct_reserve END,
        CASE WHEN p_invert THEN ml.lp_token0_in_period_sum_pct_reserve  ELSE ml.lp_token1_in_period_sum_pct_reserve END,
        CASE WHEN p_invert THEN ml.lp_token0_out_period_sum_pct_reserve ELSE ml.lp_token1_out_period_sum_pct_reserve END,
        CASE WHEN p_invert THEN ml.swap_token0_in_max  ELSE ml.swap_token1_in_max END,
        CASE WHEN p_invert THEN ml.swap_token0_out_max ELSE ml.swap_token1_in_max_t0_complement END,
        CASE WHEN p_invert THEN ml.swap_token0_out_max ELSE ml.swap_token1_out_max END,
        CASE WHEN p_invert THEN ml.swap_token0_in_max  ELSE ml.swap_token1_out_max_t0_complement END,
        CASE WHEN p_invert THEN ml.swap_token1_in_max  ELSE ml.swap_token0_in_max END,
        CASE WHEN p_invert THEN ml.swap_token1_out_max ELSE ml.swap_token0_out_max END,
        CASE WHEN p_invert THEN ml.swap_token1_in_avg  ELSE ml.swap_token0_in_avg END,
        CASE WHEN p_invert THEN ml.swap_token1_out_avg ELSE ml.swap_token0_out_avg END,
        CASE WHEN p_invert THEN ml.swap_token0_in_avg  ELSE ml.swap_token1_in_avg END,
        CASE WHEN p_invert THEN ml.swap_token0_out_avg ELSE ml.swap_token1_out_avg END,
        ml.swap_token1_in_max_pct_reserve,
        ml.swap_token1_out_max_pct_reserve,
        CASE WHEN p_invert THEN -1 * ml.swap_token0_in_max_impact_bps  ELSE ml.swap_token1_in_max_impact_bps END,
        CASE WHEN p_invert THEN -1 * ml.swap_token0_out_max_impact_bps ELSE ml.swap_token1_out_max_impact_bps END,
        CASE WHEN p_invert THEN -1 * ml.swap_token1_in_max_impact_bps  ELSE ml.swap_token0_in_max_impact_bps END,
        CASE WHEN p_invert THEN -1 * ml.swap_token1_out_max_impact_bps ELSE ml.swap_token0_out_max_impact_bps END,
        CASE WHEN p_invert THEN -1 * ml.swap_token1_in_avg_impact_bps  ELSE ml.swap_token0_in_avg_impact_bps END,
        CASE WHEN p_invert THEN -1 * ml.swap_token1_out_avg_impact_bps ELSE ml.swap_token0_out_avg_impact_bps END,
        CASE WHEN p_invert THEN -1 * ml.swap_token0_in_avg_impact_bps  ELSE ml.swap_token1_in_avg_impact_bps END,
        CASE WHEN p_invert THEN -1 * ml.swap_token0_out_avg_impact_bps ELSE ml.swap_token1_out_avg_impact_bps END,
        CASE WHEN p_invert THEN ROUND(1.0 / NULLIF(ml.vwap_sell_t0_avg, 0), 6)
             ELSE ml.vwap_buy_t0_avg END,
        CASE WHEN p_invert THEN ROUND(1.0 / NULLIF(ml.vwap_buy_t0_avg, 0), 6)
             ELSE ml.vwap_sell_t0_avg END,
        CASE WHEN p_invert THEN ROUND(1.0 / NULLIF(ml.price_t1_per_t0_avg, 0), 8)
             ELSE ml.price_t1_per_t0_avg END,
        ml.spread_vwap_avg_bps,
        CASE WHEN p_invert THEN ROUND(1.0 / NULLIF(ml.price_t1_per_t0_min, 0), 8)
             ELSE ml.price_t1_per_t0_max END,
        CASE WHEN p_invert THEN ROUND(1.0 / NULLIF(ml.price_t1_per_t0_max, 0), 8)
             ELSE ml.price_t1_per_t0_min END,
        ml.price_t1_per_t0_std,
        ml.swap_vol_t1_total_24h,
        ml.swap_vol_t1_total_24h_pct_tvl_in_t1,
        ml.swap_count_24h,
        ml.max_1h_t0_sell_pressure_pct_reserve,
        ml.max_1h_t0_sell_pressure_start,
        CASE WHEN p_invert THEN ml.max_1h_t0_buy_pressure_in_period
             ELSE ml.max_1h_t0_sell_pressure_in_period END,
        CASE WHEN p_invert THEN -1 * ml.max_1h_t0_buy_pressure_in_period_impact_bps
             ELSE ml.max_1h_t0_sell_pressure_in_period_impact_bps END,
        CASE WHEN p_invert THEN ml.max_1h_t0_sell_pressure_in_period
             ELSE ml.max_1h_t0_buy_pressure_in_period END,
        CASE WHEN p_invert THEN -1 * ml.max_1h_t0_sell_pressure_in_period_impact_bps
             ELSE ml.max_1h_t0_buy_pressure_in_period_impact_bps END
    FROM dexes.mat_dex_last ml
    WHERE ml.protocol = protocol_param
      AND ml.token_pair = pair_param;
END;
$$;
