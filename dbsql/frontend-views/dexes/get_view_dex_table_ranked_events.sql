-- =====================================================
-- Ranked Events (optimised pfx edition)
-- =====================================================
-- Key performance fix: rank & LIMIT *before* the balance_at_tx
-- LATERAL JOIN and impact_bps_from_qsell_latest calls, so only
-- p_rows rows (typically 10) hit the expensive paths instead of
-- every swap in the lookback window.
--
-- Maintains full p_invert support via the wrapping SELECT.
-- =====================================================

DROP FUNCTION IF EXISTS dexes.get_view_dex_table_ranked_events(TEXT,TEXT,TEXT,TEXT,TEXT,INTEGER,TEXT,BOOLEAN);
CREATE OR REPLACE FUNCTION dexes.get_view_dex_table_ranked_events(
    p_protocol TEXT,
    p_pair TEXT,
    p_activity_category TEXT DEFAULT 'swap',
    p_sort_asset TEXT DEFAULT 't0',
    p_flow_direction TEXT DEFAULT 'out',
    p_rows INTEGER DEFAULT 100,
    p_lookback TEXT DEFAULT '1 day',
    p_invert BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    tx_time TIMESTAMPTZ,
    signature TEXT,
    block_id BIGINT,
    pool_address TEXT,
    token0_in BIGINT,
    token0_out BIGINT,
    token1_in BIGINT,
    token1_out BIGINT,
    primary_flow BIGINT,
    complement_flow BIGINT,
    primary_flow_reserve_pct_at_tx DOUBLE PRECISION,
    primary_flow_reserve_pct_now DOUBLE PRECISION,
    complement_flow_reserve_pct_at_tx DOUBLE PRECISION,
    complement_flow_reserve_pct_now DOUBLE PRECISION,
    token0_mint TEXT,
    token1_mint TEXT,
    token0_symbol TEXT,
    token1_symbol TEXT,
    token0_balance_at_tx DOUBLE PRECISION,
    token1_balance_at_tx DOUBLE PRECISION,
    token0_balance_now DOUBLE PRECISION,
    token1_balance_now DOUBLE PRECISION,
    token0_in_pct_reserve_at_tx DOUBLE PRECISION,
    token0_out_pct_reserve_at_tx DOUBLE PRECISION,
    token1_in_pct_reserve_at_tx DOUBLE PRECISION,
    token1_out_pct_reserve_at_tx DOUBLE PRECISION,
    token0_in_pct_reserve_now DOUBLE PRECISION,
    token0_out_pct_reserve_now DOUBLE PRECISION,
    token1_in_pct_reserve_now DOUBLE PRECISION,
    token1_out_pct_reserve_now DOUBLE PRECISION,
    primary_flow_impact_bps_at_tx DOUBLE PRECISION,
    primary_flow_impact_bps_now DOUBLE PRECISION,
    activity_type_detail TEXT,
    platform TEXT,
    data_quality TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_activity_type_filter TEXT;
    v_lookback_interval INTERVAL;
    v_sql TEXT;
    v_swap_amount_in_expr TEXT;
    v_swap_amount_out_expr TEXT;
    v_liq_amount0_in_expr TEXT;
    v_liq_amount0_out_expr TEXT;
    v_liq_amount1_in_expr TEXT;
    v_liq_amount1_out_expr TEXT;
    v_has_swap_amount_in_num BOOLEAN;
    v_has_swap_amount_out_num BOOLEAN;
    v_has_liq_amount0_in_num BOOLEAN;
    v_has_liq_amount0_out_num BOOLEAN;
    v_has_liq_amount1_in_num BOOLEAN;
    v_has_liq_amount1_out_num BOOLEAN;
BEGIN
    BEGIN
        v_lookback_interval := p_lookback::INTERVAL;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Invalid lookback: %', p_lookback;
    END;

    IF p_sort_asset NOT IN ('t0', 't1') THEN
        RAISE EXCEPTION 'Invalid sort_asset: %', p_sort_asset;
    END IF;
    IF p_flow_direction NOT IN ('in', 'out') THEN
        RAISE EXCEPTION 'Invalid flow_direction: %', p_flow_direction;
    END IF;

    v_activity_type_filter := CASE LOWER(p_activity_category)
        WHEN 'swap' THEN 'swap'
        WHEN 'lp'   THEN 'liquidity_increase,liquidity_decrease'
        ELSE NULL
    END;
    IF v_activity_type_filter IS NULL THEN
        RAISE EXCEPTION 'Invalid activity_category: %', p_activity_category;
    END IF;

    -- Prefer typed numeric columns when available.
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='dexes' AND table_name='src_tx_events' AND column_name='swap_amount_in_num')  INTO v_has_swap_amount_in_num;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='dexes' AND table_name='src_tx_events' AND column_name='swap_amount_out_num') INTO v_has_swap_amount_out_num;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='dexes' AND table_name='src_tx_events' AND column_name='liq_amount0_in_num')  INTO v_has_liq_amount0_in_num;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='dexes' AND table_name='src_tx_events' AND column_name='liq_amount0_out_num') INTO v_has_liq_amount0_out_num;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='dexes' AND table_name='src_tx_events' AND column_name='liq_amount1_in_num')  INTO v_has_liq_amount1_in_num;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='dexes' AND table_name='src_tx_events' AND column_name='liq_amount1_out_num') INTO v_has_liq_amount1_out_num;

    v_swap_amount_in_expr := CASE WHEN v_has_swap_amount_in_num
        THEN 'COALESCE(s.swap_amount_in_num, CAST(NULLIF(REGEXP_REPLACE(s.swap_amount_in, ''[^0-9.-]'', '''', ''g''), '''') AS NUMERIC), 0)'
        ELSE 'COALESCE(CAST(NULLIF(REGEXP_REPLACE(s.swap_amount_in, ''[^0-9.-]'', '''', ''g''), '''') AS NUMERIC), 0)' END;
    v_swap_amount_out_expr := CASE WHEN v_has_swap_amount_out_num
        THEN 'COALESCE(s.swap_amount_out_num, CAST(NULLIF(REGEXP_REPLACE(s.swap_amount_out, ''[^0-9.-]'', '''', ''g''), '''') AS NUMERIC), 0)'
        ELSE 'COALESCE(CAST(NULLIF(REGEXP_REPLACE(s.swap_amount_out, ''[^0-9.-]'', '''', ''g''), '''') AS NUMERIC), 0)' END;
    v_liq_amount0_in_expr := CASE WHEN v_has_liq_amount0_in_num
        THEN 'COALESCE(s.liq_amount0_in_num, CAST(NULLIF(REGEXP_REPLACE(s.liq_amount0_in, ''[^0-9.-]'', '''', ''g''), '''') AS NUMERIC), 0)'
        ELSE 'COALESCE(CAST(NULLIF(REGEXP_REPLACE(s.liq_amount0_in, ''[^0-9.-]'', '''', ''g''), '''') AS NUMERIC), 0)' END;
    v_liq_amount0_out_expr := CASE WHEN v_has_liq_amount0_out_num
        THEN 'COALESCE(s.liq_amount0_out_num, CAST(NULLIF(REGEXP_REPLACE(s.liq_amount0_out, ''[^0-9.-]'', '''', ''g''), '''') AS NUMERIC), 0)'
        ELSE 'COALESCE(CAST(NULLIF(REGEXP_REPLACE(s.liq_amount0_out, ''[^0-9.-]'', '''', ''g''), '''') AS NUMERIC), 0)' END;
    v_liq_amount1_in_expr := CASE WHEN v_has_liq_amount1_in_num
        THEN 'COALESCE(s.liq_amount1_in_num, CAST(NULLIF(REGEXP_REPLACE(s.liq_amount1_in, ''[^0-9.-]'', '''', ''g''), '''') AS NUMERIC), 0)'
        ELSE 'COALESCE(CAST(NULLIF(REGEXP_REPLACE(s.liq_amount1_in, ''[^0-9.-]'', '''', ''g''), '''') AS NUMERIC), 0)' END;
    v_liq_amount1_out_expr := CASE WHEN v_has_liq_amount1_out_num
        THEN 'COALESCE(s.liq_amount1_out_num, CAST(NULLIF(REGEXP_REPLACE(s.liq_amount1_out, ''[^0-9.-]'', '''', ''g''), '''') AS NUMERIC), 0)'
        ELSE 'COALESCE(CAST(NULLIF(REGEXP_REPLACE(s.liq_amount1_out, ''[^0-9.-]'', '''', ''g''), '''') AS NUMERIC), 0)' END;

    -- ─────────────────────────────────────────────────────────────────
    -- Build dynamic SQL.
    -- CRITICAL CHANGE: rank + LIMIT first, THEN balance/impact lookups.
    -- ─────────────────────────────────────────────────────────────────
    v_sql := REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(format($query$
        WITH swap_data AS (
            SELECT
                s.time,
                s.signature AS trans_id,
                s.slot AS block_id,
                s.pool_address,
                s.event_type AS activity_type,
                s.program_id AS platform,
                s.token_pair,
                s.c_swap_est_impact_bps,
                ptr.token0_address AS token0_mint,
                ptr.token1_address AS token1_mint,
                ptr.token0_symbol,
                ptr.token1_symbol,
                CASE WHEN s.event_type = 'swap' THEN
                    CASE WHEN s.swap_token_in = ptr.token0_address THEN {{SWAP_AMOUNT_IN_EXPR}} ELSE 0 END
                ELSE {{LIQ_AMOUNT0_IN_EXPR}} END AS token0_in_raw,
                CASE WHEN s.event_type = 'swap' THEN
                    CASE WHEN s.swap_token_out = ptr.token0_address THEN {{SWAP_AMOUNT_OUT_EXPR}} ELSE 0 END
                ELSE {{LIQ_AMOUNT0_OUT_EXPR}} END AS token0_out_raw,
                CASE WHEN s.event_type = 'swap' THEN
                    CASE WHEN s.swap_token_in = ptr.token1_address THEN {{SWAP_AMOUNT_IN_EXPR}} ELSE 0 END
                ELSE {{LIQ_AMOUNT1_IN_EXPR}} END AS token1_in_raw,
                CASE WHEN s.event_type = 'swap' THEN
                    CASE WHEN s.swap_token_out = ptr.token1_address THEN {{SWAP_AMOUNT_OUT_EXPR}} ELSE 0 END
                ELSE {{LIQ_AMOUNT1_OUT_EXPR}} END AS token1_out_raw,
                COALESCE(s.env_token0_decimals, ptr.token0_decimals, 6) AS token0_decimals,
                COALESCE(s.env_token1_decimals, ptr.token1_decimals, 6) AS token1_decimals
            FROM dexes.src_tx_events s
            INNER JOIN dexes.pool_tokens_reference ptr ON s.pool_address = ptr.pool_address
            WHERE s.time >= NOW() - %L::INTERVAL
                AND s.protocol = %L
                AND s.event_type = ANY(string_to_array(%L, ','))
                AND s.token_pair = %L
        ),
        adjusted_swaps AS (
            SELECT
                time, trans_id, block_id, pool_address, activity_type, platform,
                token_pair, c_swap_est_impact_bps,
                token0_mint, token1_mint, token0_symbol, token1_symbol,
                FLOOR(token0_in_raw  / POWER(10, COALESCE(token0_decimals, 0)))::BIGINT AS token0_in,
                FLOOR(token0_out_raw / POWER(10, COALESCE(token0_decimals, 0)))::BIGINT AS token0_out,
                FLOOR(token1_in_raw  / POWER(10, COALESCE(token1_decimals, 0)))::BIGINT AS token1_in,
                FLOOR(token1_out_raw / POWER(10, COALESCE(token1_decimals, 0)))::BIGINT AS token1_out
            FROM swap_data
        ),
        -- ┌────────────────────────────────────────────────────────┐
        -- │ Rank FIRST, limit to p_rows — before any LATERAL JOIN │
        -- └────────────────────────────────────────────────────────┘
        ranked_limited AS (
            SELECT a.*,
                   ROW_NUMBER() OVER (
                       ORDER BY
                           CASE
                               WHEN '{{SORT_ASSET}}' = 't0' AND '{{FLOW_DIR}}' = 'in'  THEN a.token0_in
                               WHEN '{{SORT_ASSET}}' = 't0' AND '{{FLOW_DIR}}' = 'out' THEN a.token0_out
                               WHEN '{{SORT_ASSET}}' = 't1' AND '{{FLOW_DIR}}' = 'in'  THEN a.token1_in
                               WHEN '{{SORT_ASSET}}' = 't1' AND '{{FLOW_DIR}}' = 'out' THEN a.token1_out
                               ELSE 0
                           END DESC,
                           a.time DESC
                   ) AS rn
            FROM adjusted_swaps a
            WHERE CASE
                WHEN '{{SORT_ASSET}}' = 't0' AND '{{FLOW_DIR}}' = 'in'  THEN a.token0_in  > 0
                WHEN '{{SORT_ASSET}}' = 't0' AND '{{FLOW_DIR}}' = 'out' THEN a.token0_out > 0
                WHEN '{{SORT_ASSET}}' = 't1' AND '{{FLOW_DIR}}' = 'in'  THEN a.token1_in  > 0
                WHEN '{{SORT_ASSET}}' = 't1' AND '{{FLOW_DIR}}' = 'out' THEN a.token1_out > 0
                ELSE false
            END
        ),
        top_rows AS (
            SELECT * FROM ranked_limited WHERE rn <= %s
        ),
        -- Balance lookup now touches only p_rows rows instead of all swaps
        balance_at_tx AS (
            SELECT
                t.trans_id,
                b.token0_balance_at_tx,
                b.token1_balance_at_tx
            FROM top_rows t
            LEFT JOIN LATERAL (
                SELECT
                    token_0_value::DOUBLE PRECISION AS token0_balance_at_tx,
                    token_1_value::DOUBLE PRECISION AS token1_balance_at_tx
                FROM dexes.cagg_vaults_5s
                WHERE bucket_time <= t.time
                    AND pool_address = t.pool_address
                ORDER BY bucket_time DESC
                LIMIT 1
            ) b ON true
        ),
        current_balance AS (
            SELECT DISTINCT ON (pool_address)
                pool_address,
                token_0_value::DOUBLE PRECISION AS token0_balance_now,
                token_1_value::DOUBLE PRECISION AS token1_balance_now
            FROM dexes.cagg_vaults_5s
            WHERE protocol = %L
                AND token_pair = %L
            ORDER BY pool_address, bucket_time DESC
        )
        SELECT
            t.time AS tx_time,
            t.trans_id AS signature,
            t.block_id,
            t.pool_address,
            t.token0_in, t.token0_out, t.token1_in, t.token1_out,

            -- Primary flow
            CASE
                WHEN '{{SORT_ASSET}}' = 't0' AND '{{FLOW_DIR}}' = 'in'  THEN t.token0_in
                WHEN '{{SORT_ASSET}}' = 't0' AND '{{FLOW_DIR}}' = 'out' THEN t.token0_out
                WHEN '{{SORT_ASSET}}' = 't1' AND '{{FLOW_DIR}}' = 'in'  THEN t.token1_in
                WHEN '{{SORT_ASSET}}' = 't1' AND '{{FLOW_DIR}}' = 'out' THEN t.token1_out
                ELSE NULL
            END AS primary_flow,
            -- Complement flow
            CASE
                WHEN t.activity_type != 'swap' THEN NULL
                WHEN '{{SORT_ASSET}}' = 't0' AND '{{FLOW_DIR}}' = 'in'  THEN t.token1_out
                WHEN '{{SORT_ASSET}}' = 't0' AND '{{FLOW_DIR}}' = 'out' THEN t.token1_in
                WHEN '{{SORT_ASSET}}' = 't1' AND '{{FLOW_DIR}}' = 'in'  THEN t.token0_out
                WHEN '{{SORT_ASSET}}' = 't1' AND '{{FLOW_DIR}}' = 'out' THEN t.token0_in
                ELSE NULL
            END AS complement_flow,

            -- Primary flow reserve pct at tx
            CASE
                WHEN '{{SORT_ASSET}}' = 't0' AND '{{FLOW_DIR}}' = 'in'  THEN CASE WHEN bal.token0_balance_at_tx > 0 THEN ROUND((t.token0_in  / bal.token0_balance_at_tx * 100)::NUMERIC, 4)::DOUBLE PRECISION END
                WHEN '{{SORT_ASSET}}' = 't0' AND '{{FLOW_DIR}}' = 'out' THEN CASE WHEN bal.token0_balance_at_tx > 0 THEN ROUND((t.token0_out / bal.token0_balance_at_tx * 100)::NUMERIC, 4)::DOUBLE PRECISION END
                WHEN '{{SORT_ASSET}}' = 't1' AND '{{FLOW_DIR}}' = 'in'  THEN CASE WHEN bal.token1_balance_at_tx > 0 THEN ROUND((t.token1_in  / bal.token1_balance_at_tx * 100)::NUMERIC, 4)::DOUBLE PRECISION END
                WHEN '{{SORT_ASSET}}' = 't1' AND '{{FLOW_DIR}}' = 'out' THEN CASE WHEN bal.token1_balance_at_tx > 0 THEN ROUND((t.token1_out / bal.token1_balance_at_tx * 100)::NUMERIC, 4)::DOUBLE PRECISION END
                ELSE NULL
            END AS primary_flow_reserve_pct_at_tx,
            -- Primary flow reserve pct now
            CASE
                WHEN '{{SORT_ASSET}}' = 't0' AND '{{FLOW_DIR}}' = 'in'  THEN CASE WHEN cb.token0_balance_now > 0 THEN ROUND((t.token0_in  / cb.token0_balance_now * 100)::NUMERIC, 4)::DOUBLE PRECISION END
                WHEN '{{SORT_ASSET}}' = 't0' AND '{{FLOW_DIR}}' = 'out' THEN CASE WHEN cb.token0_balance_now > 0 THEN ROUND((t.token0_out / cb.token0_balance_now * 100)::NUMERIC, 4)::DOUBLE PRECISION END
                WHEN '{{SORT_ASSET}}' = 't1' AND '{{FLOW_DIR}}' = 'in'  THEN CASE WHEN cb.token1_balance_now > 0 THEN ROUND((t.token1_in  / cb.token1_balance_now * 100)::NUMERIC, 4)::DOUBLE PRECISION END
                WHEN '{{SORT_ASSET}}' = 't1' AND '{{FLOW_DIR}}' = 'out' THEN CASE WHEN cb.token1_balance_now > 0 THEN ROUND((t.token1_out / cb.token1_balance_now * 100)::NUMERIC, 4)::DOUBLE PRECISION END
                ELSE NULL
            END AS primary_flow_reserve_pct_now,
            -- Complement flow reserve pct at tx
            CASE
                WHEN t.activity_type != 'swap' THEN NULL
                WHEN '{{SORT_ASSET}}' = 't0' AND '{{FLOW_DIR}}' = 'in'  THEN CASE WHEN bal.token1_balance_at_tx > 0 THEN ROUND((t.token1_out / bal.token1_balance_at_tx * 100)::NUMERIC, 4)::DOUBLE PRECISION END
                WHEN '{{SORT_ASSET}}' = 't0' AND '{{FLOW_DIR}}' = 'out' THEN CASE WHEN bal.token1_balance_at_tx > 0 THEN ROUND((t.token1_in  / bal.token1_balance_at_tx * 100)::NUMERIC, 4)::DOUBLE PRECISION END
                WHEN '{{SORT_ASSET}}' = 't1' AND '{{FLOW_DIR}}' = 'in'  THEN CASE WHEN bal.token0_balance_at_tx > 0 THEN ROUND((t.token0_out / bal.token0_balance_at_tx * 100)::NUMERIC, 4)::DOUBLE PRECISION END
                WHEN '{{SORT_ASSET}}' = 't1' AND '{{FLOW_DIR}}' = 'out' THEN CASE WHEN bal.token0_balance_at_tx > 0 THEN ROUND((t.token0_in  / bal.token0_balance_at_tx * 100)::NUMERIC, 4)::DOUBLE PRECISION END
                ELSE NULL
            END AS complement_flow_reserve_pct_at_tx,
            -- Complement flow reserve pct now
            CASE
                WHEN t.activity_type != 'swap' THEN NULL
                WHEN '{{SORT_ASSET}}' = 't0' AND '{{FLOW_DIR}}' = 'in'  THEN CASE WHEN cb.token1_balance_now > 0 THEN ROUND((t.token1_out / cb.token1_balance_now * 100)::NUMERIC, 4)::DOUBLE PRECISION END
                WHEN '{{SORT_ASSET}}' = 't0' AND '{{FLOW_DIR}}' = 'out' THEN CASE WHEN cb.token1_balance_now > 0 THEN ROUND((t.token1_in  / cb.token1_balance_now * 100)::NUMERIC, 4)::DOUBLE PRECISION END
                WHEN '{{SORT_ASSET}}' = 't1' AND '{{FLOW_DIR}}' = 'in'  THEN CASE WHEN cb.token0_balance_now > 0 THEN ROUND((t.token0_out / cb.token0_balance_now * 100)::NUMERIC, 4)::DOUBLE PRECISION END
                WHEN '{{SORT_ASSET}}' = 't1' AND '{{FLOW_DIR}}' = 'out' THEN CASE WHEN cb.token0_balance_now > 0 THEN ROUND((t.token0_in  / cb.token0_balance_now * 100)::NUMERIC, 4)::DOUBLE PRECISION END
                ELSE NULL
            END AS complement_flow_reserve_pct_now,

            t.token0_mint, t.token1_mint, t.token0_symbol, t.token1_symbol,
            bal.token0_balance_at_tx, bal.token1_balance_at_tx,
            cb.token0_balance_now, cb.token1_balance_now,

            -- Individual reserve pct columns at tx
            CASE WHEN bal.token0_balance_at_tx > 0 THEN ROUND((t.token0_in  / bal.token0_balance_at_tx * 100)::NUMERIC, 4)::DOUBLE PRECISION END AS token0_in_pct_reserve_at_tx,
            CASE WHEN bal.token0_balance_at_tx > 0 THEN ROUND((t.token0_out / bal.token0_balance_at_tx * 100)::NUMERIC, 4)::DOUBLE PRECISION END AS token0_out_pct_reserve_at_tx,
            CASE WHEN bal.token1_balance_at_tx > 0 THEN ROUND((t.token1_in  / bal.token1_balance_at_tx * 100)::NUMERIC, 4)::DOUBLE PRECISION END AS token1_in_pct_reserve_at_tx,
            CASE WHEN bal.token1_balance_at_tx > 0 THEN ROUND((t.token1_out / bal.token1_balance_at_tx * 100)::NUMERIC, 4)::DOUBLE PRECISION END AS token1_out_pct_reserve_at_tx,
            -- Individual reserve pct columns now
            CASE WHEN cb.token0_balance_now > 0 THEN ROUND((t.token0_in  / cb.token0_balance_now * 100)::NUMERIC, 4)::DOUBLE PRECISION END AS token0_in_pct_reserve_now,
            CASE WHEN cb.token0_balance_now > 0 THEN ROUND((t.token0_out / cb.token0_balance_now * 100)::NUMERIC, 4)::DOUBLE PRECISION END AS token0_out_pct_reserve_now,
            CASE WHEN cb.token1_balance_now > 0 THEN ROUND((t.token1_in  / cb.token1_balance_now * 100)::NUMERIC, 4)::DOUBLE PRECISION END AS token1_in_pct_reserve_now,
            CASE WHEN cb.token1_balance_now > 0 THEN ROUND((t.token1_out / cb.token1_balance_now * 100)::NUMERIC, 4)::DOUBLE PRECISION END AS token1_out_pct_reserve_now,

            -- Impact BPS at tx (pre-calculated)
            CASE WHEN t.activity_type = 'swap'
                 THEN ROUND(COALESCE(t.c_swap_est_impact_bps, 0)::NUMERIC, 4)::DOUBLE PRECISION
                 ELSE NULL END AS primary_flow_impact_bps_at_tx,
            -- Impact BPS now (live calculation, only p_rows calls)
            CASE
                WHEN t.activity_type != 'swap' THEN NULL
                WHEN '{{FLOW_DIR}}' = 'out' THEN
                    ROUND(dexes.impact_bps_from_qsell_latest(
                        t.pool_address, '{{SORT_ASSET}}',
                        ABS(CASE WHEN '{{SORT_ASSET}}' = 't0' THEN t.token0_out ELSE t.token1_out END)::DOUBLE PRECISION
                    )::NUMERIC, 4)::DOUBLE PRECISION
                WHEN '{{FLOW_DIR}}' = 'in' THEN
                    ROUND(dexes.impact_bps_from_qsell_latest(
                        t.pool_address,
                        CASE WHEN '{{SORT_ASSET}}' = 't0' THEN 't1' ELSE 't0' END,
                        ABS(CASE WHEN '{{SORT_ASSET}}' = 't0' THEN t.token1_out ELSE t.token0_out END)::DOUBLE PRECISION
                    )::NUMERIC, 4)::DOUBLE PRECISION
                ELSE NULL
            END AS primary_flow_impact_bps_now,

            t.activity_type AS activity_type_detail,
            t.platform,
            CASE
                WHEN bal.token0_balance_at_tx IS NULL OR bal.token1_balance_at_tx IS NULL THEN 'missing_balance_context'
                WHEN cb.token0_balance_now IS NULL OR cb.token1_balance_now IS NULL THEN 'missing_current_balance'
                ELSE 'complete'
            END AS data_quality

        FROM top_rows t
        LEFT JOIN balance_at_tx bal ON t.trans_id = bal.trans_id
        LEFT JOIN current_balance cb  ON t.pool_address = cb.pool_address
        ORDER BY t.rn
    $query$,
        v_lookback_interval,
        p_protocol,
        v_activity_type_filter,
        p_pair,
        p_rows,
        p_protocol,
        p_pair
    ), '{{SORT_ASSET}}', p_sort_asset), '{{FLOW_DIR}}', p_flow_direction),
    '{{SWAP_AMOUNT_IN_EXPR}}',  v_swap_amount_in_expr),
    '{{SWAP_AMOUNT_OUT_EXPR}}', v_swap_amount_out_expr),
    '{{LIQ_AMOUNT0_IN_EXPR}}',  v_liq_amount0_in_expr),
    '{{LIQ_AMOUNT0_OUT_EXPR}}', v_liq_amount0_out_expr),
    '{{LIQ_AMOUNT1_IN_EXPR}}',  v_liq_amount1_in_expr),
    '{{LIQ_AMOUNT1_OUT_EXPR}}', v_liq_amount1_out_expr);

    IF p_invert THEN
        RETURN QUERY EXECUTE format($wrap$
            SELECT
                r.tx_time, r.signature, r.block_id, r.pool_address,
                r.token1_in AS token0_in, r.token1_out AS token0_out,
                r.token0_in AS token1_in, r.token0_out AS token1_out,
                r.primary_flow, r.complement_flow,
                r.primary_flow_reserve_pct_at_tx, r.primary_flow_reserve_pct_now,
                r.complement_flow_reserve_pct_at_tx, r.complement_flow_reserve_pct_now,
                r.token1_mint AS token0_mint, r.token0_mint AS token1_mint,
                r.token1_symbol AS token0_symbol, r.token0_symbol AS token1_symbol,
                r.token1_balance_at_tx AS token0_balance_at_tx,
                r.token0_balance_at_tx AS token1_balance_at_tx,
                r.token1_balance_now AS token0_balance_now,
                r.token0_balance_now AS token1_balance_now,
                r.token1_in_pct_reserve_at_tx  AS token0_in_pct_reserve_at_tx,
                r.token1_out_pct_reserve_at_tx AS token0_out_pct_reserve_at_tx,
                r.token0_in_pct_reserve_at_tx  AS token1_in_pct_reserve_at_tx,
                r.token0_out_pct_reserve_at_tx AS token1_out_pct_reserve_at_tx,
                r.token1_in_pct_reserve_now  AS token0_in_pct_reserve_now,
                r.token1_out_pct_reserve_now AS token0_out_pct_reserve_now,
                r.token0_in_pct_reserve_now  AS token1_in_pct_reserve_now,
                r.token0_out_pct_reserve_now AS token1_out_pct_reserve_now,
                CASE WHEN r.primary_flow_impact_bps_at_tx IS NOT NULL THEN -1 * r.primary_flow_impact_bps_at_tx END,
                CASE WHEN r.primary_flow_impact_bps_now IS NOT NULL   THEN -1 * r.primary_flow_impact_bps_now   END,
                r.activity_type_detail, r.platform, r.data_quality
            FROM (%s) r
        $wrap$, v_sql);
    ELSE
        RETURN QUERY EXECUTE v_sql;
    END IF;
END;
$$;
