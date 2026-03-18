-- ============================================================================
-- FUNCTION: get_view_dex_last (with p_invert support)
-- ============================================================================
-- Returns most recent DEX metrics for a specific pool in a single row.
-- Aggregates data from liquidity depth, vault reserves, and swap activity.
--
-- When p_invert = TRUE the output swaps the t0/t1 perspective so callers
-- see the pool from the other token's viewpoint without changing column names.
--
-- PARAMETERS:
--   protocol_param: Protocol filter (e.g., 'raydium', 'orca')
--   pair_param:     Token pair filter (e.g., 'SOL-USDC', 'USX-USDC')
--   lookback_param: Time window for aggregating swap metrics
--   p_invert:       When TRUE, swap t0↔t1 in all output columns
-- ============================================================================

DROP FUNCTION IF EXISTS dexes.get_view_dex_last(TEXT, TEXT, INTERVAL);
DROP FUNCTION IF EXISTS dexes.get_view_dex_last(TEXT, TEXT, INTERVAL, BOOLEAN);
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

    max_1h_t0_sell_pressure_in_period BIGINT,
    max_1h_t0_buy_pressure_in_period BIGINT,
    max_1h_t0_sell_pressure_in_period_impact_bps NUMERIC,
    max_1h_t0_buy_pressure_in_period_impact_bps NUMERIC,

    impact_t1_quantities DOUBLE PRECISION[],
    impact_from_t1_sell1_bps NUMERIC,
    impact_from_t1_sell2_bps NUMERIC,
    impact_from_t1_sell3_bps NUMERIC
) AS $$
DECLARE
    r_pool RECORD;
    v_pool_address TEXT;
    v_protocol TEXT;
    v_token_pair TEXT;
    v_liq_query_id BIGINT;
    v_sqrt_price_x64 NUMERIC(40,0);
    v_mint_decimals_0 SMALLINT;
    v_mint_decimals_1 SMALLINT;
    v_price_t1_per_t0 DOUBLE PRECISION;
    v_decimal_adjustment DOUBLE PRECISION;
    v_t0_reserve DOUBLE PRECISION;
    v_t1_reserve DOUBLE PRECISION;
    v_now TIMESTAMPTZ;
    v_lookback_start TIMESTAMPTZ;
    v_symbols_t0_t1 TEXT[];
    -- Helpers for the inverted perspective
    v_inv_side_t0 TEXT;
    v_inv_side_t1 TEXT;
