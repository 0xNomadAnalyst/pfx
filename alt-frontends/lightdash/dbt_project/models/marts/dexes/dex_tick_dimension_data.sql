{{
  config(
    materialized='view'
  )
}}

{#
  Long (unpivoted) tick distribution from get_view_tick_dist_simple().
  Token 0 / Token 1 values are stacked into a single token_value column
  with a token_side dimension, enabling stacked charts on a numeric x-axis.
  Delta lookbacks are pre-computed via CROSS JOIN LATERAL.
#}

WITH lookbacks AS (
    SELECT unnest(ARRAY[
        '5 minutes'::interval,
        '1 hour'::interval,
        '24 hours'::interval,
        '7 days'::interval,
        '28 days'::interval
    ]) AS delta_lookback
),

base AS (
    SELECT
        l.delta_lookback::text                                AS delta_lookback,
        r.protocol,
        r.token_pair                                          AS pair,
        r.tick_lower,
        r.tick_price_t1_per_t0,
        r.tick_price_t1_per_t0::text                          AS tick_price_label_t1_per_t0,
        r.tick_price_t0_per_t1,
        r.tick_price_t0_per_t1::text                          AS tick_price_label_t0_per_t1,
        r.current_price_t1_per_t0,
        r.current_price_t0_per_t1,
        r.tick_delta_to_peg_price_t1_per_t0_bps,
        r.tick_delta_to_peg_price_t0_per_t1_bps,
        r.tick_delta_to_current_price_t1_per_t0_bps,
        r.tick_delta_to_current_price_t0_per_t1_bps,
        r.token0_value,
        r.token1_value,
        r.token0_cumul,
        r.token1_cumul,
        r.token0_cumul_pct_reserve,
        r.token1_cumul_pct_reserve,
        r.token0_value_delta,
        r.token1_value_delta,
        r.liquidity_period_delta_in_t1_units,
        r.liquidity_period_delta_in_t1_units_pct,
        r.liquidity_period_delta_net_reallocation_in_t1_units,
        r.liquidity_period_delta_in_t0_units,
        r.liquidity_period_delta_in_t0_units_pct,
        r.liquidity_period_delta_net_reallocation_in_t0_units
    FROM lookbacks l
    CROSS JOIN LATERAL dexes.get_view_tick_dist_simple(
        NULL::text,
        NULL::text,
        l.delta_lookback
    ) r
)

SELECT
    delta_lookback, protocol, pair, tick_lower,
    tick_price_t1_per_t0, tick_price_label_t1_per_t0,
    tick_price_t0_per_t1, tick_price_label_t0_per_t1,
    current_price_t1_per_t0, current_price_t0_per_t1,
    tick_delta_to_peg_price_t1_per_t0_bps,
    tick_delta_to_peg_price_t0_per_t1_bps,
    tick_delta_to_current_price_t1_per_t0_bps,
    tick_delta_to_current_price_t0_per_t1_bps,
    'Token 0'                   AS token_side,
    token0_value                AS token_value,
    token0_cumul                AS token_cumul,
    token0_cumul_pct_reserve    AS token_cumul_pct_reserve,
    token0_value_delta          AS token_value_delta,
    liquidity_period_delta_in_t1_units,
    liquidity_period_delta_in_t1_units_pct,
    liquidity_period_delta_net_reallocation_in_t1_units,
    liquidity_period_delta_in_t0_units,
    liquidity_period_delta_in_t0_units_pct,
    liquidity_period_delta_net_reallocation_in_t0_units
FROM base

UNION ALL

SELECT
    delta_lookback, protocol, pair, tick_lower,
    tick_price_t1_per_t0, tick_price_label_t1_per_t0,
    tick_price_t0_per_t1, tick_price_label_t0_per_t1,
    current_price_t1_per_t0, current_price_t0_per_t1,
    tick_delta_to_peg_price_t1_per_t0_bps,
    tick_delta_to_peg_price_t0_per_t1_bps,
    tick_delta_to_current_price_t1_per_t0_bps,
    tick_delta_to_current_price_t0_per_t1_bps,
    'Token 1'                   AS token_side,
    token1_value                AS token_value,
    token1_cumul                AS token_cumul,
    token1_cumul_pct_reserve    AS token_cumul_pct_reserve,
    token1_value_delta          AS token_value_delta,
    liquidity_period_delta_in_t1_units,
    liquidity_period_delta_in_t1_units_pct,
    liquidity_period_delta_net_reallocation_in_t1_units,
    liquidity_period_delta_in_t0_units,
    liquidity_period_delta_in_t0_units_pct,
    liquidity_period_delta_net_reallocation_in_t0_units
FROM base
