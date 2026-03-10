-- get_view_exponent_last: Rewritten to read from mat_exp_last
-- Same signature and output schema as original (exponent/dbsql/views/get_view_exponent_last.sql)
-- Pre-computed per-vault metrics from mat_exp_last eliminate ~30 DISTINCT ON subqueries.
-- Live lookups retained for: SY supply analytics, base token escrow, AMM impact functions,
-- trailing APY calculations, and array columns that span all vaults.

CREATE OR REPLACE FUNCTION exponent.get_view_exponent_last(
    p_mkt1_pt_name TEXT DEFAULT NULL,
    p_mkt2_pt_name TEXT DEFAULT NULL
)
RETURNS TABLE (
    vault_address_mkt1 TEXT,
    vault_address_mkt2 TEXT,
    sy_total_supply NUMERIC,
    sy_total_locked_mkt1 NUMERIC,
    sy_total_locked_pct_mkt1 NUMERIC,
    sy_total_locked_mkt2 NUMERIC,
    sy_total_locked_pct_mkt2 NUMERIC,
    sy_not_in_mkt1_mkt2 NUMERIC,
    sy_not_in_mkt1_mkt2_pct NUMERIC,
    start_ts_mkt1 INTEGER,
    start_datetime_mkt1 TIMESTAMPTZ,
    duration_mkt1 INTEGER,
    end_ts_mkt1 INTEGER,
    end_datetime_mkt1 TIMESTAMPTZ,
    start_ts_mkt2 INTEGER,
    start_datetime_mkt2 TIMESTAMPTZ,
    duration_mkt2 INTEGER,
    end_ts_mkt2 INTEGER,
    end_datetime_mkt2 TIMESTAMPTZ,
    start_ts_chart INTEGER,
    start_datetime_chart TIMESTAMPTZ,
    end_ts_chart INTEGER,
    end_datetime_chart TIMESTAMPTZ,
    now_ts INTEGER,
    now_datetime TIMESTAMPTZ,
    apy_market_mkt1 NUMERIC,
    apy_market_mkt2 NUMERIC,
    pt_base_price_mkt1 NUMERIC,
    pt_base_price_mkt2 NUMERIC,
    pt_sy_price_mkt1 NUMERIC,
    pt_sy_price_mkt2 NUMERIC,
    apy_realized_vault_life_mkt1 NUMERIC,
    apy_realized_vault_life_mkt2 NUMERIC,
    apy_realized_24h NUMERIC,
    apy_realized_7d NUMERIC,
    apy_divergence_wrt_24h_mkt1 NUMERIC,
    apy_divergence_wrt_24h_mkt2 NUMERIC,
    apy_divergence_wrt_7d_mkt1 NUMERIC,
    apy_divergence_wrt_7d_mkt2 NUMERIC,
    discount_rate_mkt1 NUMERIC,
    discount_rate_mkt2 NUMERIC,
    amm_impact_trade_size_pt INTEGER,
    amm_price_impact_trade_size_sy INTEGER,
    amm_price_impact_mkt1_pct NUMERIC,
    amm_price_impact_mkt2_pct NUMERIC,
    amm_yield_impact_mkt1_pct NUMERIC,
    amm_yield_impact_mkt2_pct NUMERIC,
    sy_claims_mkt1 NUMERIC,
    sy_claims_mkt2 NUMERIC,
    pt_yt_supply NUMERIC,
    eusx_locked NUMERIC,
    eusx_collateralization_ratio NUMERIC,
    sy_coll_ratio_mkt1 NUMERIC,
    amm_depth_in_sy_mkt1 NUMERIC,
    amm_pct_of_sy_claims_mkt1 NUMERIC,
    vault_sy_claims_pct_amm_mkt1 NUMERIC,
    amm_share_sy_pct_mkt1 NUMERIC,
    yt_staked_pct_mkt1 NUMERIC,
    sy_coll_ratio_mkt2 NUMERIC,
    amm_depth_in_sy_mkt2 NUMERIC,
    amm_pct_of_sy_claims_mkt2 NUMERIC,
    vault_sy_claims_pct_amm_mkt2 NUMERIC,
    amm_share_sy_pct_mkt2 NUMERIC,
    yt_staked_pct_mkt2 NUMERIC,
    market_pt_symbol_array TEXT[],
    market_pt_symbol_array_full TEXT[],
    market_pt_symbol_array_all TEXT[],
    base_tokens_locked_array DOUBLE PRECISION[],
    total_naive_tvl NUMERIC,
    base_tokens_symbol_array TEXT[],
    base_tokens_symbols_array TEXT[],
    base_token_collateralization_ratio_array DOUBLE PRECISION[],
    apy_realized_24hr_array DOUBLE PRECISION[],
    apy_realized_7d_array DOUBLE PRECISION[],
    amm_pt_vol_24h_array DOUBLE PRECISION[],
    is_expired_mkt1 BOOLEAN,
    is_expired_mkt2 BOOLEAN,
    last_updated TIMESTAMPTZ,
    slot BIGINT
) AS $$
DECLARE
    v_va_mkt1 TEXT;
    v_va_mkt2 TEXT;
    v_market_addr_mkt1 TEXT;
    v_market_addr_mkt2 TEXT;