BEGIN
    v_now := NOW();
    v_lookback_start := CASE WHEN lookback_param IS NULL THEN NULL ELSE v_now - lookback_param END;

    -- Pre-compute side labels so impact_bps_from_qsell_latest calls use
    -- the correct token side regardless of inversion.
    IF p_invert THEN
        v_inv_side_t0 := 't1';
        v_inv_side_t1 := 't0';
    ELSE
        v_inv_side_t0 := 't0';
        v_inv_side_t1 := 't1';
    END IF;

    FOR r_pool IN
        SELECT DISTINCT ON (q.pool_address)
            q.query_id,
            q.pool_address,
            q.protocol,
            q.token_pair,
            q.sqrt_price_x64,
            q.mint_decimals_0,
            q.mint_decimals_1
        FROM src_acct_tickarray_queries q
        WHERE (protocol_param IS NULL OR q.protocol = protocol_param)
          AND (pair_param IS NULL OR LOWER(q.token_pair) = LOWER(pair_param))
          AND (lookback_param IS NULL OR q.time >= v_lookback_start)
        ORDER BY q.pool_address, q.time DESC
    LOOP
        v_liq_query_id := r_pool.query_id;
        v_pool_address := r_pool.pool_address;
        v_protocol := r_pool.protocol;
        v_token_pair := r_pool.token_pair;
        v_sqrt_price_x64 := r_pool.sqrt_price_x64;
        v_mint_decimals_0 := r_pool.mint_decimals_0;
        v_mint_decimals_1 := r_pool.mint_decimals_1;

        v_decimal_adjustment := POWER(10, v_mint_decimals_0 - v_mint_decimals_1);
        v_price_t1_per_t0 := POWER(v_sqrt_price_x64::DOUBLE PRECISION / POWER(2::DOUBLE PRECISION, 64), 2) * v_decimal_adjustment;

        SELECT
            v.token_0_value,
            v.token_1_value
        INTO
            v_t0_reserve,
            v_t1_reserve
        FROM src_acct_vaults v
        WHERE v.pool_address = v_pool_address
          AND (lookback_param IS NULL OR v.time >= v_lookback_start)
        ORDER BY v.time DESC
        LIMIT 1;

        SELECT
            ARRAY[ptr.token0_symbol, ptr.token1_symbol]
        INTO
            v_symbols_t0_t1
        FROM dexes.pool_tokens_reference ptr
        WHERE ptr.pool_address = v_pool_address;

        RETURN QUERY
    WITH swap_metrics AS (
        SELECT
            SUM(c.event_count)::BIGINT AS swap_events,
            SUM(c.amount1_in + c.amount1_out)::DOUBLE PRECISION AS vol_t1,
            SUM(c.amount0_in + c.amount0_out)::DOUBLE PRECISION AS vol_t0,
            SUM(c.amount0_in)::DOUBLE PRECISION AS vol_t0_in,
            SUM(c.amount0_out)::DOUBLE PRECISION AS vol_t0_out,
            SUM(c.amount1_in)::DOUBLE PRECISION AS vol_t1_in,
            SUM(c.amount1_out)::DOUBLE PRECISION AS vol_t1_out,
            (SUM(c.vwap_buy_t0 * c.amount0_out) FILTER (WHERE c.vwap_buy_t0 IS NOT NULL AND c.amount0_out > 0)
                / NULLIF(SUM(c.amount0_out) FILTER (WHERE c.vwap_buy_t0 IS NOT NULL AND c.amount0_out > 0), 0))::DOUBLE PRECISION AS avg_vwap_buy,
            (SUM(c.vwap_sell_t0 * c.amount0_in) FILTER (WHERE c.vwap_sell_t0 IS NOT NULL AND c.amount0_in > 0)
                / NULLIF(SUM(c.amount0_in) FILTER (WHERE c.vwap_sell_t0 IS NOT NULL AND c.amount0_in > 0), 0))::DOUBLE PRECISION AS avg_vwap_sell,
            SUM(c.amount0_out) FILTER (WHERE c.vwap_buy_t0 IS NOT NULL AND c.amount0_out > 0)::DOUBLE PRECISION AS vwap_buy_volume,
            SUM(c.amount0_in) FILTER (WHERE c.vwap_sell_t0 IS NOT NULL AND c.amount0_in > 0)::DOUBLE PRECISION AS vwap_sell_volume,
            ((COALESCE(SUM(c.vwap_buy_t0 * c.amount0_out) FILTER (WHERE c.vwap_buy_t0 IS NOT NULL AND c.amount0_out > 0), 0)
              + COALESCE(SUM(c.vwap_sell_t0 * c.amount0_in) FILTER (WHERE c.vwap_sell_t0 IS NOT NULL AND c.amount0_in > 0), 0))
              / NULLIF(
                  COALESCE(SUM(c.amount0_out) FILTER (WHERE c.vwap_buy_t0 IS NOT NULL AND c.amount0_out > 0), 0)
                  + COALESCE(SUM(c.amount0_in) FILTER (WHERE c.vwap_sell_t0 IS NOT NULL AND c.amount0_in > 0), 0),
                  0))::DOUBLE PRECISION AS avg_price,
            MAX(COALESCE(c.vwap_buy_t0, c.vwap_sell_t0))::DOUBLE PRECISION AS max_price,
            MIN(COALESCE(c.vwap_buy_t0, c.vwap_sell_t0))::DOUBLE PRECISION AS min_price,
            STDDEV(COALESCE(c.vwap_buy_t0, c.vwap_sell_t0))::DOUBLE PRECISION AS std_price
        FROM cagg_events_5s c
        WHERE c.pool_address = v_pool_address
          AND c.activity_category = 'swap'
          AND lookback_param IS NOT NULL
          AND c.bucket_time >= v_lookback_start
    ),
    individual_swaps AS (
        SELECT
            CASE
                WHEN s.swap_token_in = ptr.token0_address
                THEN ABS(CAST(NULLIF(s.swap_amount_in, '') AS NUMERIC)) / POWER(10, COALESCE(s.env_token0_decimals, ptr.token0_decimals, 6))
                ELSE 0
            END::DOUBLE PRECISION AS t0_in,
            CASE
                WHEN s.swap_token_out = ptr.token0_address
                THEN ABS(CAST(NULLIF(s.swap_amount_out, '') AS NUMERIC)) / POWER(10, COALESCE(s.env_token0_decimals, ptr.token0_decimals, 6))
                ELSE 0
            END::DOUBLE PRECISION AS t0_out,
            CASE
                WHEN s.swap_token_in = ptr.token1_address
                THEN ABS(CAST(NULLIF(s.swap_amount_in, '') AS NUMERIC)) / POWER(10, COALESCE(s.env_token1_decimals, ptr.token1_decimals, 6))
                ELSE 0
            END::DOUBLE PRECISION AS t1_in,
            CASE
                WHEN s.swap_token_out = ptr.token1_address
                THEN ABS(CAST(NULLIF(s.swap_amount_out, '') AS NUMERIC)) / POWER(10, COALESCE(s.env_token1_decimals, ptr.token1_decimals, 6))
                ELSE 0
            END::DOUBLE PRECISION AS t1_out,
            (s.swap_token_in = ptr.token1_address AND s.swap_token_out = ptr.token0_address) AS is_t1_in_t0_out,
            (s.swap_token_out = ptr.token1_address AND s.swap_token_in = ptr.token0_address) AS is_t1_out_t0_in,
            (s.swap_token_out = ptr.token0_address AND s.swap_token_in = ptr.token1_address) AS is_t0_out_t1_in
        FROM dexes.src_tx_events s
        INNER JOIN dexes.pool_tokens_reference ptr ON s.pool_address = ptr.pool_address
        WHERE s.pool_address = v_pool_address
          AND s.event_type = 'swap'
          AND lookback_param IS NOT NULL
          AND s.time >= v_lookback_start
    ),
    max_individual_swaps AS (
        SELECT
            MAX(i.t0_in)::DOUBLE PRECISION AS max_t0_in,
            MAX(i.t0_out)::DOUBLE PRECISION AS max_t0_out,
            MAX(i.t1_in)::DOUBLE PRECISION AS max_t1_in,
            MAX(i.t1_out)::DOUBLE PRECISION AS max_t1_out
        FROM individual_swaps i
    ),
    avg_individual_swaps AS (
        SELECT
            AVG(NULLIF(i.t0_in, 0))::DOUBLE PRECISION AS avg_t0_in,
            AVG(NULLIF(i.t0_out, 0))::DOUBLE PRECISION AS avg_t0_out,
            AVG(NULLIF(i.t1_in, 0))::DOUBLE PRECISION AS avg_t1_in,
            AVG(NULLIF(i.t1_out, 0))::DOUBLE PRECISION AS avg_t1_out
        FROM individual_swaps i
    ),
    lp_metrics AS (
        SELECT
            SUM(CASE WHEN c.amount0_in > 0 OR c.amount1_in > 0 THEN c.event_count ELSE 0 END)::BIGINT AS lp_add_events,
            SUM(CASE WHEN c.amount0_out > 0 OR c.amount1_out > 0 THEN c.event_count ELSE 0 END)::BIGINT AS lp_remove_events,
            SUM(c.amount0_in)::DOUBLE PRECISION AS lp_t0_in,
            SUM(c.amount0_out)::DOUBLE PRECISION AS lp_t0_out,
            SUM(c.amount1_in)::DOUBLE PRECISION AS lp_t1_in,
            SUM(c.amount1_out)::DOUBLE PRECISION AS lp_t1_out
        FROM cagg_events_5s c
        WHERE c.pool_address = v_pool_address
          AND c.activity_category = 'lp'
          AND lookback_param IS NOT NULL
          AND c.bucket_time >= v_lookback_start
    ),
    swap_24h_metrics AS (
        SELECT
            SUM(c.event_count)::BIGINT AS swap_count_24h,
            SUM(c.amount1_in + c.amount1_out)::DOUBLE PRECISION AS vol_t1_total_24h,
            SUM(c.amount0_in + c.amount0_out)::DOUBLE PRECISION AS vol_t0_total_24h
        FROM cagg_events_5s c
        WHERE c.pool_address = v_pool_address
          AND c.activity_category = 'swap'
          AND c.bucket_time >= v_now - INTERVAL '24 hours'
    ),
    max_swap_complements AS (
        SELECT
            (array_agg(i.t0_out ORDER BY i.t1_in DESC) FILTER (WHERE i.is_t1_in_t0_out AND i.t1_in > 0))[1]::DOUBLE PRECISION
                AS max_t1_in_t0_complement,
            (array_agg(i.t0_in ORDER BY i.t1_out DESC) FILTER (WHERE i.is_t1_out_t0_in AND i.t1_out > 0))[1]::DOUBLE PRECISION
                AS max_t1_out_t0_complement,
            (array_agg(i.t1_in ORDER BY i.t0_out DESC) FILTER (WHERE i.is_t0_out_t1_in AND i.t0_out > 0))[1]::DOUBLE PRECISION
                AS max_t0_out_t1_complement,
            (array_agg(i.t1_out ORDER BY i.t0_in DESC) FILTER (WHERE i.is_t1_out_t0_in AND i.t0_in > 0))[1]::DOUBLE PRECISION
                AS max_t0_in_t1_complement
        FROM individual_swaps i
    ),
    max_1h_pressure_metrics AS (
        SELECT
            CASE
                WHEN lookback_param IS NULL THEN NULL
                ELSE COALESCE(MAX(GREATEST(h.t0_in - h.t0_out, 0)), 0)
            END AS max_sell_pressure,
            CASE
                WHEN lookback_param IS NULL THEN NULL
                ELSE COALESCE(MAX(GREATEST(h.t0_out - h.t0_in, 0)), 0)
            END AS max_buy_pressure,
            CASE
                WHEN lookback_param IS NULL THEN NULL
                ELSE COALESCE(MAX(GREATEST(h.t1_in - h.t1_out, 0)), 0)
            END AS max_t1_sell_pressure,
            CASE
                WHEN lookback_param IS NULL THEN NULL
                ELSE COALESCE(MAX(GREATEST(h.t1_out - h.t1_in, 0)), 0)
            END AS max_t1_buy_pressure
        FROM (
            SELECT
                time_bucket('1 hour'::interval, c.bucket_time) AS hour_bucket,
                SUM(c.amount0_in) AS t0_in,
                SUM(c.amount0_out) AS t0_out,
                SUM(c.amount1_in) AS t1_in,
                SUM(c.amount1_out) AS t1_out
            FROM dexes.cagg_events_5s c
            WHERE c.pool_address = v_pool_address
              AND c.activity_category = 'swap'
              AND lookback_param IS NOT NULL
              AND c.bucket_time >= v_lookback_start
            GROUP BY 1
        ) h
    )
    SELECT
        -- ── Pool identifiers (1-3) ──────────────────────────────────────
        v_pool_address,
        v_protocol,
        v_token_pair,

        -- ── Symbols (4) ─────────────────────────────────────────────────
        CASE WHEN p_invert
             THEN ARRAY[v_symbols_t0_t1[2], v_symbols_t0_t1[1]]
             ELSE v_symbols_t0_t1 END,

        -- ── Liquidity query metadata (5-6) ──────────────────────────────
        v_liq_query_id,
        CASE WHEN p_invert
             THEN ROUND((1.0 / NULLIF(v_price_t1_per_t0, 0))::NUMERIC, 8)
             ELSE ROUND(v_price_t1_per_t0::NUMERIC, 8) END,

        -- ── Standard trade-size impact – "t0 sell" columns (7-10) ───────
        ARRAY[50000.0, 100000.0, 500000.0]::DOUBLE PRECISION[],
        ROUND(impact_bps_from_qsell_latest(v_pool_address, v_inv_side_t0, 50000.0)::NUMERIC, 4),
        ROUND(impact_bps_from_qsell_latest(v_pool_address, v_inv_side_t0, 100000.0)::NUMERIC, 4),
        ROUND(impact_bps_from_qsell_latest(v_pool_address, v_inv_side_t0, 500000.0)::NUMERIC, 4),

        -- ── Reserves (11-15) ────────────────────────────────────────────
        CASE WHEN p_invert THEN ROUND(v_t1_reserve::NUMERIC)::BIGINT
             ELSE ROUND(v_t0_reserve::NUMERIC)::BIGINT END,
        CASE WHEN p_invert THEN ROUND(v_t0_reserve::NUMERIC)::BIGINT
             ELSE ROUND(v_t1_reserve::NUMERIC)::BIGINT END,
        CASE WHEN p_invert
             THEN ROUND(((v_t1_reserve / NULLIF(v_price_t1_per_t0, 0)) + v_t0_reserve)::NUMERIC)::BIGINT
             ELSE ROUND(((v_t0_reserve * v_price_t1_per_t0) + v_t1_reserve)::NUMERIC)::BIGINT END,
        CASE WHEN p_invert THEN ARRAY[
            ROUND((v_t1_reserve / 1000000.0)::NUMERIC, 1),
            ROUND((v_t0_reserve / 1000000.0)::NUMERIC, 1)
        ]::NUMERIC[] ELSE ARRAY[
            ROUND((v_t0_reserve / 1000000.0)::NUMERIC, 1),
            ROUND((v_t1_reserve / 1000000.0)::NUMERIC, 1)
        ]::NUMERIC[] END,
        CASE WHEN p_invert THEN ARRAY[
            ROUND((CASE
                WHEN (v_t1_reserve / NULLIF(v_price_t1_per_t0, 0)) + v_t0_reserve > 0
                THEN ((v_t1_reserve / NULLIF(v_price_t1_per_t0, 0)) / ((v_t1_reserve / NULLIF(v_price_t1_per_t0, 0)) + v_t0_reserve)) * 100
                ELSE NULL END)::NUMERIC, 0),
            ROUND((CASE
                WHEN (v_t1_reserve / NULLIF(v_price_t1_per_t0, 0)) + v_t0_reserve > 0
                THEN (v_t0_reserve / ((v_t1_reserve / NULLIF(v_price_t1_per_t0, 0)) + v_t0_reserve)) * 100
                ELSE NULL END)::NUMERIC, 0)
        ]::NUMERIC[] ELSE ARRAY[
            ROUND((CASE
                WHEN (v_t0_reserve * v_price_t1_per_t0) + v_t1_reserve > 0
                THEN ((v_t0_reserve * v_price_t1_per_t0) / ((v_t0_reserve * v_price_t1_per_t0) + v_t1_reserve)) * 100
                ELSE NULL END)::NUMERIC, 0),
            ROUND((CASE
                WHEN (v_t0_reserve * v_price_t1_per_t0) + v_t1_reserve > 0
                THEN (v_t1_reserve / ((v_t0_reserve * v_price_t1_per_t0) + v_t1_reserve)) * 100
                ELSE NULL END)::NUMERIC, 0)
        ]::NUMERIC[] END,

        -- ── Event counts (16-18) – symmetric ────────────────────────────
        CASE WHEN lookback_param IS NULL THEN NULL ELSE COALESCE(sm.swap_events, 0) END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE COALESCE(lm.lp_add_events, 0) END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE COALESCE(lm.lp_remove_events, 0) END,

        -- ── Swap total volume (19-22) ───────────────────────────────────
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(
            CASE WHEN p_invert THEN sm.vol_t0 ELSE sm.vol_t1 END::NUMERIC)::BIGINT END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(
            CASE WHEN p_invert THEN sm.vol_t1 ELSE sm.vol_t0 END::NUMERIC)::BIGINT END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND((CASE
            WHEN p_invert AND v_t0_reserve > 0 THEN (sm.vol_t0 / v_t0_reserve) * 100
            WHEN NOT p_invert AND v_t1_reserve > 0 THEN (sm.vol_t1 / v_t1_reserve) * 100
            ELSE NULL END)::NUMERIC, 2) END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND((CASE
            WHEN p_invert AND v_t1_reserve > 0 THEN (sm.vol_t1 / v_t1_reserve) * 100
            WHEN NOT p_invert AND v_t0_reserve > 0 THEN (sm.vol_t0 / v_t0_reserve) * 100
            ELSE NULL END)::NUMERIC, 2) END,

        -- ── Swap out volume (23-26) ─────────────────────────────────────
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(COALESCE(
            CASE WHEN p_invert THEN sm.vol_t0_out ELSE sm.vol_t1_out END, 0)::NUMERIC)::BIGINT END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(COALESCE(
            CASE WHEN p_invert THEN sm.vol_t1_out ELSE sm.vol_t0_out END, 0)::NUMERIC)::BIGINT END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND((CASE
            WHEN p_invert AND v_t0_reserve > 0 THEN (sm.vol_t0_out / v_t0_reserve) * 100
            WHEN NOT p_invert AND v_t1_reserve > 0 THEN (sm.vol_t1_out / v_t1_reserve) * 100
            ELSE NULL END)::NUMERIC, 2) END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND((CASE
            WHEN p_invert AND v_t1_reserve > 0 THEN (sm.vol_t1_out / v_t1_reserve) * 100
            WHEN NOT p_invert AND v_t0_reserve > 0 THEN (sm.vol_t0_out / v_t0_reserve) * 100
            ELSE NULL END)::NUMERIC, 2) END,

        -- ── Directional swap volumes (27-30) ────────────────────────────
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(COALESCE(
            CASE WHEN p_invert THEN sm.vol_t1_in ELSE sm.vol_t0_in END, 0)::NUMERIC)::BIGINT END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(COALESCE(
            CASE WHEN p_invert THEN sm.vol_t1_out ELSE sm.vol_t0_out END, 0)::NUMERIC)::BIGINT END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(COALESCE(
            CASE WHEN p_invert THEN sm.vol_t0_in ELSE sm.vol_t1_in END, 0)::NUMERIC)::BIGINT END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(COALESCE(
            CASE WHEN p_invert THEN sm.vol_t0_out ELSE sm.vol_t1_out END, 0)::NUMERIC)::BIGINT END,

        -- ── LP flows (31-34) ────────────────────────────────────────────
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(
            CASE WHEN p_invert THEN lm.lp_t1_in ELSE lm.lp_t0_in END::NUMERIC)::BIGINT END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(
            CASE WHEN p_invert THEN lm.lp_t1_out ELSE lm.lp_t0_out END::NUMERIC)::BIGINT END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(
            CASE WHEN p_invert THEN lm.lp_t0_in ELSE lm.lp_t1_in END::NUMERIC)::BIGINT END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(
            CASE WHEN p_invert THEN lm.lp_t0_out ELSE lm.lp_t1_out END::NUMERIC)::BIGINT END,

        -- ── LP flows % of reserves (35-38) ──────────────────────────────
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND((CASE
            WHEN p_invert AND v_t1_reserve > 0 THEN (lm.lp_t1_in / v_t1_reserve) * 100
            WHEN NOT p_invert AND v_t0_reserve > 0 THEN (lm.lp_t0_in / v_t0_reserve) * 100
            ELSE NULL END)::NUMERIC, 2) END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND((CASE
            WHEN p_invert AND v_t1_reserve > 0 THEN (lm.lp_t1_out / v_t1_reserve) * 100
            WHEN NOT p_invert AND v_t0_reserve > 0 THEN (lm.lp_t0_out / v_t0_reserve) * 100
            ELSE NULL END)::NUMERIC, 2) END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND((CASE
            WHEN p_invert AND v_t0_reserve > 0 THEN (lm.lp_t0_in / v_t0_reserve) * 100
            WHEN NOT p_invert AND v_t1_reserve > 0 THEN (lm.lp_t1_in / v_t1_reserve) * 100
            ELSE NULL END)::NUMERIC, 2) END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND((CASE
            WHEN p_invert AND v_t0_reserve > 0 THEN (lm.lp_t0_out / v_t0_reserve) * 100
            WHEN NOT p_invert AND v_t1_reserve > 0 THEN (lm.lp_t1_out / v_t1_reserve) * 100
            ELSE NULL END)::NUMERIC, 2) END,

        -- ── Max swap flows with complements (39-44) ─────────────────────
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(
            CASE WHEN p_invert THEN mis.max_t0_in ELSE mis.max_t1_in END::NUMERIC)::BIGINT END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(
            CASE WHEN p_invert THEN msc.max_t0_in_t1_complement ELSE msc.max_t1_in_t0_complement END::NUMERIC)::BIGINT END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(
            CASE WHEN p_invert THEN mis.max_t0_out ELSE mis.max_t1_out END::NUMERIC)::BIGINT END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(
            CASE WHEN p_invert THEN msc.max_t0_out_t1_complement ELSE msc.max_t1_out_t0_complement END::NUMERIC)::BIGINT END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(
            CASE WHEN p_invert THEN mis.max_t1_in ELSE mis.max_t0_in END::NUMERIC)::BIGINT END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(
            CASE WHEN p_invert THEN mis.max_t1_out ELSE mis.max_t0_out END::NUMERIC)::BIGINT END,

        -- ── Average swap flows (45-48) ──────────────────────────────────
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(COALESCE(
            CASE WHEN p_invert THEN ais.avg_t1_in ELSE ais.avg_t0_in END, 0)::NUMERIC, 0) END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(COALESCE(
            CASE WHEN p_invert THEN ais.avg_t1_out ELSE ais.avg_t0_out END, 0)::NUMERIC, 0) END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(COALESCE(
            CASE WHEN p_invert THEN ais.avg_t0_in ELSE ais.avg_t1_in END, 0)::NUMERIC, 0) END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(COALESCE(
            CASE WHEN p_invert THEN ais.avg_t0_out ELSE ais.avg_t1_out END, 0)::NUMERIC, 0) END,

        -- ── Max swap % of reserves (49-50) ──────────────────────────────
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND((CASE
            WHEN p_invert AND v_t0_reserve > 0 THEN (mis.max_t0_in / v_t0_reserve) * 100
            WHEN NOT p_invert AND v_t1_reserve > 0 THEN (mis.max_t1_in / v_t1_reserve) * 100
            ELSE NULL END)::NUMERIC, 2) END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND((CASE
            WHEN p_invert AND v_t0_reserve > 0 THEN (mis.max_t0_out / v_t0_reserve) * 100
            WHEN NOT p_invert AND v_t1_reserve > 0 THEN (mis.max_t1_out / v_t1_reserve) * 100
            ELSE NULL END)::NUMERIC, 2) END,

        -- ── Max swap impacts (51-54) ────────────────────────────────────
        CASE
            WHEN lookback_param IS NULL THEN NULL
            WHEN p_invert AND COALESCE(mis.max_t0_in, 0) <= 0 THEN NULL
            WHEN NOT p_invert AND COALESCE(mis.max_t1_in, 0) <= 0 THEN NULL
            WHEN p_invert THEN ROUND(impact_bps_from_qsell_latest(v_pool_address, 't0', mis.max_t0_in)::NUMERIC, 4)
            ELSE ROUND(impact_bps_from_qsell_latest(v_pool_address, 't1', mis.max_t1_in)::NUMERIC, 4)
        END,
        CASE
            WHEN lookback_param IS NULL THEN NULL
            WHEN p_invert AND COALESCE(msc.max_t0_out_t1_complement, 0) <= 0 THEN NULL
            WHEN NOT p_invert AND COALESCE(msc.max_t1_out_t0_complement, 0) <= 0 THEN NULL
            WHEN p_invert THEN ROUND(impact_bps_from_qsell_latest(v_pool_address, 't1', msc.max_t0_out_t1_complement)::NUMERIC, 4)
            ELSE ROUND(impact_bps_from_qsell_latest(v_pool_address, 't0', msc.max_t1_out_t0_complement)::NUMERIC, 4)
        END,
        CASE
            WHEN lookback_param IS NULL THEN NULL
            WHEN p_invert AND COALESCE(mis.max_t1_in, 0) <= 0 THEN 0
            WHEN NOT p_invert AND COALESCE(mis.max_t0_in, 0) <= 0 THEN 0
            WHEN p_invert THEN ROUND(impact_bps_from_qsell_latest(v_pool_address, 't1', mis.max_t1_in)::NUMERIC, 4)
            ELSE ROUND(impact_bps_from_qsell_latest(v_pool_address, 't0', mis.max_t0_in)::NUMERIC, 4)
        END,
        CASE
            WHEN lookback_param IS NULL THEN NULL
            WHEN p_invert AND COALESCE(msc.max_t1_out_t0_complement, 0) <= 0 THEN 0
            WHEN NOT p_invert AND COALESCE(msc.max_t0_out_t1_complement, 0) <= 0 THEN 0
            WHEN p_invert THEN ROUND(impact_bps_from_qsell_latest(v_pool_address, 't0', msc.max_t1_out_t0_complement)::NUMERIC, 4)
            ELSE ROUND(impact_bps_from_qsell_latest(v_pool_address, 't1', msc.max_t0_out_t1_complement)::NUMERIC, 4)
        END,

        -- ── Avg swap impacts (55-58) ────────────────────────────────────
        CASE
            WHEN lookback_param IS NULL THEN NULL
            WHEN p_invert AND COALESCE(ais.avg_t1_in, 0) <= 0 THEN 0
            WHEN NOT p_invert AND COALESCE(ais.avg_t0_in, 0) <= 0 THEN 0
            WHEN p_invert THEN ROUND(impact_bps_from_qsell_latest(v_pool_address, 't1', ais.avg_t1_in)::NUMERIC, 4)
            ELSE ROUND(impact_bps_from_qsell_latest(v_pool_address, 't0', ais.avg_t0_in)::NUMERIC, 4)
        END,
        CASE
            WHEN lookback_param IS NULL THEN NULL
            WHEN p_invert AND COALESCE(ais.avg_t1_out, 0) <= 0 THEN 0
            WHEN NOT p_invert AND COALESCE(ais.avg_t0_out, 0) <= 0 THEN 0
            WHEN p_invert THEN ROUND(impact_bps_from_qsell_latest(v_pool_address, 't0', ais.avg_t1_out)::NUMERIC, 4)
            ELSE ROUND(impact_bps_from_qsell_latest(v_pool_address, 't1', ais.avg_t0_out)::NUMERIC, 4)
        END,
        CASE
            WHEN lookback_param IS NULL THEN NULL
            WHEN p_invert AND COALESCE(ais.avg_t0_in, 0) <= 0 THEN 0
            WHEN NOT p_invert AND COALESCE(ais.avg_t1_in, 0) <= 0 THEN 0
            WHEN p_invert THEN ROUND(impact_bps_from_qsell_latest(v_pool_address, 't0', ais.avg_t0_in)::NUMERIC, 4)
            ELSE ROUND(impact_bps_from_qsell_latest(v_pool_address, 't1', ais.avg_t1_in)::NUMERIC, 4)
        END,
        CASE
            WHEN lookback_param IS NULL THEN NULL
            WHEN p_invert AND COALESCE(ais.avg_t0_out, 0) <= 0 THEN 0
            WHEN NOT p_invert AND COALESCE(ais.avg_t1_out, 0) <= 0 THEN 0
            WHEN p_invert THEN ROUND(impact_bps_from_qsell_latest(v_pool_address, 't1', ais.avg_t0_out)::NUMERIC, 4)
            ELSE ROUND(impact_bps_from_qsell_latest(v_pool_address, 't0', ais.avg_t1_out)::NUMERIC, 4)
        END,

        -- ── VWAP metrics (59-62) ────────────────────────────────────────
        CASE WHEN lookback_param IS NULL THEN NULL
             WHEN p_invert THEN ROUND((1.0 / NULLIF(sm.avg_vwap_sell, 0))::NUMERIC, 6)
             ELSE ROUND(sm.avg_vwap_buy::NUMERIC, 6) END,
        CASE WHEN lookback_param IS NULL THEN NULL
             WHEN p_invert THEN ROUND((1.0 / NULLIF(sm.avg_vwap_buy, 0))::NUMERIC, 6)
             ELSE ROUND(sm.avg_vwap_sell::NUMERIC, 6) END,
        CASE WHEN lookback_param IS NULL THEN NULL
             WHEN p_invert THEN ROUND((1.0 / NULLIF(sm.avg_price, 0))::NUMERIC, 8)
             ELSE ROUND(sm.avg_price::NUMERIC, 8) END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND((CASE
            WHEN sm.avg_price > 0
                 AND COALESCE(sm.vwap_buy_volume, 0) >= 1.0
                 AND COALESCE(sm.vwap_sell_volume, 0) >= 1.0
            THEN CASE WHEN p_invert
                 THEN ((sm.avg_vwap_buy - sm.avg_vwap_sell) / NULLIF(sm.avg_vwap_buy * sm.avg_vwap_sell, 0)) * sm.avg_price * 10000
                 ELSE ((sm.avg_vwap_buy - sm.avg_vwap_sell) / sm.avg_price) * 10000 END
            ELSE NULL
        END)::NUMERIC, 4) END,

        -- ── Price statistics (63-65) ────────────────────────────────────
        CASE WHEN lookback_param IS NULL THEN NULL
             WHEN p_invert THEN ROUND((1.0 / NULLIF(sm.min_price, 0))::NUMERIC, 8)
             ELSE ROUND(sm.max_price::NUMERIC, 8) END,
        CASE WHEN lookback_param IS NULL THEN NULL
             WHEN p_invert THEN ROUND((1.0 / NULLIF(sm.max_price, 0))::NUMERIC, 8)
             ELSE ROUND(sm.min_price::NUMERIC, 8) END,
        CASE WHEN lookback_param IS NULL THEN NULL
             WHEN p_invert AND sm.avg_price > 0
                 THEN ROUND((sm.std_price / NULLIF(POWER(sm.avg_price, 2), 0))::NUMERIC, 8)
             ELSE ROUND(sm.std_price::NUMERIC, 8) END,

        -- ── 24-hour fixed window metrics (66-68) ────────────────────────
        CASE WHEN p_invert
             THEN ROUND(COALESCE(s24h.vol_t0_total_24h, 0)::NUMERIC)::BIGINT
             ELSE ROUND(COALESCE(s24h.vol_t1_total_24h, 0)::NUMERIC)::BIGINT END,
        CASE WHEN p_invert THEN ROUND((CASE
            WHEN ((v_t1_reserve / NULLIF(v_price_t1_per_t0, 0)) + v_t0_reserve) > 0
            THEN (COALESCE(s24h.vol_t0_total_24h, 0) / ((v_t1_reserve / NULLIF(v_price_t1_per_t0, 0)) + v_t0_reserve)) * 100
            ELSE NULL END)::NUMERIC, 1)
        ELSE ROUND((CASE
            WHEN ((v_t0_reserve * v_price_t1_per_t0) + v_t1_reserve) > 0
            THEN (COALESCE(s24h.vol_t1_total_24h, 0) / ((v_t0_reserve * v_price_t1_per_t0) + v_t1_reserve)) * 100
            ELSE NULL END)::NUMERIC, 1) END,
        COALESCE(s24h.swap_count_24h, 0),

        -- ── Max 1-hour pressure metrics (69-72) ─────────────────────────
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(COALESCE(
            CASE WHEN p_invert THEN mp.max_t1_sell_pressure ELSE mp.max_sell_pressure END, 0)::NUMERIC, 0)::BIGINT END,
        CASE WHEN lookback_param IS NULL THEN NULL ELSE ROUND(COALESCE(
            CASE WHEN p_invert THEN mp.max_t1_buy_pressure ELSE mp.max_buy_pressure END, 0)::NUMERIC, 0)::BIGINT END,
        CASE
            WHEN lookback_param IS NULL THEN NULL
            WHEN p_invert AND COALESCE(mp.max_t1_sell_pressure, 0) <= 0 THEN 0
            WHEN NOT p_invert AND COALESCE(mp.max_sell_pressure, 0) <= 0 THEN 0
            WHEN p_invert THEN ROUND(impact_bps_from_qsell_latest(v_pool_address, 't1', mp.max_t1_sell_pressure)::NUMERIC, 4)
            ELSE ROUND(impact_bps_from_qsell_latest(v_pool_address, 't0', mp.max_sell_pressure)::NUMERIC, 4)
        END,
        CASE
            WHEN lookback_param IS NULL THEN NULL
            WHEN p_invert AND COALESCE(mp.max_t1_buy_pressure, 0) <= 0 THEN 0
            WHEN NOT p_invert AND COALESCE(mp.max_buy_pressure, 0) <= 0 THEN 0
            WHEN p_invert THEN ROUND(impact_bps_from_qsell_latest(v_pool_address, 't0', mp.max_t1_buy_pressure)::NUMERIC, 4)
            ELSE ROUND(impact_bps_from_qsell_latest(v_pool_address, 't1', mp.max_buy_pressure)::NUMERIC, 4)
        END,

        -- ── Standard trade-size impact – "t1 sell" columns (73-76) ──────
        ARRAY[50000.0, 100000.0, 500000.0]::DOUBLE PRECISION[],
        ROUND(impact_bps_from_qsell_latest(v_pool_address, v_inv_side_t1, 50000.0)::NUMERIC, 4),
        ROUND(impact_bps_from_qsell_latest(v_pool_address, v_inv_side_t1, 100000.0)::NUMERIC, 4),
        ROUND(impact_bps_from_qsell_latest(v_pool_address, v_inv_side_t1, 500000.0)::NUMERIC, 4)
    FROM swap_metrics sm
    CROSS JOIN max_individual_swaps mis
    CROSS JOIN max_swap_complements msc
    CROSS JOIN avg_individual_swaps ais
    CROSS JOIN lp_metrics lm
    CROSS JOIN swap_24h_metrics s24h
    CROSS JOIN max_1h_pressure_metrics mp;
    END LOOP;

END;
$$ LANGUAGE plpgsql STABLE
SET search_path TO dexes, public;

COMMENT ON FUNCTION dexes.get_view_dex_last(TEXT, TEXT, INTERVAL, BOOLEAN) IS
'Returns most recent DEX metrics for a specific pool in a single row with formatted rounding.
Aggregates liquidity depth, vault reserves, swap activity, and LP activity metrics.

Parameters:
  protocol (e.g. ''raydium''), pair (e.g. ''SOL-USDC''),
  lookback interval (e.g. ''1 hour'', ''24 hours''),
  p_invert (FALSE = default t0→t1 view, TRUE = swap t0↔t1 perspective).

When p_invert = TRUE the output swaps t0/t1 perspectives:
  - Prices: price_t1_per_t0 becomes 1/original
  - Symbols: array reversed
  - Reserves: t0_reserve ↔ t1_reserve
  - All volume, LP, swap, impact columns: t0 data ↔ t1 data
  - VWAPs: inverted and buy/sell swapped
  - Pressure metrics: computed from t1 hourly flows instead of t0';
