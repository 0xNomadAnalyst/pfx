-- NAME: get_view_exponent_last (function) + v_exponent_last (wrapper view)
-- PFX variant: reads core per-market data from mat_exp_last (mid-level table)
-- Same signature and output schema as the canonical version
-- (exponent/dbsql/views/get_view_exponent_last.sql)
--
-- mat_exp_last provides decimal-adjusted, per-market pre-computed data.
-- Supplementary lookups (SY exchange rate history, base token escrows,
-- SY token supply, AMM price impact) still read from source tables.

CREATE OR REPLACE FUNCTION exponent.get_view_exponent_last(
    p_mkt1_pt_name TEXT DEFAULT NULL,
    p_mkt2_pt_name TEXT DEFAULT NULL
)
RETURNS TABLE (
    -- MARKET IDENTIFICATION
    vault_address_mkt1 TEXT,
    vault_address_mkt2 TEXT,

    -- SY SUPPLY ANALYTICS
    sy_total_supply NUMERIC,
    sy_total_locked_mkt1 NUMERIC,
    sy_total_locked_pct_mkt1 NUMERIC,
    sy_total_locked_mkt2 NUMERIC,
    sy_total_locked_pct_mkt2 NUMERIC,
    sy_not_in_mkt1_mkt2 NUMERIC,
    sy_not_in_mkt1_mkt2_pct NUMERIC,

    -- MATURITY ANALYTICS
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

    -- MARKET IMPLIED APY
    apy_market_mkt1 NUMERIC,
    apy_market_mkt2 NUMERIC,

    -- PT PRICE
    pt_base_price_mkt1 NUMERIC,
    pt_base_price_mkt2 NUMERIC,
    pt_sy_price_mkt1 NUMERIC,  -- DEPRECATED
    pt_sy_price_mkt2 NUMERIC,  -- DEPRECATED

    -- REALIZED UNDERLYING YIELD
    apy_realized_vault_life_mkt1 NUMERIC,
    apy_realized_vault_life_mkt2 NUMERIC,
    apy_realized_24h NUMERIC,
    apy_realized_7d NUMERIC,

    -- APY DIVERGENCE
    apy_divergence_wrt_24h_mkt1 NUMERIC,
    apy_divergence_wrt_24h_mkt2 NUMERIC,
    apy_divergence_wrt_7d_mkt1 NUMERIC,
    apy_divergence_wrt_7d_mkt2 NUMERIC,

    -- DISCOUNT RATES
    discount_rate_mkt1 NUMERIC,
    discount_rate_mkt2 NUMERIC,

    -- AMM PRICE IMPACT
    amm_impact_trade_size_pt INTEGER,
    amm_price_impact_trade_size_sy INTEGER,  -- DEPRECATED
    amm_price_impact_mkt1_pct NUMERIC,
    amm_price_impact_mkt2_pct NUMERIC,

    -- AMM YIELD IMPACT
    amm_yield_impact_mkt1_pct NUMERIC,
    amm_yield_impact_mkt2_pct NUMERIC,

    -- SY CLAIMS
    sy_claims_mkt1 NUMERIC,
    sy_claims_mkt2 NUMERIC,
    pt_yt_supply NUMERIC,

    -- LOCKED eUSX
    eusx_locked NUMERIC,
    eusx_collateralization_ratio NUMERIC,

    -- VAULTS & MARKETS
    sy_coll_ratio_mkt1 NUMERIC,
    amm_depth_in_sy_mkt1 NUMERIC,
    amm_depth_in_base_mkt1 NUMERIC,
    amm_pct_of_sy_claims_mkt1 NUMERIC,
    vault_sy_claims_pct_amm_mkt1 NUMERIC,
    amm_share_sy_pct_mkt1 NUMERIC,
    yt_staked_pct_mkt1 NUMERIC,
    sy_coll_ratio_mkt2 NUMERIC,
    amm_depth_in_sy_mkt2 NUMERIC,
    amm_depth_in_base_mkt2 NUMERIC,
    amm_pct_of_sy_claims_mkt2 NUMERIC,
    vault_sy_claims_pct_amm_mkt2 NUMERIC,
    amm_share_sy_pct_mkt2 NUMERIC,
    yt_staked_pct_mkt2 NUMERIC,

    -- ARRAY COLUMNS
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

    -- EXPIRY STATUS
    is_expired_mkt1 BOOLEAN,
    is_expired_mkt2 BOOLEAN,

    -- METADATA
    last_updated TIMESTAMPTZ,
    slot BIGINT
) AS $$
BEGIN
    IF (p_mkt1_pt_name IS NULL) != (p_mkt2_pt_name IS NULL) THEN
        RAISE EXCEPTION 'Invalid parameters: p_mkt1_pt_name and p_mkt2_pt_name must both be NULL or both have values. Got: p_mkt1_pt_name=%, p_mkt2_pt_name=%',
            COALESCE(p_mkt1_pt_name, 'NULL'), COALESCE(p_mkt2_pt_name, 'NULL');
    END IF;

    RETURN QUERY
    WITH
    -- ══════════════════════════════════════════════════════════════════════
    -- MARKET SELECTION (from mat_exp_last — decimal-adjusted per-market data)
    -- ══════════════════════════════════════════════════════════════════════
    ranked AS (
        SELECT
            ml.*,
            CASE
                WHEN p_mkt1_pt_name IS NULL THEN
                    ROW_NUMBER() OVER (ORDER BY ml.maturity_ts DESC)
                ELSE
                    CASE
                        WHEN ml.meta_pt_name = p_mkt2_pt_name THEN 1
                        WHEN ml.meta_pt_name = p_mkt1_pt_name THEN 2
                        ELSE NULL
                    END
            END AS rnk,
            CASE
                WHEN p_mkt1_pt_name IS NULL THEN COUNT(*) OVER ()
                ELSE 2
            END AS total_markets
        FROM exponent.mat_exp_last ml
        WHERE p_mkt1_pt_name IS NULL
           OR ml.meta_pt_name IN (p_mkt1_pt_name, p_mkt2_pt_name)
    ),
    m2 AS (
        SELECT * FROM ranked
        WHERE rnk = 1
          AND (p_mkt1_pt_name IS NOT NULL OR total_markets >= 2)
    ),
    m1 AS (
        SELECT * FROM ranked
        WHERE rnk = CASE
            WHEN p_mkt1_pt_name IS NOT NULL THEN 2
            WHEN total_markets = 1 THEN 1
            ELSE 2
        END
    ),

    -- ══════════════════════════════════════════════════════════════════════
    -- METADATA LOOKUPS
    -- ══════════════════════════════════════════════════════════════════════
    shared_mint_sy AS (
        SELECT COALESCE(
            (SELECT mint_sy FROM m2 LIMIT 1),
            (SELECT mint_sy FROM m1 LIMIT 1)
        ) AS mint_sy
    ),
    vault_base_tokens AS (
        -- 30-day bound keeps the scan inside the hot tier (most chunks for the
        -- last 30d are local) while tolerating inactive markets whose latest
        -- src_market_twos snapshot can be a week or more old.
        SELECT
            (SELECT meta_base_mint FROM exponent.src_market_twos
             WHERE market_address = (SELECT market_address FROM m1 LIMIT 1)
               AND block_time >= NOW() - INTERVAL '30 days'
             ORDER BY block_time DESC LIMIT 1) AS base_mint_mkt1,
            (SELECT meta_base_mint FROM exponent.src_market_twos
             WHERE market_address = (SELECT market_address FROM m2 LIMIT 1)
               AND block_time >= NOW() - INTERVAL '30 days'
             ORDER BY block_time DESC LIMIT 1) AS base_mint_mkt2
    ),
    decimals_config AS (
        SELECT
            COALESCE(
                (SELECT env_sy_decimals FROM exponent.aux_key_relations WHERE vault_address = (SELECT vault_address FROM m1 LIMIT 1)),
                (SELECT meta_sy_decimals FROM exponent.aux_key_relations WHERE vault_address = (SELECT vault_address FROM m1 LIMIT 1)),
                6
            ) AS decimals_mkt1,
            COALESCE(
                (SELECT env_sy_decimals FROM exponent.aux_key_relations WHERE vault_address = (SELECT vault_address FROM m2 LIMIT 1)),
                (SELECT meta_sy_decimals FROM exponent.aux_key_relations WHERE vault_address = (SELECT vault_address FROM m2 LIMIT 1)),
                (SELECT env_sy_decimals FROM exponent.aux_key_relations WHERE vault_address = (SELECT vault_address FROM m1 LIMIT 1)),
                6
            ) AS decimals_mkt2
    ),

    -- ══════════════════════════════════════════════════════════════════════
    -- SY TOKEN SUPPLY
    -- ══════════════════════════════════════════════════════════════════════
    latest_sy_token_accounts AS (
        -- Bounded to last 24h to avoid scanning OSM-tier chunks; src_sy_token_account
        -- updates frequently so all live mints will be present in this window.
        SELECT DISTINCT ON (st.mint_sy)
            st.mint_sy, st.supply, st.decimals, st.meta_base_mint, st.time
        FROM exponent.src_sy_token_account st
        WHERE st.time >= NOW() - INTERVAL '1 day'
        ORDER BY st.mint_sy, st.time DESC
    ),
    sy_supply_total AS (
        SELECT
            SUM(supply::NUMERIC / POW(10, COALESCE(decimals, 6))) AS supply_decimal
        FROM latest_sy_token_accounts
    ),
    sy_supply_shared AS (
        SELECT supply, decimals
        FROM latest_sy_token_accounts
        WHERE mint_sy = (SELECT mint_sy FROM shared_mint_sy)
    ),

    -- ══════════════════════════════════════════════════════════════════════
    -- SY EXCHANGE RATE LOOKBACKS (for trailing APY & divergence)
    -- Current rates come from mat_exp_last; historical from src_sy_meta_account.
    -- ══════════════════════════════════════════════════════════════════════

    -- General (legacy) lookbacks — filter by shared mint_sy.
    -- Lower bound on the search window prevents the planner from descending
    -- into the OSM tier when no row is found in the recent hot chunks.
    sy_rate_24h_ago AS (
        SELECT sy_exchange_rate AS rate
        FROM exponent.src_sy_meta_account
        WHERE mint_sy = (SELECT mint_sy FROM shared_mint_sy)
          AND time <= NOW() - INTERVAL '24 hours'
          AND time >= NOW() - INTERVAL '3 days'
        ORDER BY time DESC LIMIT 1
    ),
    sy_rate_7d_ago AS (
        SELECT sy_exchange_rate AS rate
        FROM exponent.src_sy_meta_account
        WHERE mint_sy = (SELECT mint_sy FROM shared_mint_sy)
          AND time <= NOW() - INTERVAL '7 days'
          AND time >= NOW() - INTERVAL '14 days'
        ORDER BY time DESC LIMIT 1
    ),

    -- Per-market lookbacks — filter by base_mint
    sy_rate_24h_ago_mkt1 AS (
        SELECT sy_exchange_rate AS rate
        FROM exponent.src_sy_meta_account
        WHERE meta_base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)
          AND time <= NOW() - INTERVAL '24 hours'
          AND time >= NOW() - INTERVAL '3 days'
        ORDER BY time DESC LIMIT 1
    ),
    sy_rate_24h_ago_mkt2 AS (
        SELECT sy_exchange_rate AS rate
        FROM exponent.src_sy_meta_account
        WHERE meta_base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens)
          AND time <= NOW() - INTERVAL '24 hours'
          AND time >= NOW() - INTERVAL '3 days'
        ORDER BY time DESC LIMIT 1
    ),
    sy_rate_7d_ago_mkt1 AS (
        SELECT sy_exchange_rate AS rate
        FROM exponent.src_sy_meta_account
        WHERE meta_base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)
          AND time <= NOW() - INTERVAL '7 days'
          AND time >= NOW() - INTERVAL '14 days'
        ORDER BY time DESC LIMIT 1
    ),
    sy_rate_7d_ago_mkt2 AS (
        SELECT sy_exchange_rate AS rate
        FROM exponent.src_sy_meta_account
        WHERE meta_base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens)
          AND time <= NOW() - INTERVAL '7 days'
          AND time >= NOW() - INTERVAL '14 days'
        ORDER BY time DESC LIMIT 1
    ),

    -- ══════════════════════════════════════════════════════════════════════
    -- LIFETIME APY (vault-life realized yield)
    -- Start rate: from src_sy_meta_account (earliest available).
    -- End rate: from mat_exp_last (sy_exchange_rate or final_sy_exchange_rate).
    -- Backward extrapolation kept for vaults that started before SY polling.
    -- ══════════════════════════════════════════════════════════════════════
    lifetime_config AS (
        -- env_* config columns are part of every row of src_sy_meta_account; the
        -- last 24h hot-tier window is enough to find the latest values and
        -- avoids the OSM tier (these run 4× per call).
        SELECT
            (SELECT env_sy_lifetime_apy_start_date FROM exponent.src_sy_meta_account
             WHERE meta_base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)
               AND time >= NOW() - INTERVAL '1 day'
             ORDER BY time DESC LIMIT 1) AS env_start_date_mkt1,
            (SELECT env_sy_lifetime_apy_start_index FROM exponent.src_sy_meta_account
             WHERE meta_base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)
               AND time >= NOW() - INTERVAL '1 day'
             ORDER BY time DESC LIMIT 1) AS env_start_index_mkt1,
            (SELECT env_sy_lifetime_apy_start_date FROM exponent.src_sy_meta_account
             WHERE meta_base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens)
               AND time >= NOW() - INTERVAL '1 day'
             ORDER BY time DESC LIMIT 1) AS env_start_date_mkt2,
            (SELECT env_sy_lifetime_apy_start_index FROM exponent.src_sy_meta_account
             WHERE meta_base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens)
               AND time >= NOW() - INTERVAL '1 day'
             ORDER BY time DESC LIMIT 1) AS env_start_index_mkt2
    ),
    sy_meta_start_mkt1 AS (
        SELECT
            sy_exchange_rate AS start_rate,
            time AS start_time,
            EXTRACT(EPOCH FROM time)::INTEGER AS start_epoch
        FROM exponent.src_sy_meta_account
        WHERE meta_base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)
        ORDER BY
            CASE
                WHEN COALESCE((SELECT start_ts FROM m1 LIMIT 1), EXTRACT(EPOCH FROM time)::INTEGER) <= EXTRACT(EPOCH FROM time)::INTEGER THEN 0
                ELSE 1
            END,
            EXTRACT(EPOCH FROM time)::INTEGER ASC
        LIMIT 1
    ),
    sy_meta_start_mkt2 AS (
        SELECT
            sy_exchange_rate AS start_rate,
            time AS start_time,
            EXTRACT(EPOCH FROM time)::INTEGER AS start_epoch
        FROM exponent.src_sy_meta_account
        WHERE meta_base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens)
        ORDER BY
            CASE
                WHEN COALESCE((SELECT start_ts FROM m2 LIMIT 1), EXTRACT(EPOCH FROM time)::INTEGER) <= EXTRACT(EPOCH FROM time)::INTEGER THEN 0
                ELSE 1
            END,
            EXTRACT(EPOCH FROM time)::INTEGER ASC
        LIMIT 1
    ),
    lifetime_start AS (
        SELECT
            bv.base_start_ts_mkt1,
            bv.base_start_index_mkt1,
            CASE WHEN bv.base_start_ts_mkt1 IS NOT NULL
                 THEN EXTRACT(EPOCH FROM bv.base_start_ts_mkt1) ELSE NULL END AS base_start_epoch_mkt1,
            bv.base_start_ts_mkt2,
            bv.base_start_index_mkt2,
            CASE WHEN bv.base_start_ts_mkt2 IS NOT NULL
                 THEN EXTRACT(EPOCH FROM bv.base_start_ts_mkt2) ELSE NULL END AS base_start_epoch_mkt2
        FROM (
            SELECT
                -- Market 1 baseline timestamp
                CASE
                    WHEN (SELECT start_ts FROM m1 LIMIT 1) >= (SELECT start_epoch FROM sy_meta_start_mkt1)
                    THEN (SELECT start_time FROM sy_meta_start_mkt1)
                    WHEN lc.env_start_date_mkt1 IS NOT NULL
                         AND lc.env_start_index_mkt1 IS NOT NULL AND lc.env_start_index_mkt1 > 0
                         AND (SELECT start_ts FROM m1 LIMIT 1) IS NOT NULL
                         AND (SELECT start_epoch FROM sy_meta_start_mkt1) > (SELECT start_ts FROM m1 LIMIT 1)
                    THEN to_timestamp((SELECT start_ts FROM m1 LIMIT 1))
                    ELSE (SELECT start_time FROM sy_meta_start_mkt1)
                END AS base_start_ts_mkt1,
                -- Market 1 baseline index
                CASE
                    WHEN (SELECT start_ts FROM m1 LIMIT 1) >= (SELECT start_epoch FROM sy_meta_start_mkt1)
                    THEN (SELECT start_rate FROM sy_meta_start_mkt1)
                    WHEN lc.env_start_date_mkt1 IS NOT NULL
                         AND lc.env_start_index_mkt1 IS NOT NULL AND lc.env_start_index_mkt1 > 0
                         AND (SELECT start_ts FROM m1 LIMIT 1) IS NOT NULL
                         AND (SELECT start_epoch FROM sy_meta_start_mkt1) > (SELECT start_ts FROM m1 LIMIT 1)
                    THEN (
                        (SELECT start_rate FROM sy_meta_start_mkt1) / NULLIF(
                            POWER(
                                (SELECT start_rate FROM sy_meta_start_mkt1) / NULLIF(lc.env_start_index_mkt1, 0),
                                (
                                    ((SELECT start_epoch FROM sy_meta_start_mkt1) - (SELECT start_ts FROM m1 LIMIT 1))::DOUBLE PRECISION /
                                    NULLIF(((SELECT start_epoch FROM sy_meta_start_mkt1) - EXTRACT(EPOCH FROM lc.env_start_date_mkt1)::INTEGER)::DOUBLE PRECISION, 0)
                                )
                            ), 0
                        )
                    )
                    ELSE (SELECT start_rate FROM sy_meta_start_mkt1)
                END AS base_start_index_mkt1,
                -- Market 2 baseline timestamp
                CASE
                    WHEN (SELECT start_ts FROM m2 LIMIT 1) >= (SELECT start_epoch FROM sy_meta_start_mkt2)
                    THEN (SELECT start_time FROM sy_meta_start_mkt2)
                    WHEN lc.env_start_date_mkt2 IS NOT NULL
                         AND lc.env_start_index_mkt2 IS NOT NULL AND lc.env_start_index_mkt2 > 0
                         AND (SELECT start_ts FROM m2 LIMIT 1) IS NOT NULL
                         AND (SELECT start_epoch FROM sy_meta_start_mkt2) > (SELECT start_ts FROM m2 LIMIT 1)
                    THEN to_timestamp((SELECT start_ts FROM m2 LIMIT 1))
                    ELSE (SELECT start_time FROM sy_meta_start_mkt2)
                END AS base_start_ts_mkt2,
                -- Market 2 baseline index
                CASE
                    WHEN (SELECT start_ts FROM m2 LIMIT 1) >= (SELECT start_epoch FROM sy_meta_start_mkt2)
                    THEN (SELECT start_rate FROM sy_meta_start_mkt2)
                    WHEN lc.env_start_date_mkt2 IS NOT NULL
                         AND lc.env_start_index_mkt2 IS NOT NULL AND lc.env_start_index_mkt2 > 0
                         AND (SELECT start_ts FROM m2 LIMIT 1) IS NOT NULL
                         AND (SELECT start_epoch FROM sy_meta_start_mkt2) > (SELECT start_ts FROM m2 LIMIT 1)
                    THEN (
                        (SELECT start_rate FROM sy_meta_start_mkt2) / NULLIF(
                            POWER(
                                (SELECT start_rate FROM sy_meta_start_mkt2) / NULLIF(lc.env_start_index_mkt2, 0),
                                (
                                    ((SELECT start_epoch FROM sy_meta_start_mkt2) - (SELECT start_ts FROM m2 LIMIT 1))::DOUBLE PRECISION /
                                    NULLIF(((SELECT start_epoch FROM sy_meta_start_mkt2) - EXTRACT(EPOCH FROM lc.env_start_date_mkt2)::INTEGER)::DOUBLE PRECISION, 0)
                                )
                            ), 0
                        )
                    )
                    ELSE (SELECT start_rate FROM sy_meta_start_mkt2)
                END AS base_start_index_mkt2
            FROM lifetime_config lc
        ) AS bv
    ),

    -- ══════════════════════════════════════════════════════════════════════
    -- BASE TOKEN ESCROWS
    -- ══════════════════════════════════════════════════════════════════════
    underlying_escrow AS (
        -- 24h bound keeps the DISTINCT ON within the hot tier; src_base_token_escrow
        -- updates frequently enough that all live mints will have a recent row.
        SELECT DISTINCT ON (mint)
            mint,
            (amount::DOUBLE PRECISION / NULLIF(POWER(10::DOUBLE PRECISION, COALESCE(akr.env_sy_decimals)), 0.0)) AS eusx_locked_amt
        FROM exponent.src_base_token_escrow AS ute
        LEFT JOIN exponent.aux_key_relations AS akr
            ON akr.underlying_escrow_address = ute.escrow_address
        WHERE ute.time >= NOW() - INTERVAL '1 day'
          AND mint IN (
            SELECT DISTINCT yield_bearing_mint
            FROM exponent.src_sy_meta_account
            WHERE mint_sy = (SELECT mint_sy FROM shared_mint_sy)
              AND time >= NOW() - INTERVAL '1 day'
            LIMIT 1
        )
        ORDER BY mint, ute.time DESC
    ),
    base_token_escrow_unique AS (
        SELECT DISTINCT ON (mint)
            mint,
            amount,
            meta_base_symbol,
            (amount::DOUBLE PRECISION / NULLIF(POWER(10::DOUBLE PRECISION, COALESCE(meta_base_decimals, 6)), 0.0)) AS amount_decimal
        FROM exponent.src_base_token_escrow
        WHERE time >= NOW() - INTERVAL '1 day'
          AND mint IN (
            (SELECT base_mint_mkt1 FROM vault_base_tokens),
            (SELECT base_mint_mkt2 FROM vault_base_tokens)
          )
        ORDER BY mint, time DESC
    ),
    base_token_sy_supply AS (
        SELECT DISTINCT ON (st.meta_base_mint)
            st.meta_base_mint AS base_mint,
            st.supply,
            st.decimals,
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
            (SELECT meta_base_symbol FROM base_token_escrow_unique
             WHERE mint = (SELECT base_mint_mkt1 FROM vault_base_tokens) LIMIT 1) AS symbol_mkt1,
            (SELECT meta_base_symbol FROM base_token_escrow_unique
             WHERE mint = (SELECT base_mint_mkt2 FROM vault_base_tokens) LIMIT 1) AS symbol_mkt2
    ),

    -- ══════════════════════════════════════════════════════════════════════
    -- REALIZED APY PER BASE TOKEN (for array columns)
    -- ══════════════════════════════════════════════════════════════════════
    base_token_24h_apy AS (
        SELECT DISTINCT ON (base_mint)
            base_mint,
            CASE
                WHEN base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)
                     AND (SELECT rate FROM sy_rate_24h_ago_mkt1) IS NOT NULL
                     AND (SELECT sy_exchange_rate FROM m1 LIMIT 1) IS NOT NULL
                THEN (
                    ((SELECT sy_exchange_rate FROM m1 LIMIT 1) /
                     NULLIF((SELECT rate FROM sy_rate_24h_ago_mkt1), 0) - 1.0
                    ) * 365.0 * 100
                )
                WHEN base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens)
                     AND base_mint != COALESCE((SELECT base_mint_mkt1 FROM vault_base_tokens), '')
                     AND (SELECT rate FROM sy_rate_24h_ago_mkt2) IS NOT NULL
                     AND (SELECT sy_exchange_rate FROM m2 LIMIT 1) IS NOT NULL
                THEN (
                    ((SELECT sy_exchange_rate FROM m2 LIMIT 1) /
                     NULLIF((SELECT rate FROM sy_rate_24h_ago_mkt2), 0) - 1.0
                    ) * 365.0 * 100
                )
                ELSE NULL
            END AS apy_24h
        FROM (
            SELECT DISTINCT base_mint_mkt1 AS base_mint FROM vault_base_tokens WHERE base_mint_mkt1 IS NOT NULL
            UNION
            SELECT DISTINCT base_mint_mkt2 AS base_mint FROM vault_base_tokens WHERE base_mint_mkt2 IS NOT NULL
        ) unique_base_tokens
        ORDER BY base_mint
    ),
    base_token_7d_apy AS (
        SELECT DISTINCT ON (base_mint)
            base_mint,
            CASE
                WHEN base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)
                     AND (SELECT rate FROM sy_rate_7d_ago_mkt1) IS NOT NULL
                     AND (SELECT sy_exchange_rate FROM m1 LIMIT 1) IS NOT NULL
                THEN (
                    ((SELECT sy_exchange_rate FROM m1 LIMIT 1) /
                     NULLIF((SELECT rate FROM sy_rate_7d_ago_mkt1), 0) - 1.0
                    ) * (365.0 / 7.0) * 100
                )
                WHEN base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens)
                     AND base_mint != COALESCE((SELECT base_mint_mkt1 FROM vault_base_tokens), '')
                     AND (SELECT rate FROM sy_rate_7d_ago_mkt2) IS NOT NULL
                     AND (SELECT sy_exchange_rate FROM m2 LIMIT 1) IS NOT NULL
                THEN (
                    ((SELECT sy_exchange_rate FROM m2 LIMIT 1) /
                     NULLIF((SELECT rate FROM sy_rate_7d_ago_mkt2), 0) - 1.0
                    ) * (365.0 / 7.0) * 100
                )
                ELSE NULL
            END AS apy_7d
        FROM (
            SELECT DISTINCT base_mint_mkt1 AS base_mint FROM vault_base_tokens WHERE base_mint_mkt1 IS NOT NULL
            UNION
            SELECT DISTINCT base_mint_mkt2 AS base_mint FROM vault_base_tokens WHERE base_mint_mkt2 IS NOT NULL
        ) unique_base_tokens
        ORDER BY base_mint
    ),

    -- ══════════════════════════════════════════════════════════════════════
    -- SIMPLE APY (linear annualization matching Exponent web convention)
    -- ══════════════════════════════════════════════════════════════════════
    simple_apy AS (
        SELECT
            CASE
                WHEN (SELECT pt_base_price FROM m1) IS NOT NULL
                     AND (SELECT pt_base_price FROM m1) > 0
                     AND (SELECT pt_base_price FROM m1) < 1.0
                     AND (SELECT maturity_ts FROM m1) > EXTRACT(EPOCH FROM NOW())::INTEGER
                THEN (
                    (1.0 / (SELECT pt_base_price FROM m1) - 1.0) /
                    GREATEST(
                        ((SELECT maturity_ts FROM m1)::NUMERIC - EXTRACT(EPOCH FROM NOW())::NUMERIC) / 31536000.0,
                        1.0 / 365.0
                    )
                )
                ELSE NULL
            END AS mkt1,
            CASE
                WHEN (SELECT pt_base_price FROM m2) IS NOT NULL
                     AND (SELECT pt_base_price FROM m2) > 0
                     AND (SELECT pt_base_price FROM m2) < 1.0
                     AND (SELECT maturity_ts FROM m2) > EXTRACT(EPOCH FROM NOW())::INTEGER
                THEN (
                    (1.0 / (SELECT pt_base_price FROM m2) - 1.0) /
                    GREATEST(
                        ((SELECT maturity_ts FROM m2)::NUMERIC - EXTRACT(EPOCH FROM NOW())::NUMERIC) / 31536000.0,
                        1.0 / 365.0
                    )
                )
                ELSE NULL
            END AS mkt2
    )

    -- ══════════════════════════════════════════════════════════════════════
    -- FINAL SELECT
    -- ══════════════════════════════════════════════════════════════════════
    SELECT
    -- ─── MARKET IDENTIFICATION ────────────────────────────────────────
    (SELECT vault_address FROM m1)::TEXT,
    (SELECT vault_address FROM m2)::TEXT,

    -- ─── SY SUPPLY ANALYTICS ─────────────────────────────────────────
    -- mat_exp_last values are already decimal-adjusted, as is sy_supply_total
    ROUND(COALESCE((SELECT supply_decimal FROM sy_supply_total), 0)::NUMERIC, 0),

    -- Locked = vault escrow + AMM pool SY (decimal-adjusted from mat_exp_last)
    ROUND(COALESCE(
        (SELECT total_sy_in_escrow FROM m1) + (SELECT sy_balance FROM m1),
        0
    )::NUMERIC, 0),

    ROUND(COALESCE(
        ((SELECT total_sy_in_escrow FROM m1) + (SELECT sy_balance FROM m1)) /
        NULLIF((SELECT supply_decimal FROM sy_supply_total), 0) * 100,
        0
    )::NUMERIC, 1),

    ROUND(CASE
        WHEN (SELECT vault_address FROM m2) IS NOT NULL
        THEN (SELECT total_sy_in_escrow FROM m2) + (SELECT sy_balance FROM m2)
        ELSE NULL
    END::NUMERIC, 0),

    ROUND(CASE
        WHEN (SELECT vault_address FROM m2) IS NOT NULL
        THEN ((SELECT total_sy_in_escrow FROM m2) + (SELECT sy_balance FROM m2)) /
             NULLIF((SELECT supply_decimal FROM sy_supply_total), 0) * 100
        ELSE NULL
    END::NUMERIC, 1),

    ROUND(COALESCE(
        (SELECT supply_decimal FROM sy_supply_total) -
        COALESCE((SELECT total_sy_in_escrow FROM m1) + (SELECT sy_balance FROM m1), 0) -
        COALESCE((SELECT total_sy_in_escrow FROM m2) + (SELECT sy_balance FROM m2), 0),
        0
    )::NUMERIC, 0),

    ROUND(COALESCE(
        100.0 -
        COALESCE(((SELECT total_sy_in_escrow FROM m1) + (SELECT sy_balance FROM m1)) /
                 NULLIF((SELECT supply_decimal FROM sy_supply_total), 0) * 100, 0) -
        COALESCE(((SELECT total_sy_in_escrow FROM m2) + (SELECT sy_balance FROM m2)) /
                 NULLIF((SELECT supply_decimal FROM sy_supply_total), 0) * 100, 0),
        0
    )::NUMERIC, 1),

    -- ─── MATURITY ANALYTICS ──────────────────────────────────────────
    (SELECT start_ts FROM m1),
    to_timestamp((SELECT start_ts FROM m1)),
    (SELECT duration FROM m1),
    (SELECT maturity_ts FROM m1),
    to_timestamp((SELECT maturity_ts FROM m1)),

    (SELECT start_ts FROM m2),
    to_timestamp((SELECT start_ts FROM m2)),
    (SELECT duration FROM m2),
    (SELECT maturity_ts FROM m2),
    to_timestamp((SELECT maturity_ts FROM m2)),

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

    -- ─── MARKET IMPLIED APY ──────────────────────────────────────────
    ROUND(COALESCE((SELECT mkt1 FROM simple_apy) * 100, NULL)::NUMERIC, 2),
    ROUND(COALESCE((SELECT mkt2 FROM simple_apy) * 100, NULL)::NUMERIC, 2),

    -- ─── PT PRICE ────────────────────────────────────────────────────
    ROUND(CASE
        WHEN (SELECT maturity_ts FROM m1) < EXTRACT(EPOCH FROM NOW())::INTEGER
        THEN 1.0
        ELSE COALESCE((SELECT pt_base_price FROM m1), 0)
    END::NUMERIC, 4),

    ROUND(CASE
        WHEN (SELECT market_address FROM m2) IS NULL THEN NULL
        WHEN (SELECT maturity_ts FROM m2) < EXTRACT(EPOCH FROM NOW())::INTEGER
        THEN 1.0
        ELSE (SELECT pt_base_price FROM m2)
    END::NUMERIC, 4),

    -- PT SY price (DEPRECATED — same as pt_base_price)
    ROUND(CASE
        WHEN (SELECT maturity_ts FROM m1) < EXTRACT(EPOCH FROM NOW())::INTEGER
        THEN 1.0
        ELSE COALESCE((SELECT pt_base_price FROM m1), 0)
    END::NUMERIC, 4),

    ROUND(CASE
        WHEN (SELECT market_address FROM m2) IS NULL THEN NULL
        WHEN (SELECT maturity_ts FROM m2) < EXTRACT(EPOCH FROM NOW())::INTEGER
        THEN 1.0
        ELSE (SELECT pt_base_price FROM m2)
    END::NUMERIC, 4),

    -- ─── REALIZED UNDERLYING YIELD — VAULT LIFE ─────────────────────
    -- End rate: sy_exchange_rate (active) or final_sy_exchange_rate (expired) from mat_exp_last
    ROUND(CASE
        WHEN (SELECT vault_address FROM m1) IS NULL THEN NULL
        WHEN (SELECT base_start_index_mkt1 FROM lifetime_start) IS NOT NULL
             AND (SELECT base_start_index_mkt1 FROM lifetime_start) > 0
             AND (SELECT base_start_epoch_mkt1 FROM lifetime_start) IS NOT NULL
             AND EXTRACT(EPOCH FROM NOW())::NUMERIC > (SELECT base_start_epoch_mkt1 FROM lifetime_start)
        THEN
            CASE
                WHEN ABS(
                    COALESCE(CASE WHEN (SELECT is_expired FROM m1) THEN (SELECT final_sy_exchange_rate FROM m1) ELSE (SELECT sy_exchange_rate FROM m1) END, 0) -
                    (SELECT base_start_index_mkt1 FROM lifetime_start)
                ) / NULLIF((SELECT base_start_index_mkt1 FROM lifetime_start), 0) < 0.0001
                THEN 0.00
                ELSE (
                    COALESCE(CASE WHEN (SELECT is_expired FROM m1) THEN (SELECT final_sy_exchange_rate FROM m1) ELSE (SELECT sy_exchange_rate FROM m1) END, 0) /
                    NULLIF((SELECT base_start_index_mkt1 FROM lifetime_start), 0) - 1.0
                ) * (
                    31536000.0 / GREATEST(
                        EXTRACT(EPOCH FROM NOW())::NUMERIC - (SELECT base_start_epoch_mkt1 FROM lifetime_start),
                        3600.0
                    )
                ) * 100
            END
        ELSE NULL
    END::NUMERIC, 2),

    ROUND(CASE
        WHEN (SELECT vault_address FROM m2) IS NULL THEN NULL
        WHEN (SELECT base_start_index_mkt2 FROM lifetime_start) IS NOT NULL
             AND (SELECT base_start_index_mkt2 FROM lifetime_start) > 0
             AND (SELECT base_start_epoch_mkt2 FROM lifetime_start) IS NOT NULL
             AND EXTRACT(EPOCH FROM NOW())::NUMERIC > (SELECT base_start_epoch_mkt2 FROM lifetime_start)
        THEN
            CASE
                WHEN ABS(
                    COALESCE(CASE WHEN (SELECT is_expired FROM m2) THEN (SELECT final_sy_exchange_rate FROM m2) ELSE (SELECT sy_exchange_rate FROM m2) END, 0) -
                    (SELECT base_start_index_mkt2 FROM lifetime_start)
                ) / NULLIF((SELECT base_start_index_mkt2 FROM lifetime_start), 0) < 0.0001
                THEN 0.00
                ELSE (
                    COALESCE(CASE WHEN (SELECT is_expired FROM m2) THEN (SELECT final_sy_exchange_rate FROM m2) ELSE (SELECT sy_exchange_rate FROM m2) END, 0) /
                    NULLIF((SELECT base_start_index_mkt2 FROM lifetime_start), 0) - 1.0
                ) * (
                    31536000.0 / GREATEST(
                        EXTRACT(EPOCH FROM NOW())::NUMERIC - (SELECT base_start_epoch_mkt2 FROM lifetime_start),
                        3600.0
                    )
                ) * 100
            END
        ELSE NULL
    END::NUMERIC, 2),

    -- ─── REALIZED UNDERLYING YIELD — 24h & 7d TRAILING ──────────────
    -- Current rate from mat_exp_last; historical from src_sy_meta_account
    ROUND(CASE
        WHEN (SELECT rate FROM sy_rate_24h_ago) IS NOT NULL
        THEN (
            (COALESCE((SELECT sy_exchange_rate FROM m2), (SELECT sy_exchange_rate FROM m1)) /
             NULLIF((SELECT rate FROM sy_rate_24h_ago), 0) - 1.0
            ) * 365.0 * 100
        )
        ELSE NULL
    END::NUMERIC, 2),

    ROUND(CASE
        WHEN (SELECT rate FROM sy_rate_7d_ago) IS NOT NULL
        THEN (
            (COALESCE((SELECT sy_exchange_rate FROM m2), (SELECT sy_exchange_rate FROM m1)) /
             NULLIF((SELECT rate FROM sy_rate_7d_ago), 0) - 1.0
            ) * (365.0 / 7.0) * 100
        )
        ELSE NULL
    END::NUMERIC, 2),

    -- ─── APY DIVERGENCE ──────────────────────────────────────────────
    ROUND(CASE
        WHEN (SELECT rate FROM sy_rate_24h_ago_mkt1) IS NOT NULL
             AND (SELECT mkt1 FROM simple_apy) IS NOT NULL
        THEN (
            (SELECT mkt1 FROM simple_apy) * 100 -
            ((SELECT sy_exchange_rate FROM m1) /
             NULLIF((SELECT rate FROM sy_rate_24h_ago_mkt1), 0) - 1.0
            ) * 365.0 * 100
        )
        ELSE NULL
    END::NUMERIC, 2),

    ROUND(CASE
        WHEN (SELECT rate FROM sy_rate_24h_ago_mkt2) IS NOT NULL
             AND (SELECT mkt2 FROM simple_apy) IS NOT NULL
        THEN (
            (SELECT mkt2 FROM simple_apy) * 100 -
            ((SELECT sy_exchange_rate FROM m2) /
             NULLIF((SELECT rate FROM sy_rate_24h_ago_mkt2), 0) - 1.0
            ) * 365.0 * 100
        )
        ELSE NULL
    END::NUMERIC, 2),

    ROUND(CASE
        WHEN (SELECT rate FROM sy_rate_7d_ago_mkt1) IS NOT NULL
             AND (SELECT sy_exchange_rate FROM m1) IS NOT NULL
             AND (SELECT mkt1 FROM simple_apy) IS NOT NULL
        THEN (
            (SELECT mkt1 FROM simple_apy) * 100 -
            ((SELECT sy_exchange_rate FROM m1) /
             NULLIF((SELECT rate FROM sy_rate_7d_ago_mkt1), 0) - 1.0
            ) * (365.0 / 7.0) * 100
        )
        ELSE NULL
    END::NUMERIC, 2),

    ROUND(CASE
        WHEN (SELECT rate FROM sy_rate_7d_ago_mkt2) IS NOT NULL
             AND (SELECT sy_exchange_rate FROM m2) IS NOT NULL
             AND (SELECT mkt2 FROM simple_apy) IS NOT NULL
        THEN (
            (SELECT mkt2 FROM simple_apy) * 100 -
            ((SELECT sy_exchange_rate FROM m2) /
             NULLIF((SELECT rate FROM sy_rate_7d_ago_mkt2), 0) - 1.0
            ) * (365.0 / 7.0) * 100
        )
        ELSE NULL
    END::NUMERIC, 2),

    -- ─── DISCOUNT RATES ──────────────────────────────────────────────
    CASE
        WHEN (SELECT maturity_ts FROM m1) < EXTRACT(EPOCH FROM NOW())::INTEGER
        THEN NULL
        ELSE ROUND(COALESCE((SELECT c_market_discount_rate FROM m1) * 100, 0)::NUMERIC, 2)
    END,

    ROUND(CASE
        WHEN (SELECT market_address FROM m2) IS NOT NULL
             AND (SELECT maturity_ts FROM m2) >= EXTRACT(EPOCH FROM NOW())::INTEGER
        THEN (SELECT c_market_discount_rate FROM m2) * 100
        ELSE NULL
    END::NUMERIC, 2),

    -- ─── AMM PRICE IMPACT ────────────────────────────────────────────
    100000,
    100000,  -- DEPRECATED

    ROUND(CASE
        WHEN (SELECT market_address FROM m1) IS NOT NULL
        THEN exponent.get_amm_price_impact((SELECT market_address FROM m1), 100000.0, NULL)
        ELSE NULL
    END::NUMERIC, 2),

    ROUND(CASE
        WHEN (SELECT market_address FROM m2) IS NOT NULL
        THEN exponent.get_amm_price_impact((SELECT market_address FROM m2), 100000.0, NULL)
        ELSE NULL
    END::NUMERIC, 2),

    -- ─── AMM YIELD IMPACT ────────────────────────────────────────────
    ROUND(CASE
        WHEN (SELECT market_address FROM m1) IS NOT NULL
             AND (SELECT maturity_ts FROM m1) >= EXTRACT(EPOCH FROM NOW())::INTEGER
        THEN exponent.get_amm_yield_impact((SELECT market_address FROM m1), 100000.0, NULL)
        ELSE NULL
    END::NUMERIC, 2),

    ROUND(CASE
        WHEN (SELECT market_address FROM m2) IS NOT NULL
             AND (SELECT maturity_ts FROM m2) >= EXTRACT(EPOCH FROM NOW())::INTEGER
        THEN exponent.get_amm_yield_impact((SELECT market_address FROM m2), 100000.0, NULL)
        ELSE NULL
    END::NUMERIC, 2),

    -- ─── SY CLAIMS ───────────────────────────────────────────────────
    -- Already decimal-adjusted in mat_exp_last
    ROUND(COALESCE(
        (SELECT sy_for_pt + treasury_sy + uncollected_sy FROM m1),
        0
    )::NUMERIC, 0),

    ROUND(CASE
        WHEN (SELECT vault_address FROM m2) IS NOT NULL
        THEN (SELECT sy_for_pt + treasury_sy + uncollected_sy FROM m2)
        ELSE NULL
    END::NUMERIC, 0),

    -- Combined PT/YT supply
    ROUND(COALESCE(
        COALESCE((SELECT pt_supply FROM m1), 0) +
        COALESCE((SELECT pt_supply FROM m2), 0),
        0
    )::NUMERIC, 0),

    -- ─── LOCKED eUSX / BASE TOKEN ───────────────────────────────────
    ROUND(COALESCE((SELECT eusx_locked_amt FROM underlying_escrow), 0)::NUMERIC, 0),

    ROUND(COALESCE(
        (SELECT eusx_locked_amt FROM underlying_escrow) /
        NULLIF(
            (SELECT supply FROM sy_supply_shared)::NUMERIC / POW(10, (SELECT decimals_mkt2 FROM decimals_config)),
            0
        ),
        0
    )::NUMERIC, 2),

    -- ─── VAULTS & MARKETS (per market) ──────────────────────────────

    -- Market 1: SY collateralization ratio
    ROUND(COALESCE(
        (SELECT total_sy_in_escrow FROM m1) /
        NULLIF((SELECT sy_for_pt + treasury_sy + uncollected_sy FROM m1), 0),
        0
    )::NUMERIC, 2),

    -- Market 1: AMM depth in SY (decimal-adjusted from mat_exp_last)
    ROUND(COALESCE((SELECT pool_depth_in_sy FROM m1), 0)::NUMERIC, 0),

    -- Market 1: AMM depth in base token terms (PT at underlying price + SY at exchange rate)
    ROUND(COALESCE(
        (SELECT pt_balance FROM m1) * COALESCE((SELECT pt_base_price FROM m1), 1.0) +
        (SELECT sy_balance FROM m1) * COALESCE((SELECT sy_exchange_rate FROM m1), 1.0),
        0
    )::NUMERIC, 0),

    -- Market 1: AMM as % of SY claims
    ROUND(COALESCE(
        (SELECT pool_depth_in_sy FROM m1) /
        NULLIF((SELECT sy_for_pt + treasury_sy + uncollected_sy FROM m1), 0) * 100,
        0
    )::NUMERIC, 1),

    -- Market 1: Vault SY claims as % of AMM
    ROUND(COALESCE(
        (SELECT sy_for_pt + treasury_sy + uncollected_sy FROM m1) /
        NULLIF((SELECT pool_depth_in_sy FROM m1), 0) * 100,
        0
    )::NUMERIC, 1),

    -- Market 1: AMM share of total SY supply
    ROUND(COALESCE(
        (SELECT pool_depth_in_sy FROM m1) /
        NULLIF((SELECT supply FROM sy_supply_shared)::NUMERIC / POW(10, COALESCE((SELECT decimals FROM sy_supply_shared), 6)), 0) * 100,
        0
    )::NUMERIC, 1),

    -- Market 1: YT staked %
    ROUND(COALESCE(
        CASE
            WHEN (SELECT pt_supply FROM m1) > 0
            THEN COALESCE((SELECT yt_escrow_balance FROM m1), 0) /
                 NULLIF((SELECT pt_supply FROM m1), 0) * 100
            ELSE 0
        END,
        0
    )::NUMERIC, 1),

    -- Market 2: SY collateralization ratio
    ROUND(CASE
        WHEN (SELECT vault_address FROM m2) IS NOT NULL
        THEN (SELECT total_sy_in_escrow FROM m2) /
             NULLIF((SELECT sy_for_pt + treasury_sy + uncollected_sy FROM m2), 0)
        ELSE NULL
    END::NUMERIC, 2),

    -- Market 2: AMM depth in SY
    ROUND(CASE
        WHEN (SELECT vault_address FROM m2) IS NOT NULL
        THEN (SELECT pool_depth_in_sy FROM m2)
        ELSE NULL
    END::NUMERIC, 0),

    -- Market 2: AMM depth in base token terms (PT at underlying price + SY at exchange rate)
    ROUND(CASE
        WHEN (SELECT vault_address FROM m2) IS NOT NULL
        THEN (SELECT pt_balance FROM m2) * COALESCE((SELECT pt_base_price FROM m2), 1.0) +
             (SELECT sy_balance FROM m2) * COALESCE((SELECT sy_exchange_rate FROM m2), 1.0)
        ELSE NULL
    END::NUMERIC, 0),

    -- Market 2: AMM as % of SY claims
    ROUND(CASE
        WHEN (SELECT vault_address FROM m2) IS NOT NULL
        THEN (SELECT pool_depth_in_sy FROM m2) /
             NULLIF((SELECT sy_for_pt + treasury_sy + uncollected_sy FROM m2), 0) * 100
        ELSE NULL
    END::NUMERIC, 1),

    -- Market 2: Vault SY claims as % of AMM
    ROUND(CASE
        WHEN (SELECT vault_address FROM m2) IS NOT NULL
        THEN (SELECT sy_for_pt + treasury_sy + uncollected_sy FROM m2) /
             NULLIF((SELECT pool_depth_in_sy FROM m2), 0) * 100
        ELSE NULL
    END::NUMERIC, 1),

    -- Market 2: AMM share of total SY supply
    ROUND(CASE
        WHEN (SELECT vault_address FROM m2) IS NOT NULL
        THEN (SELECT pool_depth_in_sy FROM m2) /
             NULLIF((SELECT supply FROM sy_supply_shared)::NUMERIC / POW(10, COALESCE((SELECT decimals FROM sy_supply_shared), 6)), 0) * 100
        ELSE NULL
    END::NUMERIC, 1),

    -- Market 2: YT staked %
    ROUND(CASE
        WHEN (SELECT vault_address FROM m2) IS NOT NULL AND (SELECT pt_supply FROM m2) > 0
        THEN COALESCE((SELECT yt_escrow_balance FROM m2), 0) /
             NULLIF((SELECT pt_supply FROM m2), 0) * 100
        ELSE NULL
    END::NUMERIC, 1),

    -- ─── ARRAY COLUMNS ───────────────────────────────────────────────

    -- Market PT symbol arrays
    ARRAY[
        (SELECT meta_pt_symbol FROM exponent.aux_key_relations WHERE market_address = (SELECT market_address FROM m1 LIMIT 1) LIMIT 1),
        (SELECT meta_pt_symbol FROM exponent.aux_key_relations WHERE market_address = (SELECT market_address FROM m2 LIMIT 1) LIMIT 1)
    ],

    ARRAY[
        (SELECT meta_pt_name FROM m1),
        (SELECT meta_pt_name FROM m2)
    ],

    (SELECT ARRAY_AGG(DISTINCT meta_pt_name ORDER BY meta_pt_name)
     FROM exponent.aux_key_relations
     WHERE meta_pt_name IS NOT NULL
    ),

    -- Base tokens locked array
    CASE
        WHEN (SELECT base_mint_mkt1 FROM vault_base_tokens) IS NULL
        THEN ARRAY[]::DOUBLE PRECISION[]
        WHEN (SELECT base_mint_mkt2 FROM vault_base_tokens) IS NULL
             OR (SELECT base_mint_mkt2 FROM vault_base_tokens) = (SELECT base_mint_mkt1 FROM vault_base_tokens)
        THEN ARRAY[ROUND((SELECT amount_decimal FROM base_token_escrow_unique WHERE mint = (SELECT base_mint_mkt1 FROM vault_base_tokens))::NUMERIC, 0)::DOUBLE PRECISION]
        ELSE ARRAY[
            ROUND((SELECT amount_decimal FROM base_token_escrow_unique WHERE mint = (SELECT base_mint_mkt1 FROM vault_base_tokens))::NUMERIC, 0)::DOUBLE PRECISION,
            ROUND((SELECT amount_decimal FROM base_token_escrow_unique WHERE mint = (SELECT base_mint_mkt2 FROM vault_base_tokens))::NUMERIC, 0)::DOUBLE PRECISION
        ]
    END,

    -- Total naive TVL
    ROUND(COALESCE((SELECT SUM(amount_decimal) FROM base_token_escrow_unique), 0)::NUMERIC, 0),

    -- Base token symbol arrays
    CASE
        WHEN (SELECT symbol_mkt1 FROM base_token_symbols_by_market) IS NULL
        THEN ARRAY[]::TEXT[]
        WHEN (SELECT symbol_mkt2 FROM base_token_symbols_by_market) IS NULL
             OR (SELECT symbol_mkt2 FROM base_token_symbols_by_market) = (SELECT symbol_mkt1 FROM base_token_symbols_by_market)
        THEN ARRAY[(SELECT symbol_mkt1 FROM base_token_symbols_by_market)]
        ELSE ARRAY[
            (SELECT symbol_mkt1 FROM base_token_symbols_by_market),
            (SELECT symbol_mkt2 FROM base_token_symbols_by_market)
        ]
    END,

    CASE
        WHEN (SELECT symbol_mkt1 FROM base_token_symbols_by_market) IS NULL
        THEN ARRAY[]::TEXT[]
        WHEN (SELECT symbol_mkt2 FROM base_token_symbols_by_market) IS NULL
             OR (SELECT symbol_mkt2 FROM base_token_symbols_by_market) = (SELECT symbol_mkt1 FROM base_token_symbols_by_market)
        THEN ARRAY[(SELECT symbol_mkt1 FROM base_token_symbols_by_market)]
        ELSE ARRAY[
            (SELECT symbol_mkt1 FROM base_token_symbols_by_market),
            (SELECT symbol_mkt2 FROM base_token_symbols_by_market)
        ]
    END,

    -- Base token collateralization ratio array
    CASE
        WHEN (SELECT base_mint_mkt1 FROM vault_base_tokens) IS NULL
        THEN ARRAY[]::DOUBLE PRECISION[]
        WHEN (SELECT base_mint_mkt2 FROM vault_base_tokens) IS NULL
             OR (SELECT base_mint_mkt2 FROM vault_base_tokens) = (SELECT base_mint_mkt1 FROM vault_base_tokens)
        THEN ARRAY[
            ROUND(COALESCE(
                (SELECT amount_decimal FROM base_token_escrow_unique WHERE mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)) /
                NULLIF((SELECT supply_decimal FROM base_token_sy_supply WHERE base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)), 0),
                0
            )::NUMERIC, 2)::DOUBLE PRECISION
        ]
        ELSE ARRAY[
            ROUND(COALESCE(
                (SELECT amount_decimal FROM base_token_escrow_unique WHERE mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)) /
                NULLIF((SELECT supply_decimal FROM base_token_sy_supply WHERE base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)), 0),
                0
            )::NUMERIC, 2)::DOUBLE PRECISION,
            ROUND(COALESCE(
                (SELECT amount_decimal FROM base_token_escrow_unique WHERE mint = (SELECT base_mint_mkt2 FROM vault_base_tokens)) /
                NULLIF((SELECT supply_decimal FROM base_token_sy_supply WHERE base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens)), 0),
                0
            )::NUMERIC, 2)::DOUBLE PRECISION
        ]
    END,

    -- 24h realized APY array
    CASE
        WHEN (SELECT base_mint_mkt1 FROM vault_base_tokens) IS NULL
        THEN ARRAY[]::DOUBLE PRECISION[]
        WHEN (SELECT base_mint_mkt2 FROM vault_base_tokens) IS NULL
             OR (SELECT base_mint_mkt2 FROM vault_base_tokens) = (SELECT base_mint_mkt1 FROM vault_base_tokens)
        THEN ARRAY[
            (SELECT ROUND(apy_24h::NUMERIC, 2)::DOUBLE PRECISION FROM base_token_24h_apy WHERE base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens))
        ]
        ELSE ARRAY[
            (SELECT ROUND(apy_24h::NUMERIC, 2)::DOUBLE PRECISION FROM base_token_24h_apy WHERE base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)),
            (SELECT ROUND(apy_24h::NUMERIC, 2)::DOUBLE PRECISION FROM base_token_24h_apy WHERE base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens))
        ]
    END,

    -- 7d realized APY array
    CASE
        WHEN (SELECT base_mint_mkt1 FROM vault_base_tokens) IS NULL
        THEN ARRAY[]::DOUBLE PRECISION[]
        WHEN (SELECT base_mint_mkt2 FROM vault_base_tokens) IS NULL
             OR (SELECT base_mint_mkt2 FROM vault_base_tokens) = (SELECT base_mint_mkt1 FROM vault_base_tokens)
        THEN ARRAY[
            (SELECT ROUND(apy_7d::NUMERIC, 2)::DOUBLE PRECISION FROM base_token_7d_apy WHERE base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens))
        ]
        ELSE ARRAY[
            (SELECT ROUND(apy_7d::NUMERIC, 2)::DOUBLE PRECISION FROM base_token_7d_apy WHERE base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)),
            (SELECT ROUND(apy_7d::NUMERIC, 2)::DOUBLE PRECISION FROM base_token_7d_apy WHERE base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens))
        ]
    END,

    -- AMM PT trading volume 24h array (from mat_exp_last)
    ARRAY[
        ROUND(COALESCE((SELECT amm_pt_vol_24h FROM m1), 0)::NUMERIC, 0)::DOUBLE PRECISION,
        ROUND(COALESCE((SELECT amm_pt_vol_24h FROM m2), 0)::NUMERIC, 0)::DOUBLE PRECISION
    ],

    -- ─── EXPIRY STATUS ───────────────────────────────────────────────
    CASE
        WHEN (SELECT maturity_ts FROM m1) IS NOT NULL
        THEN (SELECT maturity_ts FROM m1) < EXTRACT(EPOCH FROM NOW())::INTEGER
        ELSE NULL
    END,

    CASE
        WHEN (SELECT maturity_ts FROM m2) IS NOT NULL
        THEN (SELECT maturity_ts FROM m2) < EXTRACT(EPOCH FROM NOW())::INTEGER
        ELSE NULL
    END,

    -- ─── METADATA ────────────────────────────────────────────────────
    NOW(),
    GREATEST(
        COALESCE((SELECT x.slot FROM m1 x), 0),
        COALESCE((SELECT x.slot FROM m2 x), 0)
    );
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION exponent.get_view_exponent_last(TEXT, TEXT) IS
'PFX variant: reads core per-market data from mat_exp_last (mid-level table).
Same output schema as the canonical version. See exponent/dbsql/views/get_view_exponent_last.sql for full documentation.';

-- Wrapper view
CREATE OR REPLACE VIEW exponent.v_exponent_last AS
SELECT * FROM exponent.get_view_exponent_last();

COMMENT ON VIEW exponent.v_exponent_last IS
'Wrapper view for backward compatibility. Calls get_view_exponent_last() with default parameters.';
