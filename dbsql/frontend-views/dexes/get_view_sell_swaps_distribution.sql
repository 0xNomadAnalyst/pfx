-- =====================================================
-- Sell Swap Distribution (optimised pfx edition)
-- =====================================================
-- Replaces N per-row calls to impact_bps_from_qsell_latest with:
--   1. A single pre-fetch of the pool's current state (sqrt_price, decimals,
--      active-tick liquidity & capacity).
--   2. An inline CLMM formula for every bucket whose midpoint stays within
--      the active tick (the vast majority).
--   3. The expensive function call only for the few cross-tick buckets AND
--      only when the bucket is non-empty (swap_count > 0).
--
-- Additional improvements over the original:
--   * p_invert support  (matches DBSQL contract signature)
--   * Time-filtered pool-address lookup (avoids full cagg scan)
--   * Direct token_pair = comparison (index-friendly, no LOWER())
-- =====================================================

DROP FUNCTION IF EXISTS dexes.get_view_sell_swaps_distribution(TEXT, TEXT, TEXT, TEXT, INTEGER);
DROP FUNCTION IF EXISTS dexes.get_view_sell_swaps_distribution(TEXT, TEXT, TEXT, TEXT, INTEGER, BOOLEAN);
CREATE OR REPLACE FUNCTION dexes.get_view_sell_swaps_distribution(
    p_protocol TEXT,
    p_pair TEXT,
    p_token TEXT DEFAULT 't0',
    p_lookback TEXT DEFAULT '7 days',
    p_buckets INTEGER DEFAULT 50,
    p_invert BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    bucket_number INTEGER,
    bucket_min DOUBLE PRECISION,
    bucket_max DOUBLE PRECISION,
    bucket_max_in_k DOUBLE PRECISION,
    bucket_midpoint DOUBLE PRECISION,
    swap_count INTEGER,
    cumulative_share DOUBLE PRECISION,
    price_impact_bps DOUBLE PRECISION,
    price_impact_bps_abs DOUBLE PRECISION,
    price_impact_bps_inv DOUBLE PRECISION,
    percentile_10 DOUBLE PRECISION,
    percentile_25 DOUBLE PRECISION,
    percentile_50 DOUBLE PRECISION,
    percentile_75 DOUBLE PRECISION,
    percentile_90 DOUBLE PRECISION,
    total_swaps BIGINT,
    earliest_swap TIMESTAMPTZ,
    latest_swap TIMESTAMPTZ
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_lookback_interval INTERVAL;
    v_pool_address TEXT;
    -- Resolved token side (accounts for p_invert)
    v_eff_token TEXT;
    -- Pre-fetched pool state for inline impact
    v_query_id BIGINT;
    v_current_tick INTEGER;
    v_sqrt_price_x64 NUMERIC(40,0);
    v_mint_decimals_0 SMALLINT;
    v_mint_decimals_1 SMALLINT;
    v_dec_adj DOUBLE PRECISION;
    v_sqrt_cur DOUBLE PRECISION;
    v_cur_price DOUBLE PRECISION;
    v_active_liq DOUBLE PRECISION;
    v_active_cap DOUBLE PRECISION;   -- max qty sellable in active tick
    v_pow_dec DOUBLE PRECISION;      -- 10^relevant_decimals
BEGIN
    IF p_token NOT IN ('t0', 't1') THEN
        RAISE EXCEPTION 'Invalid token parameter: %. Must be t0 or t1', p_token;
    END IF;

    BEGIN
        v_lookback_interval := p_lookback::INTERVAL;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Invalid lookback: %', p_lookback;
    END;

    IF p_buckets IS NULL OR p_buckets < 1 OR p_buckets > 1000 THEN
        RAISE EXCEPTION 'Invalid buckets: %', p_buckets;
    END IF;

    -- When inverted, the logical t0 is really the physical t1 and vice-versa.
    v_eff_token := CASE
        WHEN p_invert THEN CASE WHEN p_token = 't0' THEN 't1' ELSE 't0' END
        ELSE p_token
    END;

    -- ── Pool address (time-filtered, index-friendly) ─────────────────
    SELECT DISTINCT e.pool_address INTO v_pool_address
    FROM dexes.cagg_events_5s e
    WHERE e.protocol = p_protocol
      AND e.token_pair = p_pair
      AND e.activity_category = 'swap'
      AND e.bucket_time >= NOW() - v_lookback_interval
    LIMIT 1;

    -- ── Pre-fetch pool state for inline CLMM ────────────────────────
    IF v_pool_address IS NOT NULL THEN
        SELECT MAX(query_id) INTO v_query_id
        FROM dexes.src_acct_tickarray_tokendist_latest
        WHERE pool_address = v_pool_address;

        IF v_query_id IS NOT NULL THEN
            SELECT q.current_tick, q.mint_decimals_0, q.mint_decimals_1, q.sqrt_price_x64
            INTO v_current_tick, v_mint_decimals_0, v_mint_decimals_1, v_sqrt_price_x64
            FROM dexes.src_acct_tickarray_queries q
            WHERE q.query_id = v_query_id;

            IF v_current_tick IS NOT NULL THEN
                v_dec_adj   := POWER(10, v_mint_decimals_0 - v_mint_decimals_1);
                v_sqrt_cur  := v_sqrt_price_x64::DOUBLE PRECISION / POWER(2::DOUBLE PRECISION, 64);
                v_cur_price := POWER(v_sqrt_cur, 2) * v_dec_adj;

                IF v_eff_token = 't0' THEN
                    SELECT COALESCE(t.token0_sold_cumul, 0), t.liquidity_balance
                    INTO v_active_cap, v_active_liq
                    FROM dexes.src_acct_tickarray_tokendist_latest t
                    WHERE t.pool_address = v_pool_address
                      AND t.tick_lower <= v_current_tick
                      AND t.tick_upper > v_current_tick
                    LIMIT 1;
                    v_pow_dec := POWER(10, v_mint_decimals_0);
                ELSE
                    SELECT COALESCE(t.token1_sold_cumul, 0), t.liquidity_balance
                    INTO v_active_cap, v_active_liq
                    FROM dexes.src_acct_tickarray_tokendist_latest t
                    WHERE t.pool_address = v_pool_address
                      AND t.tick_lower <= v_current_tick
                      AND t.tick_upper > v_current_tick
                    LIMIT 1;
                    v_pow_dec := POWER(10, v_mint_decimals_1);
                END IF;
            END IF;
        END IF;
    END IF;

    -- ── Main query ──────────────────────────────────────────────────
    RETURN QUERY
    WITH swap_data AS (
        SELECT
            c.bucket_time AS time,
            CASE
                WHEN v_eff_token = 't0' THEN c.amount0_in_max
                ELSE c.amount1_in_max
            END AS token_amount
        FROM dexes.cagg_events_5s c
        WHERE c.protocol = p_protocol
          AND c.token_pair = p_pair
          AND c.activity_category = 'swap'
          AND c.bucket_time >= NOW() - v_lookback_interval
          AND (
              (v_eff_token = 't0' AND c.amount0_in_max IS NOT NULL)
              OR (v_eff_token = 't1' AND c.amount1_in_max IS NOT NULL)
          )
    ),
    sample_stats AS (
        SELECT
            COUNT(*)::BIGINT AS total_swaps,
            MIN(time)        AS earliest_swap,
            MAX(time)        AS latest_swap,
            MIN(token_amount) AS min_amount,
            MAX(token_amount) AS max_amount,
            PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY token_amount) AS p10,
            PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY token_amount) AS p25,
            PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY token_amount) AS p50,
            PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY token_amount) AS p75,
            PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY token_amount) AS p90
        FROM swap_data
    ),
    bucket_ranges AS (
        SELECT
            CASE
                WHEN ss.min_amount = ss.max_amount THEN CEIL(p_buckets::NUMERIC / 2)::INTEGER
                ELSE LEAST(WIDTH_BUCKET(sd.token_amount, ss.min_amount, ss.max_amount, p_buckets), p_buckets)
            END AS bucket_num
        FROM swap_data sd
        CROSS JOIN sample_stats ss
    ),
    all_buckets AS (
        SELECT generate_series(1, p_buckets) AS bucket_num
    ),
    bucket_counts AS (
        SELECT br.bucket_num, COUNT(*)::INTEGER AS swap_count
        FROM bucket_ranges br
        WHERE br.bucket_num BETWEEN 1 AND p_buckets
        GROUP BY br.bucket_num
    ),
    bucket_aggregates AS (
        SELECT
            ab.bucket_num,
            CASE
                WHEN ss.min_amount = ss.max_amount THEN
                    ss.min_amount - COALESCE(NULLIF(ABS(ss.min_amount) * 0.01, 0), 1) * 0.5
                        + (ab.bucket_num - 1) * COALESCE(NULLIF(ABS(ss.min_amount) * 0.01, 0), 1) / p_buckets
                ELSE
                    ss.min_amount + (ab.bucket_num - 1) * (ss.max_amount - ss.min_amount) / p_buckets
            END AS bucket_min,
            CASE
                WHEN ss.min_amount = ss.max_amount THEN
                    ss.min_amount - COALESCE(NULLIF(ABS(ss.min_amount) * 0.01, 0), 1) * 0.5
                        + ab.bucket_num * COALESCE(NULLIF(ABS(ss.min_amount) * 0.01, 0), 1) / p_buckets
                ELSE
                    ss.min_amount + ab.bucket_num * (ss.max_amount - ss.min_amount) / p_buckets
            END AS bucket_max,
            COALESCE(bc.swap_count, 0)::INTEGER AS swap_count,
            SUM(COALESCE(bc.swap_count, 0)) OVER (ORDER BY ab.bucket_num) AS cumulative_count
        FROM all_buckets ab
        CROSS JOIN sample_stats ss
        LEFT JOIN bucket_counts bc ON ab.bucket_num = bc.bucket_num
        WHERE ss.total_swaps > 0
    ),
    distribution_with_share AS (
        SELECT
            ba.bucket_num,
            ba.bucket_min,
            ba.bucket_max,
            (ba.bucket_min + ba.bucket_max) / 2.0 AS bucket_midpoint,
            ba.swap_count,
            CASE
                WHEN ss.total_swaps > 0
                THEN (ba.cumulative_count::DOUBLE PRECISION / ss.total_swaps::DOUBLE PRECISION) * 100.0
                ELSE 0
            END AS cumulative_share,
            ss.total_swaps,
            ss.earliest_swap,
            ss.latest_swap,
            ss.p10, ss.p25, ss.p50, ss.p75, ss.p90
        FROM bucket_aggregates ba
        CROSS JOIN sample_stats ss
    ),
    distribution_with_impact AS (
        SELECT
            dws.*,
            CASE
                -- ① Fast path: inline CLMM for trades within active tick
                WHEN v_active_liq IS NOT NULL
                     AND v_active_liq > 0
                     AND v_cur_price > 0
                     AND dws.bucket_midpoint > 0
                     AND dws.bucket_midpoint <= COALESCE(v_active_cap, 0)
                THEN
                    CASE WHEN v_eff_token = 't0' THEN
                        (POWER(
                            1.0 / (1.0 / v_sqrt_cur
                                   + dws.bucket_midpoint * v_pow_dec / v_active_liq),
                            2
                        ) * v_dec_adj - v_cur_price)
                        / v_cur_price * 10000
                    ELSE
                        (POWER(
                            v_sqrt_cur
                            + dws.bucket_midpoint * v_pow_dec / v_active_liq,
                            2
                        ) * v_dec_adj - v_cur_price)
                        / v_cur_price * 10000
                    END
                -- ② Slow path: cross-tick trade, non-empty bucket only
                WHEN v_pool_address IS NOT NULL
                     AND dws.bucket_midpoint > 0
                     AND dws.swap_count > 0
                THEN
                    dexes.impact_bps_from_qsell_latest(
                        v_pool_address, v_eff_token, dws.bucket_midpoint
                    )
                ELSE NULL
            END AS impact_raw
        FROM distribution_with_share dws
    )
    SELECT
        dwi.bucket_num::INTEGER,
        ROUND(dwi.bucket_min::NUMERIC, 2)::DOUBLE PRECISION,
        ROUND(dwi.bucket_max::NUMERIC, 2)::DOUBLE PRECISION,
        ROUND((dwi.bucket_max / 1000.0)::NUMERIC, 1)::DOUBLE PRECISION,
        ROUND(dwi.bucket_midpoint::NUMERIC, 2)::DOUBLE PRECISION,
        dwi.swap_count,
        ROUND(dwi.cumulative_share::NUMERIC, 4)::DOUBLE PRECISION,
        ROUND(dwi.impact_raw::NUMERIC, 4)::DOUBLE PRECISION,
        ROUND(ABS(dwi.impact_raw)::NUMERIC, 4)::DOUBLE PRECISION,
        ROUND((dwi.impact_raw * -1)::NUMERIC, 4)::DOUBLE PRECISION,
        ROUND(dwi.p10::NUMERIC, 2)::DOUBLE PRECISION,
        ROUND(dwi.p25::NUMERIC, 2)::DOUBLE PRECISION,
        ROUND(dwi.p50::NUMERIC, 2)::DOUBLE PRECISION,
        ROUND(dwi.p75::NUMERIC, 2)::DOUBLE PRECISION,
        ROUND(dwi.p90::NUMERIC, 2)::DOUBLE PRECISION,
        dwi.total_swaps,
        dwi.earliest_swap,
        dwi.latest_swap
    FROM distribution_with_impact dwi
    ORDER BY dwi.bucket_num;
END;
$$;