BEGIN
    IF (p_mkt1_pt_name IS NULL) != (p_mkt2_pt_name IS NULL) THEN
        RAISE EXCEPTION 'Invalid parameters: p_mkt1_pt_name and p_mkt2_pt_name must both be NULL or both have values. Got: p_mkt1_pt_name=%, p_mkt2_pt_name=%',
            COALESCE(p_mkt1_pt_name, 'NULL'), COALESCE(p_mkt2_pt_name, 'NULL');
    END IF;

    -- Resolve vault addresses for mkt1 and mkt2
    IF p_mkt1_pt_name IS NOT NULL THEN
        SELECT ml.vault_address, ml.market_address INTO v_va_mkt2, v_market_addr_mkt2
        FROM exponent.mat_exp_last ml
        WHERE ml.meta_pt_name = p_mkt2_pt_name
        LIMIT 1;

        SELECT ml.vault_address, ml.market_address INTO v_va_mkt1, v_market_addr_mkt1
        FROM exponent.mat_exp_last ml
        WHERE ml.meta_pt_name = p_mkt1_pt_name
        LIMIT 1;
    ELSE
        SELECT ml.vault_address, ml.market_address INTO v_va_mkt2, v_market_addr_mkt2
        FROM exponent.mat_exp_last ml
        WHERE ml.maturity_ts IS NOT NULL
        ORDER BY ml.maturity_ts DESC
        LIMIT 1;

        IF (SELECT COUNT(*) FROM exponent.mat_exp_last) >= 2 THEN
            SELECT ml.vault_address, ml.market_address INTO v_va_mkt1, v_market_addr_mkt1
            FROM exponent.mat_exp_last ml
            WHERE ml.maturity_ts IS NOT NULL
            ORDER BY ml.maturity_ts DESC
            LIMIT 1 OFFSET 1;
        ELSE
            v_va_mkt1 := v_va_mkt2;
            v_market_addr_mkt1 := v_market_addr_mkt2;
            v_va_mkt2 := NULL;
            v_market_addr_mkt2 := NULL;
        END IF;
    END IF;

    RETURN QUERY
    WITH m1 AS (
        SELECT * FROM exponent.mat_exp_last WHERE vault_address = v_va_mkt1
    ),
    m2 AS (
        SELECT * FROM exponent.mat_exp_last WHERE vault_address = v_va_mkt2
    ),
    -- Decimals from aux
    decimals_config AS (
        SELECT
            COALESCE(
                (SELECT COALESCE(env_sy_decimals, meta_sy_decimals, 6) FROM exponent.aux_key_relations WHERE vault_address = v_va_mkt1),
                6
            ) AS decimals_mkt1,
            COALESCE(
                (SELECT COALESCE(env_sy_decimals, meta_sy_decimals, 6) FROM exponent.aux_key_relations WHERE vault_address = v_va_mkt2),
                (SELECT COALESCE(env_sy_decimals, meta_sy_decimals, 6) FROM exponent.aux_key_relations WHERE vault_address = v_va_mkt1),
                6
            ) AS decimals_mkt2
    ),
    -- Base tokens for each market vault
    vault_base_tokens AS (
        SELECT
            (SELECT meta_base_mint FROM exponent.src_vaults WHERE vault_address = v_va_mkt1 ORDER BY block_time DESC LIMIT 1) AS base_mint_mkt1,
            (SELECT meta_base_mint FROM exponent.src_vaults WHERE vault_address = v_va_mkt2 ORDER BY block_time DESC LIMIT 1) AS base_mint_mkt2
    ),
    -- SY token supply (latest per mint_sy)
    latest_sy_token_accounts AS (
        SELECT DISTINCT ON (st.mint_sy)
            st.mint_sy, st.supply, st.decimals, st.meta_base_mint, st.time
        FROM exponent.src_sy_token_account st
        ORDER BY st.mint_sy, st.time DESC
    ),
    -- eUSX SY exchange rate
    sy_meta_eusx_latest AS (
        SELECT DISTINCT ON (mint_sy) mint_sy, sy_exchange_rate
        FROM exponent.src_sy_meta_account
        WHERE meta_base_mint = '3ThdFZQKM6kRyVGLG48kaPg5TRMhYMKY1iCRa9xop1WC'
        ORDER BY mint_sy, time DESC
    ),
    -- Combined SY supply in USX terms
    sy_token_supply_combined AS (
        SELECT
            COALESCE(SUM(supply) FILTER (WHERE base_mint = '6FrrzDk5mQARGc1TDYoyVnSyRdds1t4PbtohCD6p3tgG'), 0) AS sy_usx_supply_raw,
            COALESCE(SUM(supply) FILTER (WHERE base_mint = '3ThdFZQKM6kRyVGLG48kaPg5TRMhYMKY1iCRa9xop1WC'), 0) AS sy_eusx_supply_raw,
            COALESCE(MAX(decimals) FILTER (WHERE base_mint = '6FrrzDk5mQARGc1TDYoyVnSyRdds1t4PbtohCD6p3tgG'), 6) AS sy_usx_decimals,
            COALESCE(SUM(supply) FILTER (WHERE base_mint = '6FrrzDk5mQARGc1TDYoyVnSyRdds1t4PbtohCD6p3tgG'), 0) +
            COALESCE(
                SUM(supply) FILTER (WHERE base_mint = '3ThdFZQKM6kRyVGLG48kaPg5TRMhYMKY1iCRa9xop1WC') *
                (1.0 / NULLIF(MAX(exchange_rate) FILTER (WHERE base_mint = '3ThdFZQKM6kRyVGLG48kaPg5TRMhYMKY1iCRa9xop1WC'), 0)),
                0
            ) AS sy_total_supply_raw_usx_terms
        FROM (
            SELECT st.mint_sy, st.supply, st.decimals, st.meta_base_mint AS base_mint,
                   sm.sy_exchange_rate AS exchange_rate
            FROM latest_sy_token_accounts st
            LEFT JOIN sy_meta_eusx_latest sm ON st.mint_sy = sm.mint_sy
            WHERE st.meta_base_mint IN ('3ThdFZQKM6kRyVGLG48kaPg5TRMhYMKY1iCRa9xop1WC', '6FrrzDk5mQARGc1TDYoyVnSyRdds1t4PbtohCD6p3tgG')
        ) sy_with_meta
    ),
    -- SY token supply for shared mint_sy
    shared_mint_sy AS (
        SELECT COALESCE(
            (SELECT mint_sy FROM m2 LIMIT 1),
            (SELECT mint_sy FROM m1 LIMIT 1)
        ) AS mint_sy
    ),
    sy_token_supply AS (
        SELECT mint_sy, supply
        FROM latest_sy_token_accounts
        WHERE mint_sy = (SELECT mint_sy FROM shared_mint_sy)
    ),
    -- USX-terms locked for percentage calculations
    market_locked_sy_usx_terms AS (
        SELECT
            CASE
                WHEN (SELECT base_mint_mkt1 FROM vault_base_tokens) = '3ThdFZQKM6kRyVGLG48kaPg5TRMhYMKY1iCRa9xop1WC'
                THEN (COALESCE((SELECT total_sy_in_escrow FROM m1), 0) * POW(10, (SELECT decimals_mkt1 FROM decimals_config)) +
                      COALESCE((SELECT sy_balance FROM m1), 0) * POW(10, (SELECT decimals_mkt1 FROM decimals_config))) *
                     (1.0 / NULLIF((SELECT sy_exchange_rate FROM m1), 0))
                ELSE (COALESCE((SELECT total_sy_in_escrow FROM m1), 0) + COALESCE((SELECT sy_balance FROM m1), 0)) *
                     POW(10, (SELECT decimals_mkt1 FROM decimals_config))
            END AS locked_usx_terms_mkt1,
            CASE
                WHEN v_va_mkt2 IS NULL THEN NULL
                WHEN (SELECT base_mint_mkt2 FROM vault_base_tokens) = '3ThdFZQKM6kRyVGLG48kaPg5TRMhYMKY1iCRa9xop1WC'
                THEN (COALESCE((SELECT total_sy_in_escrow FROM m2), 0) * POW(10, (SELECT decimals_mkt2 FROM decimals_config)) +
                      COALESCE((SELECT sy_balance FROM m2), 0) * POW(10, (SELECT decimals_mkt2 FROM decimals_config))) *
                     (1.0 / NULLIF((SELECT sy_exchange_rate FROM m2), 0))
                ELSE (COALESCE((SELECT total_sy_in_escrow FROM m2), 0) + COALESCE((SELECT sy_balance FROM m2), 0)) *
                     POW(10, (SELECT decimals_mkt2 FROM decimals_config))
            END AS locked_usx_terms_mkt2
    ),
    -- Trailing APY: SY meta lookback for mkt1 and mkt2 base tokens
    sy_meta_trailing_mkt1 AS (
        SELECT mint_sy, time, sy_exchange_rate
        FROM exponent.src_sy_meta_account
        WHERE meta_base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)
          AND time >= NOW() - INTERVAL '8 days'
    ),
    sy_meta_trailing_mkt2 AS (
        SELECT mint_sy, time, sy_exchange_rate
        FROM exponent.src_sy_meta_account
        WHERE meta_base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens)
          AND time >= NOW() - INTERVAL '8 days'
    ),
    sy_meta_trailing_general AS (
        SELECT mint_sy, time, sy_exchange_rate
        FROM exponent.src_sy_meta_account
        WHERE mint_sy = (SELECT mint_sy FROM shared_mint_sy)
          AND time >= NOW() - INTERVAL '8 days'
    ),
    sy_rates AS (
        SELECT
            (SELECT sy_exchange_rate FROM sy_meta_trailing_general ORDER BY time DESC LIMIT 1) AS rate_now,
            (SELECT sy_exchange_rate FROM sy_meta_trailing_general WHERE time <= NOW() - INTERVAL '24 hours' ORDER BY time DESC LIMIT 1) AS rate_24h_ago,
            (SELECT sy_exchange_rate FROM sy_meta_trailing_general WHERE time <= NOW() - INTERVAL '7 days' ORDER BY time DESC LIMIT 1) AS rate_7d_ago,
            (SELECT sy_exchange_rate FROM sy_meta_trailing_mkt1 ORDER BY time DESC LIMIT 1) AS rate_now_mkt1,
            (SELECT sy_exchange_rate FROM sy_meta_trailing_mkt1 WHERE time <= NOW() - INTERVAL '24 hours' ORDER BY time DESC LIMIT 1) AS rate_24h_ago_mkt1,
            (SELECT sy_exchange_rate FROM sy_meta_trailing_mkt1 WHERE time <= NOW() - INTERVAL '7 days' ORDER BY time DESC LIMIT 1) AS rate_7d_ago_mkt1,
            (SELECT sy_exchange_rate FROM sy_meta_trailing_mkt2 ORDER BY time DESC LIMIT 1) AS rate_now_mkt2,
            (SELECT sy_exchange_rate FROM sy_meta_trailing_mkt2 WHERE time <= NOW() - INTERVAL '24 hours' ORDER BY time DESC LIMIT 1) AS rate_24h_ago_mkt2,
            (SELECT sy_exchange_rate FROM sy_meta_trailing_mkt2 WHERE time <= NOW() - INTERVAL '7 days' ORDER BY time DESC LIMIT 1) AS rate_7d_ago_mkt2
    ),
    -- Base token escrow
    base_token_escrow_unique AS (
        SELECT DISTINCT ON (mint)
            mint, amount, meta_base_symbol,
            (amount::DOUBLE PRECISION / NULLIF(POWER(10::DOUBLE PRECISION, COALESCE(meta_base_decimals, 6)), 0.0)) AS amount_decimal
        FROM exponent.src_base_token_escrow
        WHERE mint IN (
            (SELECT base_mint_mkt1 FROM vault_base_tokens),
            (SELECT base_mint_mkt2 FROM vault_base_tokens)
        )
        ORDER BY mint, time DESC
    ),
    base_token_sy_supply AS (
        SELECT DISTINCT ON (st.meta_base_mint)
            st.meta_base_mint AS base_mint,
            (st.supply::DOUBLE PRECISION / NULLIF(POWER(10::DOUBLE PRECISION, COALESCE(st.decimals, 6)), 0.0)) AS supply_decimal
        FROM latest_sy_token_accounts st
        WHERE st.meta_base_mint IN (
            (SELECT base_mint_mkt1 FROM vault_base_tokens),
            (SELECT base_mint_mkt2 FROM vault_base_tokens)
        )
        ORDER BY st.meta_base_mint, st.time DESC
    ),
    base_token_symbols_by_market AS (
        SELECT
            (SELECT meta_base_symbol FROM base_token_escrow_unique WHERE mint = (SELECT base_mint_mkt1 FROM vault_base_tokens) LIMIT 1) AS symbol_mkt1,
            (SELECT meta_base_symbol FROM base_token_escrow_unique WHERE mint = (SELECT base_mint_mkt2 FROM vault_base_tokens) LIMIT 1) AS symbol_mkt2
    ),
    -- Underlying escrow (eUSX locked)
    underlying_escrow AS (
        SELECT DISTINCT ON (mint)
            mint,
            (amount::DOUBLE PRECISION / NULLIF(POWER(10::DOUBLE PRECISION, COALESCE(akr.env_sy_decimals, 6)), 0.0)) AS eusx_locked_amt
        FROM exponent.src_base_token_escrow AS ute
        LEFT JOIN exponent.aux_key_relations AS akr ON akr.underlying_escrow_address = ute.escrow_address
        WHERE mint IN (
            SELECT DISTINCT yield_bearing_mint
            FROM exponent.src_sy_meta_account
            WHERE mint_sy = (SELECT mint_sy FROM shared_mint_sy)
            LIMIT 1
        )
        ORDER BY mint, ute.time DESC
    ),
    -- 24h PT volume per market
    amm_pt_volume_24h AS (
        SELECT market_address,
               SUM(COALESCE(amount_amm_pt_in, 0) + COALESCE(amount_amm_pt_out, 0)) AS pt_volume_24h
        FROM exponent.cagg_tx_events_5s
        WHERE event_type = 'trade_pt' AND market_address IS NOT NULL
          AND bucket_time >= NOW() - INTERVAL '24 hours'
        GROUP BY market_address
    ),
    -- Per-base-token trailing APYs
    base_token_24h_apy AS (
        SELECT DISTINCT ON (base_mint) base_mint,
            CASE
                WHEN base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)
                     AND (SELECT rate_24h_ago_mkt1 FROM sy_rates) IS NOT NULL
                THEN ((SELECT rate_now_mkt1 FROM sy_rates) / NULLIF((SELECT rate_24h_ago_mkt1 FROM sy_rates), 0) - 1.0) * 365.0 * 100
                WHEN base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens)
                     AND base_mint != COALESCE((SELECT base_mint_mkt1 FROM vault_base_tokens), '')
                     AND (SELECT rate_24h_ago_mkt2 FROM sy_rates) IS NOT NULL
                THEN ((SELECT rate_now_mkt2 FROM sy_rates) / NULLIF((SELECT rate_24h_ago_mkt2 FROM sy_rates), 0) - 1.0) * 365.0 * 100
                ELSE NULL
            END AS apy_24h
        FROM (
            SELECT DISTINCT base_mint_mkt1 AS base_mint FROM vault_base_tokens WHERE base_mint_mkt1 IS NOT NULL
            UNION
            SELECT DISTINCT base_mint_mkt2 FROM vault_base_tokens WHERE base_mint_mkt2 IS NOT NULL
        ) ubt
        ORDER BY base_mint
    ),
    base_token_7d_apy AS (
        SELECT DISTINCT ON (base_mint) base_mint,
            CASE
                WHEN base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)
                     AND (SELECT rate_7d_ago_mkt1 FROM sy_rates) IS NOT NULL
                THEN ((SELECT rate_now_mkt1 FROM sy_rates) / NULLIF((SELECT rate_7d_ago_mkt1 FROM sy_rates), 0) - 1.0) * (365.0/7.0) * 100
                WHEN base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens)
                     AND base_mint != COALESCE((SELECT base_mint_mkt1 FROM vault_base_tokens), '')
                     AND (SELECT rate_7d_ago_mkt2 FROM sy_rates) IS NOT NULL
                THEN ((SELECT rate_now_mkt2 FROM sy_rates) / NULLIF((SELECT rate_7d_ago_mkt2 FROM sy_rates), 0) - 1.0) * (365.0/7.0) * 100
                ELSE NULL
            END AS apy_7d
        FROM (
            SELECT DISTINCT base_mint_mkt1 AS base_mint FROM vault_base_tokens WHERE base_mint_mkt1 IS NOT NULL
            UNION
            SELECT DISTINCT base_mint_mkt2 FROM vault_base_tokens WHERE base_mint_mkt2 IS NOT NULL
        ) ubt
        ORDER BY base_mint
    )
    SELECT
        -- MARKET IDENTIFICATION
        v_va_mkt1,
        v_va_mkt2,

        -- SY SUPPLY ANALYTICS
        ROUND(COALESCE(
            (SELECT sy_total_supply_raw_usx_terms FROM sy_token_supply_combined) /
            POW(10, COALESCE((SELECT sy_usx_decimals FROM sy_token_supply_combined), 6)),
            0
        )::NUMERIC, 0),

        ROUND(COALESCE(
            ((SELECT total_sy_in_escrow FROM m1) + COALESCE((SELECT sy_balance FROM m1), 0)),
            0
        )::NUMERIC, 0),
        ROUND(COALESCE(
            (SELECT locked_usx_terms_mkt1 FROM market_locked_sy_usx_terms) /
            NULLIF((SELECT sy_total_supply_raw_usx_terms FROM sy_token_supply_combined), 0) * 100,
            0
        )::NUMERIC, 1),

        ROUND(CASE WHEN v_va_mkt2 IS NOT NULL
            THEN (SELECT total_sy_in_escrow FROM m2) + COALESCE((SELECT sy_balance FROM m2), 0)
            ELSE NULL
        END::NUMERIC, 0),
        ROUND(CASE WHEN v_va_mkt2 IS NOT NULL
            THEN (SELECT locked_usx_terms_mkt2 FROM market_locked_sy_usx_terms) /
                 NULLIF((SELECT sy_total_supply_raw_usx_terms FROM sy_token_supply_combined), 0) * 100
            ELSE NULL
        END::NUMERIC, 1),

        ROUND(COALESCE(
            ((SELECT sy_total_supply_raw_usx_terms FROM sy_token_supply_combined) -
             COALESCE((SELECT locked_usx_terms_mkt1 FROM market_locked_sy_usx_terms), 0) -
             COALESCE((SELECT locked_usx_terms_mkt2 FROM market_locked_sy_usx_terms), 0)) /
             POW(10, COALESCE((SELECT sy_usx_decimals FROM sy_token_supply_combined), 6)),
            0
        )::NUMERIC, 0),
        ROUND(COALESCE(
            100.0 -
            (COALESCE((SELECT locked_usx_terms_mkt1 FROM market_locked_sy_usx_terms), 0) /
             NULLIF((SELECT sy_total_supply_raw_usx_terms FROM sy_token_supply_combined), 0) * 100) -
            (COALESCE((SELECT locked_usx_terms_mkt2 FROM market_locked_sy_usx_terms), 0) /
             NULLIF((SELECT sy_total_supply_raw_usx_terms FROM sy_token_supply_combined), 0) * 100),
            0
        )::NUMERIC, 1),

        -- MATURITY ANALYTICS
        (SELECT start_ts FROM m1),
        CASE WHEN (SELECT start_ts FROM m1) IS NOT NULL THEN to_timestamp((SELECT start_ts FROM m1)) ELSE NULL END,
        (SELECT duration FROM m1),
        (SELECT maturity_ts FROM m1),
        CASE WHEN (SELECT maturity_ts FROM m1) IS NOT NULL THEN to_timestamp((SELECT maturity_ts FROM m1)) ELSE NULL END,
        (SELECT start_ts FROM m2),
        CASE WHEN (SELECT start_ts FROM m2) IS NOT NULL THEN to_timestamp((SELECT start_ts FROM m2)) ELSE NULL END,
        (SELECT duration FROM m2),
        (SELECT maturity_ts FROM m2),
        CASE WHEN (SELECT maturity_ts FROM m2) IS NOT NULL THEN to_timestamp((SELECT maturity_ts FROM m2)) ELSE NULL END,

        -- Chart bounds
        EXTRACT(EPOCH FROM (
            to_timestamp(LEAST(
                COALESCE((SELECT start_ts FROM m1), 2147483647),
                COALESCE((SELECT start_ts FROM m2), 2147483647)
            )) - INTERVAL '7 days'
        ))::INTEGER,
        to_timestamp(LEAST(
            COALESCE((SELECT start_ts FROM m1), 2147483647),
            COALESCE((SELECT start_ts FROM m2), 2147483647)
        )) - INTERVAL '7 days',
        EXTRACT(EPOCH FROM (
            to_timestamp(GREATEST(
                COALESCE((SELECT maturity_ts FROM m1), 0),
                COALESCE((SELECT maturity_ts FROM m2), 0)
            )) + INTERVAL '7 days'
        ))::INTEGER,
        to_timestamp(GREATEST(
            COALESCE((SELECT maturity_ts FROM m1), 0),
            COALESCE((SELECT maturity_ts FROM m2), 0)
        )) + INTERVAL '7 days',
        EXTRACT(EPOCH FROM NOW())::INTEGER,
        NOW(),

        -- MARKET IMPLIED APY (from mat_exp_last, converted to %)
        ROUND(CASE
            WHEN v_va_mkt1 IS NOT NULL
                 AND (SELECT maturity_ts FROM m1) >= EXTRACT(EPOCH FROM NOW())::INTEGER
            THEN (SELECT c_market_implied_apy FROM m1) * 100
            ELSE NULL
        END::NUMERIC, 2),
        ROUND(CASE
            WHEN v_va_mkt2 IS NOT NULL
                 AND (SELECT maturity_ts FROM m2) >= EXTRACT(EPOCH FROM NOW())::INTEGER
            THEN (SELECT c_market_implied_apy FROM m2) * 100
            ELSE NULL
        END::NUMERIC, 2),

        -- PT PRICE (from mat_exp_last)
        ROUND(CASE
            WHEN (SELECT is_expired FROM m1) THEN 1.0
            ELSE COALESCE((SELECT pt_base_price FROM m1), 0)
        END::NUMERIC, 4),
        ROUND(CASE
            WHEN v_va_mkt2 IS NULL THEN NULL
            WHEN (SELECT is_expired FROM m2) THEN 1.0
            ELSE (SELECT pt_base_price FROM m2)
        END::NUMERIC, 4),
        -- PT SY PRICE (DEPRECATED, same as pt_base_price)
        ROUND(CASE
            WHEN (SELECT is_expired FROM m1) THEN 1.0
            ELSE COALESCE((SELECT pt_base_price FROM m1), 0)
        END::NUMERIC, 4),
        ROUND(CASE
            WHEN v_va_mkt2 IS NULL THEN NULL
            WHEN (SELECT is_expired FROM m2) THEN 1.0
            ELSE (SELECT pt_base_price FROM m2)
        END::NUMERIC, 4),

        -- REALIZED VAULT LIFE APY (from mat_exp_last)
        ROUND((SELECT sy_trailing_apy_vault_life FROM m1)::NUMERIC, 2),
        ROUND((SELECT sy_trailing_apy_vault_life FROM m2)::NUMERIC, 2),

        -- REALIZED 24h APY (general, live)
        ROUND(CASE
            WHEN (SELECT rate_24h_ago FROM sy_rates) IS NOT NULL
            THEN ((SELECT rate_now FROM sy_rates) / NULLIF((SELECT rate_24h_ago FROM sy_rates), 0) - 1.0) * 365.0 * 100
            ELSE NULL
        END::NUMERIC, 2),
        -- REALIZED 7d APY (general, live)
        ROUND(CASE
            WHEN (SELECT rate_7d_ago FROM sy_rates) IS NOT NULL
            THEN ((SELECT rate_now FROM sy_rates) / NULLIF((SELECT rate_7d_ago FROM sy_rates), 0) - 1.0) * (365.0/7.0) * 100
            ELSE NULL
        END::NUMERIC, 2),

        -- APY DIVERGENCE
        ROUND(CASE
            WHEN (SELECT rate_24h_ago_mkt1 FROM sy_rates) IS NOT NULL
                 AND NOT (SELECT is_expired FROM m1)
            THEN (SELECT c_market_implied_apy FROM m1) * 100 -
                 ((SELECT rate_now_mkt1 FROM sy_rates) / NULLIF((SELECT rate_24h_ago_mkt1 FROM sy_rates), 0) - 1.0) * 365.0 * 100
            ELSE NULL
        END::NUMERIC, 2),
        ROUND(CASE
            WHEN (SELECT rate_24h_ago_mkt2 FROM sy_rates) IS NOT NULL
                 AND v_va_mkt2 IS NOT NULL AND NOT (SELECT is_expired FROM m2)
            THEN (SELECT c_market_implied_apy FROM m2) * 100 -
                 ((SELECT rate_now_mkt2 FROM sy_rates) / NULLIF((SELECT rate_24h_ago_mkt2 FROM sy_rates), 0) - 1.0) * 365.0 * 100
            ELSE NULL
        END::NUMERIC, 2),
        ROUND(CASE
            WHEN (SELECT rate_7d_ago_mkt1 FROM sy_rates) IS NOT NULL AND NOT (SELECT is_expired FROM m1)
            THEN (SELECT c_market_implied_apy FROM m1) * 100 -
                 ((SELECT rate_now_mkt1 FROM sy_rates) / NULLIF((SELECT rate_7d_ago_mkt1 FROM sy_rates), 0) - 1.0) * (365.0/7.0) * 100
            ELSE NULL
        END::NUMERIC, 2),
        ROUND(CASE
            WHEN (SELECT rate_7d_ago_mkt2 FROM sy_rates) IS NOT NULL
                 AND v_va_mkt2 IS NOT NULL AND NOT (SELECT is_expired FROM m2)
            THEN (SELECT c_market_implied_apy FROM m2) * 100 -
                 ((SELECT rate_now_mkt2 FROM sy_rates) / NULLIF((SELECT rate_7d_ago_mkt2 FROM sy_rates), 0) - 1.0) * (365.0/7.0) * 100
            ELSE NULL
        END::NUMERIC, 2),

        -- DISCOUNT RATES (from mat_exp_last)
        CASE
            WHEN (SELECT is_expired FROM m1) THEN NULL
            ELSE ROUND(COALESCE((SELECT c_market_discount_rate FROM m1) * 100, 0)::NUMERIC, 2)
        END,
        ROUND(CASE
            WHEN v_va_mkt2 IS NOT NULL AND NOT (SELECT is_expired FROM m2)
            THEN (SELECT c_market_discount_rate FROM m2) * 100
            ELSE NULL
        END::NUMERIC, 2),

        -- AMM PRICE IMPACT (live domain function calls)
        100000::INTEGER,
        100000::INTEGER,
        ROUND(CASE
            WHEN v_market_addr_mkt1 IS NOT NULL
            THEN exponent.get_amm_price_impact(v_market_addr_mkt1, 100000.0, NULL)
            ELSE NULL
        END::NUMERIC, 2),
        ROUND(CASE
            WHEN v_market_addr_mkt2 IS NOT NULL
            THEN exponent.get_amm_price_impact(v_market_addr_mkt2, 100000.0, NULL)
            ELSE NULL
        END::NUMERIC, 2),

        -- AMM YIELD IMPACT (live domain function calls)
        ROUND(CASE
            WHEN v_market_addr_mkt1 IS NOT NULL AND NOT (SELECT is_expired FROM m1)
            THEN exponent.get_amm_yield_impact(v_market_addr_mkt1, 100000.0, NULL)
            ELSE NULL
        END::NUMERIC, 2),
        ROUND(CASE
            WHEN v_market_addr_mkt2 IS NOT NULL AND NOT COALESCE((SELECT is_expired FROM m2), TRUE)
            THEN exponent.get_amm_yield_impact(v_market_addr_mkt2, 100000.0, NULL)
            ELSE NULL
        END::NUMERIC, 2),

        -- SY CLAIMS (from mat_exp_last, already decimal-scaled)
        ROUND(COALESCE(
            (SELECT sy_for_pt FROM m1) + COALESCE((SELECT treasury_sy FROM m1), 0) + COALESCE((SELECT uncollected_sy FROM m1), 0),
            0
        )::NUMERIC, 0),
        ROUND(CASE WHEN v_va_mkt2 IS NOT NULL
            THEN (SELECT sy_for_pt FROM m2) + COALESCE((SELECT treasury_sy FROM m2), 0) + COALESCE((SELECT uncollected_sy FROM m2), 0)
            ELSE NULL
        END::NUMERIC, 0),

        -- PT/YT SUPPLY (combined, from mat_exp_last)
        ROUND(COALESCE(
            COALESCE((SELECT pt_supply FROM m1), 0) + COALESCE((SELECT pt_supply FROM m2), 0),
            0
        )::NUMERIC, 0),

        -- LOCKED eUSX
        ROUND(COALESCE((SELECT eusx_locked_amt FROM underlying_escrow), 0)::NUMERIC, 0),
        ROUND(COALESCE(
            (SELECT eusx_locked_amt FROM underlying_escrow) /
            NULLIF(
                (SELECT supply FROM sy_token_supply) / POW(10, (SELECT decimals_mkt2 FROM decimals_config)),
                0
            ),
            0
        )::NUMERIC, 2),

        -- VAULTS & MARKETS (from mat_exp_last pre-computed ratios)
        ROUND(COALESCE((SELECT c_vault_collateralization_ratio FROM m1), 0)::NUMERIC, 2),
        ROUND(COALESCE((SELECT pool_depth_in_sy FROM m1), 0)::NUMERIC, 0),
        ROUND(CASE WHEN (SELECT pool_depth_in_sy FROM m1) > 0
            THEN (SELECT pool_depth_in_sy FROM m1) /
                 NULLIF((SELECT sy_for_pt FROM m1) + COALESCE((SELECT treasury_sy FROM m1), 0) + COALESCE((SELECT uncollected_sy FROM m1), 0), 0) * 100
            ELSE 0
        END::NUMERIC, 1),
        ROUND(CASE WHEN (SELECT pool_depth_in_sy FROM m1) > 0
            THEN ((SELECT sy_for_pt FROM m1) + COALESCE((SELECT treasury_sy FROM m1), 0) + COALESCE((SELECT uncollected_sy FROM m1), 0)) /
                 NULLIF((SELECT pool_depth_in_sy FROM m1), 0) * 100
            ELSE 0
        END::NUMERIC, 1),
        ROUND(COALESCE((SELECT amm_share_sy_pct FROM m1), 0)::NUMERIC, 1),
        ROUND(COALESCE((SELECT yt_staked_pct FROM m1), 0)::NUMERIC, 1),

        -- Market 2
        ROUND(CASE WHEN v_va_mkt2 IS NOT NULL THEN (SELECT c_vault_collateralization_ratio FROM m2) ELSE NULL END::NUMERIC, 2),
        ROUND(CASE WHEN v_va_mkt2 IS NOT NULL THEN (SELECT pool_depth_in_sy FROM m2) ELSE NULL END::NUMERIC, 0),
        ROUND(CASE WHEN v_va_mkt2 IS NOT NULL AND (SELECT pool_depth_in_sy FROM m2) > 0
            THEN (SELECT pool_depth_in_sy FROM m2) /
                 NULLIF((SELECT sy_for_pt FROM m2) + COALESCE((SELECT treasury_sy FROM m2), 0) + COALESCE((SELECT uncollected_sy FROM m2), 0), 0) * 100
            ELSE NULL
        END::NUMERIC, 1),
        ROUND(CASE WHEN v_va_mkt2 IS NOT NULL AND (SELECT pool_depth_in_sy FROM m2) > 0
            THEN ((SELECT sy_for_pt FROM m2) + COALESCE((SELECT treasury_sy FROM m2), 0) + COALESCE((SELECT uncollected_sy FROM m2), 0)) /
                 NULLIF((SELECT pool_depth_in_sy FROM m2), 0) * 100
            ELSE NULL
        END::NUMERIC, 1),
        ROUND(CASE WHEN v_va_mkt2 IS NOT NULL THEN (SELECT amm_share_sy_pct FROM m2) ELSE NULL END::NUMERIC, 1),
        ROUND(CASE WHEN v_va_mkt2 IS NOT NULL THEN (SELECT yt_staked_pct FROM m2) ELSE NULL END::NUMERIC, 1),

        -- ARRAY COLUMNS
        ARRAY[
            (SELECT meta_pt_name FROM m1),
            (SELECT meta_pt_name FROM m2)
        ],
        ARRAY[
            (SELECT meta_pt_name FROM m1),
            (SELECT meta_pt_name FROM m2)
        ],
        (SELECT ARRAY_AGG(DISTINCT meta_pt_name ORDER BY meta_pt_name)
         FROM exponent.aux_key_relations WHERE meta_pt_name IS NOT NULL),

        -- Base tokens locked array
        CASE
            WHEN (SELECT base_mint_mkt1 FROM vault_base_tokens) IS NULL THEN ARRAY[]::DOUBLE PRECISION[]
            WHEN (SELECT base_mint_mkt2 FROM vault_base_tokens) IS NULL
                 OR (SELECT base_mint_mkt2 FROM vault_base_tokens) = (SELECT base_mint_mkt1 FROM vault_base_tokens)
            THEN ARRAY[ROUND((SELECT amount_decimal FROM base_token_escrow_unique WHERE mint = (SELECT base_mint_mkt1 FROM vault_base_tokens))::NUMERIC, 0)::DOUBLE PRECISION]
            ELSE ARRAY[
                ROUND((SELECT amount_decimal FROM base_token_escrow_unique WHERE mint = (SELECT base_mint_mkt1 FROM vault_base_tokens))::NUMERIC, 0)::DOUBLE PRECISION,
                ROUND((SELECT amount_decimal FROM base_token_escrow_unique WHERE mint = (SELECT base_mint_mkt2 FROM vault_base_tokens))::NUMERIC, 0)::DOUBLE PRECISION
            ]
        END,
        ROUND(COALESCE((SELECT SUM(amount_decimal) FROM base_token_escrow_unique), 0)::NUMERIC, 0),

        -- Base tokens symbol arrays
        CASE
            WHEN (SELECT symbol_mkt1 FROM base_token_symbols_by_market) IS NULL THEN ARRAY[]::TEXT[]
            WHEN (SELECT symbol_mkt2 FROM base_token_symbols_by_market) IS NULL
                 OR (SELECT symbol_mkt2 FROM base_token_symbols_by_market) = (SELECT symbol_mkt1 FROM base_token_symbols_by_market)
            THEN ARRAY[(SELECT symbol_mkt1 FROM base_token_symbols_by_market)]
            ELSE ARRAY[(SELECT symbol_mkt1 FROM base_token_symbols_by_market), (SELECT symbol_mkt2 FROM base_token_symbols_by_market)]
        END,
        CASE
            WHEN (SELECT symbol_mkt1 FROM base_token_symbols_by_market) IS NULL THEN ARRAY[]::TEXT[]
            WHEN (SELECT symbol_mkt2 FROM base_token_symbols_by_market) IS NULL
                 OR (SELECT symbol_mkt2 FROM base_token_symbols_by_market) = (SELECT symbol_mkt1 FROM base_token_symbols_by_market)
            THEN ARRAY[(SELECT symbol_mkt1 FROM base_token_symbols_by_market)]
            ELSE ARRAY[(SELECT symbol_mkt1 FROM base_token_symbols_by_market), (SELECT symbol_mkt2 FROM base_token_symbols_by_market)]
        END,

        -- Collateralization ratio array
        CASE
            WHEN (SELECT base_mint_mkt1 FROM vault_base_tokens) IS NULL THEN ARRAY[]::DOUBLE PRECISION[]
            WHEN (SELECT base_mint_mkt2 FROM vault_base_tokens) IS NULL
                 OR (SELECT base_mint_mkt2 FROM vault_base_tokens) = (SELECT base_mint_mkt1 FROM vault_base_tokens)
            THEN ARRAY[ROUND(COALESCE(
                (SELECT amount_decimal FROM base_token_escrow_unique WHERE mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)) /
                NULLIF((SELECT supply_decimal FROM base_token_sy_supply WHERE base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)), 0), 0
            )::NUMERIC, 2)::DOUBLE PRECISION]
            ELSE ARRAY[
                ROUND(COALESCE(
                    (SELECT amount_decimal FROM base_token_escrow_unique WHERE mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)) /
                    NULLIF((SELECT supply_decimal FROM base_token_sy_supply WHERE base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)), 0), 0
                )::NUMERIC, 2)::DOUBLE PRECISION,
                ROUND(COALESCE(
                    (SELECT amount_decimal FROM base_token_escrow_unique WHERE mint = (SELECT base_mint_mkt2 FROM vault_base_tokens)) /
                    NULLIF((SELECT supply_decimal FROM base_token_sy_supply WHERE base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens)), 0), 0
                )::NUMERIC, 2)::DOUBLE PRECISION
            ]
        END,

        -- APY 24h array
        CASE
            WHEN (SELECT base_mint_mkt1 FROM vault_base_tokens) IS NULL THEN ARRAY[]::DOUBLE PRECISION[]
            WHEN (SELECT base_mint_mkt2 FROM vault_base_tokens) IS NULL
                 OR (SELECT base_mint_mkt2 FROM vault_base_tokens) = (SELECT base_mint_mkt1 FROM vault_base_tokens)
            THEN ARRAY[(SELECT ROUND(apy_24h::NUMERIC, 2)::DOUBLE PRECISION FROM base_token_24h_apy WHERE base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens))]
            ELSE ARRAY[
                (SELECT ROUND(apy_24h::NUMERIC, 2)::DOUBLE PRECISION FROM base_token_24h_apy WHERE base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)),
                (SELECT ROUND(apy_24h::NUMERIC, 2)::DOUBLE PRECISION FROM base_token_24h_apy WHERE base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens))
            ]
        END,
        -- APY 7d array
        CASE
            WHEN (SELECT base_mint_mkt1 FROM vault_base_tokens) IS NULL THEN ARRAY[]::DOUBLE PRECISION[]
            WHEN (SELECT base_mint_mkt2 FROM vault_base_tokens) IS NULL
                 OR (SELECT base_mint_mkt2 FROM vault_base_tokens) = (SELECT base_mint_mkt1 FROM vault_base_tokens)
            THEN ARRAY[(SELECT ROUND(apy_7d::NUMERIC, 2)::DOUBLE PRECISION FROM base_token_7d_apy WHERE base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens))]
            ELSE ARRAY[
                (SELECT ROUND(apy_7d::NUMERIC, 2)::DOUBLE PRECISION FROM base_token_7d_apy WHERE base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)),
                (SELECT ROUND(apy_7d::NUMERIC, 2)::DOUBLE PRECISION FROM base_token_7d_apy WHERE base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens))
            ]
        END,

        -- AMM volume 24h array
        ARRAY[
            ROUND(COALESCE((SELECT pt_volume_24h FROM amm_pt_volume_24h WHERE market_address = v_market_addr_mkt1), 0)::NUMERIC, 0)::DOUBLE PRECISION,
            ROUND(COALESCE((SELECT pt_volume_24h FROM amm_pt_volume_24h WHERE market_address = v_market_addr_mkt2), 0)::NUMERIC, 0)::DOUBLE PRECISION
        ],

        -- EXPIRY STATUS (from mat_exp_last)
        (SELECT is_expired FROM m1),
        (SELECT is_expired FROM m2),

        -- METADATA
        NOW(),
        GREATEST(
            COALESCE((SELECT slot FROM m1), 0),
            COALESCE((SELECT slot FROM m2), 0)
        );
END;
$$ LANGUAGE plpgsql STABLE;

-- Wrapper view for backward compatibility
CREATE OR REPLACE VIEW exponent.v_exponent_last AS
SELECT * FROM exponent.get_view_exponent_last();
