-- =====================================================
-- Sell Pressure T0 Distribution (optimised pfx edition)
-- =====================================================
-- Same inline-CLMM / pre-fetch strategy as the sell-swaps distribution.
--
-- Key differences from the original:
--   * p_invert support  (matches DBSQL contract signature)
--   * Time-filtered pool-address lookup
--   * Direct token_pair comparison (no LOWER())
--   * Pre-fetched pool state → inline CLMM for active-tick buckets
--   * Expensive impact_bps_from_qsell_latest only for cross-tick AND
--     non-empty buckets
-- =====================================================

DROP FUNCTION IF EXISTS dexes.get_view_sell_pressure_t0_distribution(TEXT, TEXT, TEXT, TEXT, INTEGER, TEXT);
DROP FUNCTION IF EXISTS dexes.get_view_sell_pressure_t0_distribution(TEXT, TEXT, TEXT, TEXT, INTEGER, TEXT, BOOLEAN);
CREATE OR REPLACE FUNCTION dexes.get_view_sell_pressure_t0_distribution(
    p_protocol TEXT,
    p_token_pair TEXT,
    p_pressure_interval TEXT DEFAULT '5 minutes',
    p_lookback TEXT DEFAULT '7 days',
    p_buckets INTEGER DEFAULT 50,
    p_pressure_filter TEXT DEFAULT NULL,
    p_invert BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    bucket_number INTEGER,
    bucket_min DOUBLE PRECISION,
    bucket_max DOUBLE PRECISION,
    bucket_max_in_k DOUBLE PRECISION,
    bucket_midpoint DOUBLE PRECISION,
    interval_count INTEGER,
    cumulative_share DOUBLE PRECISION,
    cumulative_percentile DOUBLE PRECISION,
    price_impact_bps DOUBLE PRECISION,
    price_impact_bps_abs DOUBLE PRECISION,
    price_impact_bps_inv DOUBLE PRECISION,
    percentile_10 DOUBLE PRECISION,
    percentile_25 DOUBLE PRECISION,
    percentile_50 DOUBLE PRECISION,
    percentile_75 DOUBLE PRECISION,
    percentile_90 DOUBLE PRECISION,
    total_intervals BIGINT,
    total_intervals_filtered BIGINT,
    total_intervals_filtered_pct INTEGER,
    total_swaps BIGINT,
    earliest_interval TIMESTAMPTZ,
    latest_interval TIMESTAMPTZ,
    protocol TEXT,
    token_pair TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_pressure_interval INTERVAL;
    v_lookback_interval INTERVAL;
    v_pool_address TEXT;
    -- Pre-fetched pool state
    v_query_id BIGINT;
    v_current_tick INTEGER;
    v_sqrt_price_x64 NUMERIC(40,0);
    v_mint_decimals_0 SMALLINT;
    v_mint_decimals_1 SMALLINT;
    v_dec_adj DOUBLE PRECISION;
    v_sqrt_cur DOUBLE PRECISION;
    v_cur_price DOUBLE PRECISION;
    -- Active-tick data for t0-sell (positive midpoints)
    v_t0_active_liq DOUBLE PRECISION;
    v_t0_active_cap DOUBLE PRECISION;
    v_pow_dec_0 DOUBLE PRECISION;
    -- Active-tick data for t1-sell (negative midpoints → buying t0)
    v_t1_active_liq DOUBLE PRECISION;
    v_t1_active_cap DOUBLE PRECISION;
    v_pow_dec_1 DOUBLE PRECISION;
    -- Effective sides when inverted
    v_sell_side TEXT;   -- side for positive midpoints
    v_buy_side TEXT;    -- side for negative midpoints (converted)
BEGIN
    BEGIN
        v_pressure_interval := p_pressure_interval::INTERVAL;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Invalid pressure interval: %', p_pressure_interval;
    END;

    BEGIN
        v_lookback_interval := p_lookback::INTERVAL;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Invalid lookback: %', p_lookback;
    END;

    IF p_buckets IS NULL OR p_buckets < 1 OR p_buckets > 1000 THEN
        RAISE EXCEPTION 'Invalid buckets: %', p_buckets;
    END IF;

    IF p_pressure_filter IS NOT NULL
       AND p_pressure_filter NOT IN ('buy_only', 'sell_only') THEN
        RAISE EXCEPTION 'Invalid pressure_filter: %', p_pressure_filter;
    END IF;

    -- When inverted the token sides swap.
    IF p_invert THEN
        v_sell_side := 't1';
        v_buy_side  := 't0';
    ELSE
        v_sell_side := 't0';
        v_buy_side  := 't1';
    END IF;

    -- ── Pool address (time-filtered) ─────────────────────────────────
    SELECT DISTINCT e.pool_address INTO v_pool_address
    FROM dexes.cagg_events_5s e
    WHERE e.protocol = p_protocol
      AND e.token_pair = p_token_pair
      AND e.activity_category = 'swap'
      AND e.bucket_time >= NOW() - v_lookback_interval
    LIMIT 1;

    -- ── Pre-fetch pool state ─────────────────────────────────────────
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
                v_pow_dec_0 := POWER(10, v_mint_decimals_0);
                v_pow_dec_1 := POWER(10, v_mint_decimals_1);

                -- Active-tick capacity for t0-side sells
                SELECT COALESCE(t.token0_sold_cumul, 0), t.liquidity_balance
                INTO v_t0_active_cap, v_t0_active_liq
                FROM dexes.src_acct_tickarray_tokendist_latest t
                WHERE t.pool_address = v_pool_address
                  AND t.tick_lower <= v_current_tick
                  AND t.tick_upper > v_current_tick
                LIMIT 1;

                -- Active-tick capacity for t1-side sells (buying pressure path)
                SELECT COALESCE(t.token1_sold_cumul, 0), t.liquidity_balance
                INTO v_t1_active_cap, v_t1_active_liq
                FROM dexes.src_acct_tickarray_tokendist_latest t
                WHERE t.pool_address = v_pool_address
                  AND t.tick_lower <= v_current_tick
                  AND t.tick_upper > v_current_tick
                LIMIT 1;
            END IF;
        END IF;
    END IF;

    -- ── Main query ──────────────────────────────────────────────────
    RETURN QUERY
    WITH swap_events_total AS (
        SELECT SUM(e.event_count)::BIGINT AS total_swap_events
        FROM dexes.cagg_events_5s e
        WHERE e.protocol = p_protocol
          AND e.token_pair = p_token_pair
          AND e.activity_category = 'swap'
          AND e.bucket_time >= NOW() - v_lookback_interval
    ),
    all_intervals AS (
        SELECT COUNT(*)::BIGINT AS total_intervals_unfiltered
        FROM (
            SELECT time_bucket(v_pressure_interval, e.bucket_time) AS interval_time
            FROM dexes.cagg_events_5s e
            WHERE e.protocol = p_protocol
              AND e.token_pair = p_token_pair
              AND e.activity_category = 'swap'
              AND e.bucket_time >= NOW() - v_lookback_interval
            GROUP BY time_bucket(v_pressure_interval, e.bucket_time), e.pool_address
            HAVING SUM(e.event_count) > 0
        ) intervals
    ),
    pressure_intervals AS (
        SELECT
            time_bucket(v_pressure_interval, e.bucket_time) AS interval_time,
            e.pool_address,
            MAX(e.protocol) AS protocol,
            MAX(e.token_pair) AS token_pair,
            SUM(e.amount0_in) - SUM(e.amount0_out) AS net_sell_pressure_t0
        FROM dexes.cagg_events_5s e
        WHERE e.protocol = p_protocol
          AND e.token_pair = p_token_pair
          AND e.activity_category = 'swap'
          AND e.bucket_time >= NOW() - v_lookback_interval
        GROUP BY time_bucket(v_pressure_interval, e.bucket_time), e.pool_address
        HAVING SUM(e.event_count) > 0
            AND (
                p_pressure_filter IS NULL
                OR (p_pressure_filter = 'buy_only'  AND (SUM(e.amount0_in) - SUM(e.amount0_out)) < 0)
                OR (p_pressure_filter = 'sell_only' AND (SUM(e.amount0_in) - SUM(e.amount0_out)) > 0)
            )
    ),
    sample_stats AS (
        SELECT
            MAX(ai.total_intervals_unfiltered)::BIGINT AS total_intervals,
            COUNT(*)::BIGINT AS total_intervals_filtered,
            CASE
                WHEN MAX(ai.total_intervals_unfiltered) > 0
                THEN ROUND((COUNT(*)::NUMERIC / MAX(ai.total_intervals_unfiltered)::NUMERIC) * 100, 0)::INTEGER
                ELSE 0
            END AS total_intervals_filtered_pct,
            COALESCE(MAX(sev.total_swap_events), 0)::BIGINT AS total_swaps,
            MIN(pi.interval_time) AS earliest_interval,
            MAX(pi.interval_time) AS latest_interval,
            MIN(pi.net_sell_pressure_t0) AS min_pressure,
            MAX(pi.net_sell_pressure_t0) AS max_pressure,
            PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY pi.net_sell_pressure_t0) AS p10,
            PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY pi.net_sell_pressure_t0) AS p25,
            PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY pi.net_sell_pressure_t0) AS p50,
            PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY pi.net_sell_pressure_t0) AS p75,
            PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY pi.net_sell_pressure_t0) AS p90,
            MAX(pi.protocol) AS protocol,
            MAX(pi.token_pair) AS token_pair
        FROM pressure_intervals pi
        CROSS JOIN swap_events_total sev
        CROSS JOIN all_intervals ai
    ),
    bucket_ranges AS (
        SELECT
            CASE
                WHEN ss.min_pressure = ss.max_pressure THEN CEIL(p_buckets::NUMERIC / 2)::INTEGER
                ELSE LEAST(WIDTH_BUCKET(pi.net_sell_pressure_t0, ss.min_pressure, ss.max_pressure, p_buckets), p_buckets)
            END AS bucket_num
        FROM pressure_intervals pi
        CROSS JOIN sample_stats ss
    ),
    all_buckets AS (
        SELECT generate_series(1, p_buckets) AS bucket_num
    ),
    bucket_counts AS (
        SELECT br.bucket_num, COUNT(*)::INTEGER AS interval_count
        FROM bucket_ranges br
        WHERE br.bucket_num BETWEEN 1 AND p_buckets
        GROUP BY br.bucket_num
    ),
    bucket_aggregates AS (
        SELECT
            ab.bucket_num,
            ss.protocol,
            ss.token_pair,
            CASE
                WHEN ss.min_pressure = ss.max_pressure THEN
                    ss.min_pressure - COALESCE(NULLIF(ABS(ss.min_pressure) * 0.01, 0), 1) * 0.5
                        + (ab.bucket_num - 1) * COALESCE(NULLIF(ABS(ss.min_pressure) * 0.01, 0), 1) / p_buckets
                ELSE
                    ss.min_pressure + (ab.bucket_num - 1) * (ss.max_pressure - ss.min_pressure) / p_buckets
            END AS bucket_min,
            CASE
                WHEN ss.min_pressure = ss.max_pressure THEN
                    ss.min_pressure - COALESCE(NULLIF(ABS(ss.min_pressure) * 0.01, 0), 1) * 0.5
                        + ab.bucket_num * COALESCE(NULLIF(ABS(ss.min_pressure) * 0.01, 0), 1) / p_buckets
                ELSE
                    ss.min_pressure + ab.bucket_num * (ss.max_pressure - ss.min_pressure) / p_buckets
            END AS bucket_max,
            COALESCE(bc.interval_count, 0)::INTEGER AS interval_count,
            SUM(COALESCE(bc.interval_count, 0)) OVER (ORDER BY ab.bucket_num) AS cumulative_count
        FROM all_buckets ab
        CROSS JOIN sample_stats ss
        LEFT JOIN bucket_counts bc ON ab.bucket_num = bc.bucket_num
        WHERE ss.total_intervals_filtered > 0
    ),
    distribution_with_share AS (
        SELECT
            ba.bucket_num,
            ba.bucket_min,
            ba.bucket_max,
            (ba.bucket_min + ba.bucket_max) / 2.0 AS bucket_midpoint,
            ba.interval_count,
            CASE
                WHEN ss.total_intervals_filtered > 0
                THEN (ba.cumulative_count::DOUBLE PRECISION / ss.total_intervals_filtered::DOUBLE PRECISION) * 100.0
                ELSE 0
            END AS cumulative_share,
            CASE
                WHEN ss.total_intervals_filtered > 0
                THEN (ba.cumulative_count::DOUBLE PRECISION / ss.total_intervals_filtered::DOUBLE PRECISION) * 100.0
                ELSE 0
            END AS cumulative_percentile,
            ss.total_intervals,
            ss.total_intervals_filtered,
            ss.total_intervals_filtered_pct,
            ss.total_swaps,
            ss.earliest_interval,
            ss.latest_interval,
            ss.p10, ss.p25, ss.p50, ss.p75, ss.p90,
            ba.protocol,
            ba.token_pair
        FROM bucket_aggregates ba
        CROSS JOIN sample_stats ss
    ),
    distribution_with_impact AS (
        SELECT
            dws.*,
            CASE
                -- ── Positive midpoint: selling t0 (or inverted equivalent) ──
                -- ① Fast: inline CLMM within active tick
                WHEN dws.bucket_midpoint > 0
                     AND v_cur_price > 0
                     AND COALESCE(v_t0_active_liq, 0) > 0
                     AND dws.bucket_midpoint <= COALESCE(v_t0_active_cap, 0)
                THEN
                    CASE WHEN v_sell_side = 't0' THEN
                        (POWER(1.0 / (1.0 / v_sqrt_cur + dws.bucket_midpoint * v_pow_dec_0 / v_t0_active_liq), 2)
                         * v_dec_adj - v_cur_price) / v_cur_price * 10000
                    ELSE
                        (POWER(v_sqrt_cur + dws.bucket_midpoint * v_pow_dec_1 / v_t1_active_liq, 2)
                         * v_dec_adj - v_cur_price) / v_cur_price * 10000
                    END
                -- ② Slow: cross-tick positive, non-empty only
                WHEN dws.bucket_midpoint > 0
                     AND v_pool_address IS NOT NULL
                     AND dws.interval_count > 0
                THEN
                    dexes.impact_bps_from_qsell_latest(v_pool_address, v_sell_side, dws.bucket_midpoint)

                -- ── Negative midpoint: buying t0 = selling t1 ───────────────
                -- ③ Fast: inline CLMM within active tick (t1 side)
                WHEN dws.bucket_midpoint < 0
                     AND v_cur_price > 0
                     AND COALESCE(v_t1_active_liq, 0) > 0
                     AND (ABS(dws.bucket_midpoint) * v_cur_price) <= COALESCE(v_t1_active_cap, 0)
                THEN
                    CASE WHEN v_buy_side = 't1' THEN
                        (POWER(v_sqrt_cur + ABS(dws.bucket_midpoint) * v_cur_price * v_pow_dec_1 / v_t1_active_liq, 2)
                         * v_dec_adj - v_cur_price) / v_cur_price * 10000
                    ELSE
                        (POWER(1.0 / (1.0 / v_sqrt_cur + ABS(dws.bucket_midpoint) * v_cur_price * v_pow_dec_0 / v_t0_active_liq), 2)
                         * v_dec_adj - v_cur_price) / v_cur_price * 10000
                    END
                -- ④ Slow: cross-tick negative, non-empty only
                WHEN dws.bucket_midpoint < 0
                     AND v_pool_address IS NOT NULL
                     AND v_cur_price > 0
                     AND dws.interval_count > 0
                THEN
                    dexes.impact_bps_from_qsell_latest(
                        v_pool_address, v_buy_side, ABS(dws.bucket_midpoint) * v_cur_price
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
        dwi.interval_count,
        ROUND(dwi.cumulative_share::NUMERIC, 4)::DOUBLE PRECISION,
        ROUND(dwi.cumulative_percentile::NUMERIC, 2)::DOUBLE PRECISION,
        ROUND(dwi.impact_raw::NUMERIC, 4)::DOUBLE PRECISION,
        ROUND(ABS(dwi.impact_raw)::NUMERIC, 4)::DOUBLE PRECISION,
        ROUND((dwi.impact_raw * -1)::NUMERIC, 4)::DOUBLE PRECISION,
        ROUND(dwi.p10::NUMERIC, 2)::DOUBLE PRECISION,
        ROUND(dwi.p25::NUMERIC, 2)::DOUBLE PRECISION,
        ROUND(dwi.p50::NUMERIC, 2)::DOUBLE PRECISION,
        ROUND(dwi.p75::NUMERIC, 2)::DOUBLE PRECISION,
        ROUND(dwi.p90::NUMERIC, 2)::DOUBLE PRECISION,
        dwi.total_intervals,
        dwi.total_intervals_filtered,
        dwi.total_intervals_filtered_pct,
        dwi.total_swaps,
        dwi.earliest_interval,
        dwi.latest_interval,
        dwi.protocol,
        dwi.token_pair
    FROM distribution_with_impact dwi
    ORDER BY dwi.bucket_num;
END;
$$;
