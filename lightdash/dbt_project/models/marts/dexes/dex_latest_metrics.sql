{{
  config(
    materialized='view'
  )
}}

{#
  Latest DEX pool metrics from dexes.get_view_dex_last().
  Lookback-dependent metrics (swap volumes, LP activity, VWAP, etc.) are
  pre-computed via CROSS JOIN LATERAL across standard intervals.
  Protocol and pair passed as NULL to return the full universe.
  Array columns are unpacked into scalar columns for Lightdash compatibility.
#}

WITH lookbacks AS (
    SELECT unnest(ARRAY[
        '5 minutes'::interval,
        '1 hour'::interval,
        '24 hours'::interval,
        '7 days'::interval,
        '28 days'::interval
    ]) AS lookback
)

SELECT
    l.lookback::text                                    AS lookback,
    r.protocol,
    r.token_pair                                        AS pair,
    r.pool_address,
    r.symbols_t0_t1[1]                                  AS symbol_t0,
    r.symbols_t0_t1[2]                                  AS symbol_t1,

    -- Current price & liquidity query
    r.liq_query_id,
    r.price_t1_per_t0,

    -- Price impact for standard trade sizes (selling token0)
    r.impact_from_t0_sell1_bps                          AS impact_50k_t0_sell_bps,
    r.impact_from_t0_sell2_bps                          AS impact_100k_t0_sell_bps,
    r.impact_from_t0_sell3_bps                          AS impact_500k_t0_sell_bps,

    -- Reserve metrics
    r.t0_reserve,
    r.t1_reserve,
    r.tvl_in_t1_units,
    r.reserve_t0_t1_millions[1]                         AS t0_reserve_millions,
    r.reserve_t0_t1_millions[2]                         AS t1_reserve_millions,
    r.reserve_t0_t1_balance_pct[1]                      AS t0_balance_pct,
    r.reserve_t0_t1_balance_pct[2]                      AS t1_balance_pct,

    -- Event counts
    r.swap_count_period,
    r.lp_in_count_period,
    r.lp_out_count_period,

    -- Swap volume (total)
    r.swap_vol_in_t1_units,
    r.swap_vol_in_t0_units,
    r.swap_vol_in_t1_units_pct_reserve,
    r.swap_vol_in_t0_units_pct_reserve,
    r.swap_vol_out_t1_units,
    r.swap_vol_out_t0_units,
    r.swap_vol_out_t1_units_pct_reserve,
    r.swap_vol_out_t0_units_pct_reserve,

    -- Directional swap volumes
    r.swap_vol_period_t0_in,
    r.swap_vol_period_t0_out,
    r.swap_vol_period_t1_in,
    r.swap_vol_period_t1_out,

    -- LP activity
    r.lp_token0_in_period_sum,
    r.lp_token0_out_period_sum,
    r.lp_token1_in_period_sum,
    r.lp_token1_out_period_sum,
    r.lp_token0_in_period_sum_pct_reserve,
    r.lp_token0_out_period_sum_pct_reserve,
    r.lp_token1_in_period_sum_pct_reserve,
    r.lp_token1_out_period_sum_pct_reserve,

    -- Max swap flows with complements
    r.swap_token1_in_max,
    r.swap_token1_in_max_t0_complement,
    r.swap_token1_out_max,
    r.swap_token1_out_max_t0_complement,
    r.swap_token0_in_max,
    r.swap_token0_out_max,

    -- Average swap flows
    r.swap_token0_in_avg,
    r.swap_token0_out_avg,
    r.swap_token1_in_avg,
    r.swap_token1_out_avg,

    -- Max swap as % of reserves
    r.swap_token1_in_max_pct_reserve,
    r.swap_token1_out_max_pct_reserve,

    -- Price impact for max swaps
    r.swap_token1_in_max_impact_bps,
    r.swap_token1_out_max_impact_bps,
    r.swap_token0_in_max_impact_bps,
    r.swap_token0_out_max_impact_bps,

    -- Price impact for average swaps
    r.swap_token0_in_avg_impact_bps,
    r.swap_token0_out_avg_impact_bps,
    r.swap_token1_in_avg_impact_bps,
    r.swap_token1_out_avg_impact_bps,

    -- VWAP and spread metrics
    r.vwap_buy_t0_avg,
    r.vwap_sell_t0_avg,
    r.price_t1_per_t0_avg,
    r.spread_vwap_avg_bps,

    -- Price statistics
    r.price_t1_per_t0_max,
    r.price_t1_per_t0_min,
    r.price_t1_per_t0_std,

    -- 24-hour fixed window metrics (same across all lookbacks)
    r.swap_vol_t1_total_24h,
    r.swap_vol_t1_total_24h_pct_tvl_in_t1,
    r.swap_count_24h,

    -- Max 1-hour pressure metrics
    r.max_1h_t0_sell_pressure_in_period,
    r.max_1h_t0_buy_pressure_in_period,
    r.max_1h_t0_sell_pressure_in_period_impact_bps,
    r.max_1h_t0_buy_pressure_in_period_impact_bps

FROM lookbacks l
CROSS JOIN LATERAL dexes.get_view_dex_last(
    NULL::text,
    NULL::text,
    l.lookback
) r
