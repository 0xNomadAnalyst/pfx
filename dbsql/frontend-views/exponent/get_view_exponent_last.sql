-- NAME: get_view_exponent_last (function) + v_exponent_last (wrapper view)
-- Exponent Last State Function - Dashboard Metrics for Two Markets
--
-- Provides the most recent state for key metrics organized by market (mkt1, mkt2)
--
-- Market Selection Modes:
--   1. DEFAULT (both params NULL): Uses recency-based selection:
--      - mkt2 = vault with HIGHEST maturity_ts (furthest expiry)
--      - mkt1 = vault with NEXT HIGHEST maturity_ts (nearer expiry)
--   2. EXPLICIT (both params provided): Uses meta_pt_name lookup:
--      - mkt1 = vault matching p_mkt1_pt_name in aux_key_relations.meta_pt_name
--      - mkt2 = vault matching p_mkt2_pt_name in aux_key_relations.meta_pt_name
--   3. INVALID (one param NULL, one not): Raises exception
--
-- Metrics include:
--   - SY supply analytics (locked, utilization %)
--   - Maturity analytics (start, end, chart bounds)
--   - Realized underlying yield (annualized from vault life)
--   - Locked eUSX collateralization
--   - Vault & market metrics (collateral ratios, AMM depth, YT staking)
--
-- Usage:
--   - For backward compatibility (default mode): SELECT * FROM exponent.v_exponent_last;
--   - For parameterized access: SELECT * FROM exponent.get_view_exponent_last('PT-USX-09FEB26', 'PT-eUSX-11MAR26');

CREATE OR REPLACE FUNCTION exponent.get_view_exponent_last(
    p_mkt1_pt_name TEXT DEFAULT NULL,  -- Optional: explicit mkt1 selection via meta_pt_name (e.g., 'PT-weUSX-26DEC2025')
    p_mkt2_pt_name TEXT DEFAULT NULL   -- Optional: explicit mkt2 selection via meta_pt_name (e.g., 'PT-weUSX-26JUN2026')
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

    -- ARRAY COLUMNS
    market_pt_symbol_array TEXT[],
    market_pt_symbol_array_full TEXT[],
    market_pt_symbol_array_all TEXT[],  -- All available markets (for dropdowns/selectors)
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
    -- =====================================================
    -- Parameter Validation
    -- =====================================================
    -- Both params must be NULL (default mode) or both must have values (explicit mode)
    -- One NULL + one value is invalid
    IF (p_mkt1_pt_name IS NULL) != (p_mkt2_pt_name IS NULL) THEN
        RAISE EXCEPTION 'Invalid parameters: p_mkt1_pt_name and p_mkt2_pt_name must both be NULL or both have values. Got: p_mkt1_pt_name=%, p_mkt2_pt_name=%',
            COALESCE(p_mkt1_pt_name, 'NULL'), COALESCE(p_mkt2_pt_name, 'NULL');
    END IF;

    RETURN QUERY
    WITH ranked_vaults AS (
        -- Get vault data based on selection mode
        -- DEFAULT MODE (params NULL): rank by maturity_ts descending
        -- EXPLICIT MODE (params provided): filter by meta_pt_name from aux_key_relations
        SELECT
            v.vault_address,
            v.mint_sy,
            v.maturity_ts,
            v.start_ts,
            v.duration,
            v.total_sy_in_escrow,
            v.sy_for_pt,
            v.pt_supply,
            v.treasury_sy,
            v.uncollected_sy,
            v.last_seen_sy_exchange_rate,
            v.time,
            v.slot AS vault_slot,
            CASE
                WHEN p_mkt1_pt_name IS NULL THEN
                    -- Default mode: rank by maturity_ts
                    ROW_NUMBER() OVER (ORDER BY v.maturity_ts DESC)
                ELSE
                    -- Explicit mode: assign ranks based on param match
                    CASE
                        WHEN aux.meta_pt_name = p_mkt2_pt_name THEN 1  -- mkt2
                        WHEN aux.meta_pt_name = p_mkt1_pt_name THEN 2  -- mkt1
                        ELSE NULL
                    END
            END AS maturity_rank,
            CASE
                WHEN p_mkt1_pt_name IS NULL THEN COUNT(*) OVER ()
                ELSE 2  -- In explicit mode, we always have 2 markets (or error)
            END AS total_vaults
        FROM (
            SELECT DISTINCT ON (vault_address)
                vault_address,
                mint_sy,
                maturity_ts,
                start_ts,
                duration,
                total_sy_in_escrow,
                sy_for_pt,
                pt_supply,
                treasury_sy,
                uncollected_sy,
                last_seen_sy_exchange_rate,
                time,
                src_vaults.slot AS slot
            FROM exponent.src_vaults
            ORDER BY vault_address, block_time DESC
        ) v
        LEFT JOIN exponent.aux_key_relations aux ON aux.vault_address = v.vault_address
        WHERE
            -- In explicit mode, only include matching vaults
            p_mkt1_pt_name IS NULL
            OR aux.meta_pt_name IN (p_mkt1_pt_name, p_mkt2_pt_name)
    ),
    vault_mkt2 AS (
        -- Market 2: In default mode = highest maturity_ts (furthest expiry)
        -- In explicit mode = vault matching p_mkt2_pt_name
        -- Only populated if 2+ vaults exist (default mode) or explicit match found
        SELECT * FROM ranked_vaults
        WHERE maturity_rank = 1
          AND (p_mkt1_pt_name IS NOT NULL OR total_vaults >= 2)
    ),
    vault_mkt1 AS (
        -- Market 1: In default mode = next highest maturity_ts (nearer expiry), OR only vault if just one
        -- In explicit mode = vault matching p_mkt1_pt_name
        SELECT * FROM ranked_vaults
        WHERE maturity_rank = CASE
            WHEN p_mkt1_pt_name IS NOT NULL THEN 2  -- Explicit mode: rank 2 is mkt1
            WHEN total_vaults = 1 THEN 1  -- Default mode: only vault gets rank 1
            ELSE 2  -- Default mode: second-ranked vault
        END
    ),
shared_mint_sy AS (
    -- Get the shared mint_sy (both markets use the same SY token)
    -- Use COALESCE to handle cases where one market might not exist
    -- Must be defined early since other CTEs depend on it
    SELECT COALESCE(
        (SELECT mint_sy FROM vault_mkt2 LIMIT 1),
        (SELECT mint_sy FROM vault_mkt1 LIMIT 1),
        (SELECT mint_sy FROM ranked_vaults ORDER BY maturity_rank LIMIT 1)
    ) AS mint_sy
),
market_mkt2 AS (
    -- Get latest market data for mkt2
    SELECT DISTINCT ON (vault_address)
        vault_address,
        market_address,
        sy_balance,
        c_total_market_depth_in_sy,
        c_implied_apy,
        c_implied_pt_price,
        c_discount_rate,
        meta_pt_symbol,
        meta_pt_name,
        meta_base_mint
    FROM exponent.src_market_twos
    WHERE vault_address = (SELECT vault_address FROM vault_mkt2 LIMIT 1)
    ORDER BY vault_address, block_time DESC
),
market_mkt1 AS (
    -- Get latest market data for mkt1
    SELECT DISTINCT ON (vault_address)
        vault_address,
        market_address,
        sy_balance,
        c_total_market_depth_in_sy,
        c_implied_apy,
        c_implied_pt_price,
        c_discount_rate,
        meta_pt_symbol,
        meta_pt_name,
        meta_base_mint
    FROM exponent.src_market_twos
    WHERE vault_address = (SELECT vault_address FROM vault_mkt1 LIMIT 1)
    ORDER BY vault_address, block_time DESC
),
latest_sy_token_accounts AS (
    -- Precompute latest SY token account row per mint_sy for reuse.
    SELECT DISTINCT ON (st.mint_sy)
        st.mint_sy,
        st.supply,
        st.decimals,
        st.meta_base_mint,
        st.time
    FROM exponent.src_sy_token_account st
    ORDER BY st.mint_sy, st.time DESC
),
sy_token_supply_eusx AS (
    -- Get latest SY token supply for eUSX base token
    SELECT
        mint_sy,
        supply,
        decimals
    FROM latest_sy_token_accounts
    WHERE meta_base_mint = '3ThdFZQKM6kRyVGLG48kaPg5TRMhYMKY1iCRa9xop1WC'
),
sy_token_supply_usx AS (
    -- Get latest SY token supply for USX base token
    SELECT
        mint_sy,
        supply,
        decimals
    FROM latest_sy_token_accounts
    WHERE meta_base_mint = '6FrrzDk5mQARGc1TDYoyVnSyRdds1t4PbtohCD6p3tgG'
),
sy_meta_eusx_latest AS (
    -- Get latest SY exchange rate for eUSX base token
    SELECT DISTINCT ON (mint_sy)
        mint_sy,
        sy_exchange_rate
    FROM exponent.src_sy_meta_account
    WHERE meta_base_mint = '3ThdFZQKM6kRyVGLG48kaPg5TRMhYMKY1iCRa9xop1WC'
    ORDER BY mint_sy, time DESC
),
sy_token_supply_combined AS (
    -- Combined SY token supply in USX terms (assuming 1:1 eUSX:USX convertibility)
    -- Sum of: sy_usx (in USX) + sy_eusx (in eUSX, converted to USX via exchange rate)
    SELECT
        COALESCE(SUM(supply) FILTER (WHERE base_mint = '6FrrzDk5mQARGc1TDYoyVnSyRdds1t4PbtohCD6p3tgG'), 0) AS sy_usx_supply_raw,
        COALESCE(SUM(supply) FILTER (WHERE base_mint = '3ThdFZQKM6kRyVGLG48kaPg5TRMhYMKY1iCRa9xop1WC'), 0) AS sy_eusx_supply_raw,
        COALESCE(MAX(decimals) FILTER (WHERE base_mint = '6FrrzDk5mQARGc1TDYoyVnSyRdds1t4PbtohCD6p3tgG'), 6) AS sy_usx_decimals,
        COALESCE(MAX(decimals) FILTER (WHERE base_mint = '3ThdFZQKM6kRyVGLG48kaPg5TRMhYMKY1iCRa9xop1WC'), 6) AS sy_eusx_decimals,
        -- Total supply in USX terms: sy_usx + (sy_eusx * price_eusx_per_sy)
        -- price_eusx_per_sy = 1 / sy_exchange_rate
        COALESCE(SUM(supply) FILTER (WHERE base_mint = '6FrrzDk5mQARGc1TDYoyVnSyRdds1t4PbtohCD6p3tgG'), 0) +
        COALESCE(
            SUM(supply) FILTER (WHERE base_mint = '3ThdFZQKM6kRyVGLG48kaPg5TRMhYMKY1iCRa9xop1WC') *
            (1.0 / NULLIF(MAX(exchange_rate) FILTER (WHERE base_mint = '3ThdFZQKM6kRyVGLG48kaPg5TRMhYMKY1iCRa9xop1WC'), 0)),
            0
        ) AS sy_total_supply_raw_usx_terms
    FROM (
        SELECT
            st.mint_sy,
            st.supply,
            st.decimals,
            st.meta_base_mint AS base_mint,
            sm.sy_exchange_rate AS exchange_rate
        FROM latest_sy_token_accounts st
        LEFT JOIN sy_meta_eusx_latest sm ON st.mint_sy = sm.mint_sy
        WHERE st.meta_base_mint IN ('3ThdFZQKM6kRyVGLG48kaPg5TRMhYMKY1iCRa9xop1WC', '6FrrzDk5mQARGc1TDYoyVnSyRdds1t4PbtohCD6p3tgG')
    ) sy_with_meta
),
sy_token_supply AS (
    -- Legacy compatibility: get supply for shared_mint_sy (for backward compatibility with other CTEs)
    -- This is used for market-specific calculations that don't need cross-vault aggregation
    SELECT
        mint_sy,
        supply
    FROM latest_sy_token_accounts
    WHERE mint_sy = (SELECT mint_sy FROM shared_mint_sy)
),
vault_base_tokens AS (
    -- Get base token (meta_base_mint) for each market's vault
    SELECT
        (SELECT meta_base_mint FROM exponent.src_vaults
         WHERE vault_address = (SELECT vault_address FROM vault_mkt1 LIMIT 1)
         ORDER BY block_time DESC LIMIT 1) AS base_mint_mkt1,
        (SELECT meta_base_mint FROM exponent.src_vaults
         WHERE vault_address = (SELECT vault_address FROM vault_mkt2 LIMIT 1)
         ORDER BY block_time DESC LIMIT 1) AS base_mint_mkt2
),
market_locked_sy_usx_terms AS (
    -- Convert each market's locked SY to USX terms for percentage calculations
    -- Market 1: convert to USX terms if eUSX-based (using market's specific SY exchange rate)
    SELECT
        CASE
            WHEN (SELECT base_mint_mkt1 FROM vault_base_tokens) = '3ThdFZQKM6kRyVGLG48kaPg5TRMhYMKY1iCRa9xop1WC'
            THEN ((SELECT total_sy_in_escrow FROM vault_mkt1) + (SELECT sy_balance FROM market_mkt1)) *
                 (1.0 / NULLIF((
                     SELECT sy_exchange_rate
                     FROM exponent.src_sy_meta_account
                     WHERE mint_sy = (SELECT mint_sy FROM vault_mkt1 LIMIT 1)
                     ORDER BY time DESC LIMIT 1
                 ), 0))
            ELSE ((SELECT total_sy_in_escrow FROM vault_mkt1) + (SELECT sy_balance FROM market_mkt1))
        END AS locked_usx_terms_mkt1,
        -- Market 2: convert to USX terms if eUSX-based (using market's specific SY exchange rate)
        CASE
            WHEN (SELECT base_mint_mkt2 FROM vault_base_tokens) = '3ThdFZQKM6kRyVGLG48kaPg5TRMhYMKY1iCRa9xop1WC'
            THEN ((SELECT total_sy_in_escrow FROM vault_mkt2) + (SELECT sy_balance FROM market_mkt2)) *
                 (1.0 / NULLIF((
                     SELECT sy_exchange_rate
                     FROM exponent.src_sy_meta_account
                     WHERE mint_sy = (SELECT mint_sy FROM vault_mkt2 LIMIT 1)
                     ORDER BY time DESC LIMIT 1
                 ), 0))
            ELSE ((SELECT total_sy_in_escrow FROM vault_mkt2) + (SELECT sy_balance FROM market_mkt2))
        END AS locked_usx_terms_mkt2
),
decimals_config AS (
    -- Get token decimals for both markets from aux_key_relations
    -- Fallback chain: env_sy_decimals -> meta_sy_decimals -> 6 (default for USX/eUSX)
    -- When mkt2 doesn't exist, fall back to mkt1 decimals (both use same SY token)
    SELECT
        COALESCE(
            (SELECT env_sy_decimals FROM exponent.aux_key_relations WHERE vault_address = (SELECT vault_address FROM vault_mkt1 LIMIT 1)),
            (SELECT meta_sy_decimals FROM exponent.aux_key_relations WHERE vault_address = (SELECT vault_address FROM vault_mkt1 LIMIT 1)),
            6
        ) AS decimals_mkt1,
        COALESCE(
            (SELECT env_sy_decimals FROM exponent.aux_key_relations WHERE vault_address = (SELECT vault_address FROM vault_mkt2 LIMIT 1)),
            (SELECT meta_sy_decimals FROM exponent.aux_key_relations WHERE vault_address = (SELECT vault_address FROM vault_mkt2 LIMIT 1)),
            (SELECT env_sy_decimals FROM exponent.aux_key_relations WHERE vault_address = (SELECT vault_address FROM vault_mkt1 LIMIT 1)),
            (SELECT meta_sy_decimals FROM exponent.aux_key_relations WHERE vault_address = (SELECT vault_address FROM vault_mkt1 LIMIT 1)),
            6
        ) AS decimals_mkt2
),
lifetime_config AS (
    -- Lifetime APY baseline overrides from config/env
    -- Read directly from src_sy_meta_account (latest values) using market-specific base tokens
    -- Each market may have different base tokens, so get config separately for each
    SELECT
        (SELECT env_sy_lifetime_apy_start_date FROM exponent.src_sy_meta_account WHERE meta_base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens) ORDER BY time DESC LIMIT 1) AS env_start_date_mkt1,
        (SELECT env_sy_lifetime_apy_start_index FROM exponent.src_sy_meta_account WHERE meta_base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens) ORDER BY time DESC LIMIT 1) AS env_start_index_mkt1,
        (SELECT env_sy_lifetime_apy_start_date FROM exponent.src_sy_meta_account WHERE meta_base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens) ORDER BY time DESC LIMIT 1) AS env_start_date_mkt2,
        (SELECT env_sy_lifetime_apy_start_index FROM exponent.src_sy_meta_account WHERE meta_base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens) ORDER BY time DESC LIMIT 1) AS env_start_index_mkt2
),
sy_meta_mkt2 AS (
    -- Get SY meta account data for mkt2 (for yield calculation)
    -- Filter by market-specific base token (meta_base_mint) from vault
    SELECT
        mint_sy,
        time,
        sy_exchange_rate,
        EXTRACT(EPOCH FROM time)::INTEGER AS time_epoch
    FROM exponent.src_sy_meta_account
    WHERE meta_base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens)
),
sy_meta_start_mkt2 AS (
    -- Get SY exchange rate at vault start (mkt2)
    -- Returns the earliest available SY meta record (may be after vault start if polling started late)
    SELECT
        sy_exchange_rate AS start_rate,
        time AS start_time,
        time_epoch AS start_epoch
    FROM sy_meta_mkt2
    ORDER BY
        CASE
            WHEN COALESCE((SELECT start_ts FROM vault_mkt2 LIMIT 1), time_epoch) <= time_epoch THEN 0
            ELSE 1
        END,
        time_epoch ASC
    LIMIT 1
),
sy_meta_end_mkt2 AS (
    -- Get SY exchange rate at end or now (mkt2) with fallback to latest available value
    SELECT COALESCE(
        (
            SELECT sy_exchange_rate
            FROM sy_meta_mkt2
            WHERE time_epoch <= LEAST(
                COALESCE((SELECT maturity_ts FROM vault_mkt2 LIMIT 1), EXTRACT(EPOCH FROM NOW())::INTEGER),
                EXTRACT(EPOCH FROM NOW())::INTEGER
            )
            ORDER BY time_epoch DESC
            LIMIT 1
        ),
        (
            SELECT sy_exchange_rate
            FROM sy_meta_mkt2
            ORDER BY time_epoch DESC
            LIMIT 1
        )
    ) AS end_rate
),
sy_meta_mkt1 AS (
    -- Get SY meta account data for mkt1 (for yield calculation)
    -- Filter by market-specific base token (meta_base_mint) from vault
    SELECT
        mint_sy,
        time,
        sy_exchange_rate,
        EXTRACT(EPOCH FROM time)::INTEGER AS time_epoch
    FROM exponent.src_sy_meta_account
    WHERE meta_base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)
),
sy_meta_start_mkt1 AS (
    -- Get SY exchange rate at vault start (mkt1)
    -- Returns the earliest available SY meta record (may be after vault start if polling started late)
    SELECT
        sy_exchange_rate AS start_rate,
        time AS start_time,
        time_epoch AS start_epoch
    FROM sy_meta_mkt1
    ORDER BY
        CASE
            WHEN COALESCE((SELECT start_ts FROM vault_mkt1 LIMIT 1), time_epoch) <= time_epoch THEN 0
            ELSE 1
        END,
        time_epoch ASC
    LIMIT 1
),
sy_meta_end_mkt1 AS (
    -- Get SY exchange rate at end or now (mkt1) with fallback to latest available value
    SELECT COALESCE(
        (
            SELECT sy_exchange_rate
            FROM sy_meta_mkt1
            WHERE time_epoch <= LEAST(
                COALESCE((SELECT maturity_ts FROM vault_mkt1 LIMIT 1), EXTRACT(EPOCH FROM NOW())::INTEGER),
                EXTRACT(EPOCH FROM NOW())::INTEGER
            )
            ORDER BY time_epoch DESC
            LIMIT 1
        ),
        (
            SELECT sy_exchange_rate
            FROM sy_meta_mkt1
            ORDER BY time_epoch DESC
            LIMIT 1
        )
    ) AS end_rate
),
lifetime_start AS (
    -- Determine baseline start timestamp and exchange rate for lifetime APY calculations
    -- When config override exists but we lack data from that date, extrapolate backwards
    -- using the observed growth rate from earliest data to estimate the starting index
    SELECT
        base_values.base_start_ts_mkt1,
        base_values.base_start_index_mkt1,
        CASE WHEN base_values.base_start_ts_mkt1 IS NOT NULL
             THEN EXTRACT(EPOCH FROM base_values.base_start_ts_mkt1)
             ELSE NULL
        END AS base_start_epoch_mkt1,
        base_values.base_start_ts_mkt2,
        base_values.base_start_index_mkt2,
        CASE WHEN base_values.base_start_ts_mkt2 IS NOT NULL
             THEN EXTRACT(EPOCH FROM base_values.base_start_ts_mkt2)
             ELSE NULL
        END AS base_start_epoch_mkt2
    FROM (
        SELECT
            -- Market 1 baseline timestamp
            CASE
                -- If vault start is after or at earliest SY data, use earliest SY data timestamp
                WHEN (SELECT start_ts FROM vault_mkt1 LIMIT 1) >= (SELECT start_epoch FROM sy_meta_start_mkt1)
                THEN (SELECT start_time FROM sy_meta_start_mkt1)
                -- If config exists and we're extrapolating, use vault start timestamp
                WHEN lc.env_start_date_mkt1 IS NOT NULL
                     AND lc.env_start_index_mkt1 IS NOT NULL
                     AND lc.env_start_index_mkt1 > 0
                     AND (SELECT start_ts FROM vault_mkt1 LIMIT 1) IS NOT NULL
                     AND (SELECT start_epoch FROM sy_meta_start_mkt1) > (SELECT start_ts FROM vault_mkt1 LIMIT 1)
                THEN to_timestamp((SELECT start_ts FROM vault_mkt1 LIMIT 1))
                -- Otherwise use earliest SY meta timestamp
                ELSE (SELECT start_time FROM sy_meta_start_mkt1)
            END AS base_start_ts_mkt1,

            -- Market 1 baseline index (with backward extrapolation if needed)
            CASE
                -- If vault start is after or at earliest SY data, no extrapolation needed
                WHEN (SELECT start_ts FROM vault_mkt1 LIMIT 1) >= (SELECT start_epoch FROM sy_meta_start_mkt1)
                THEN (SELECT start_rate FROM sy_meta_start_mkt1)
                -- If config exists and vault start is between config date and first observation,
                -- extrapolate from first observation back to vault start
                WHEN lc.env_start_date_mkt1 IS NOT NULL
                     AND lc.env_start_index_mkt1 IS NOT NULL
                     AND lc.env_start_index_mkt1 > 0
                     AND (SELECT start_ts FROM vault_mkt1 LIMIT 1) IS NOT NULL
                     AND (SELECT start_epoch FROM sy_meta_start_mkt1) > (SELECT start_ts FROM vault_mkt1 LIMIT 1)
                THEN (
                    -- Extrapolate backwards from first observation to vault start
                    -- Using growth rate from config baseline to first observation
                    -- Formula: observed_rate / (growth_factor ^ gap_fraction)
                    -- where growth_factor = observed_rate / config_baseline
                    -- and gap_fraction = (vault_start to first_obs) / (config_baseline to first_obs)
                    (SELECT start_rate FROM sy_meta_start_mkt1) / NULLIF(
                        POWER(
                            (SELECT start_rate FROM sy_meta_start_mkt1) / NULLIF(lc.env_start_index_mkt1, 0),
                            (
                                ((SELECT start_epoch FROM sy_meta_start_mkt1) - (SELECT start_ts FROM vault_mkt1 LIMIT 1))::DOUBLE PRECISION /
                                NULLIF(((SELECT start_epoch FROM sy_meta_start_mkt1) - EXTRACT(EPOCH FROM lc.env_start_date_mkt1)::INTEGER)::DOUBLE PRECISION, 0)
                            )
                        ),
                        0
                    )
                )
                -- Otherwise use earliest observed rate
                ELSE (SELECT start_rate FROM sy_meta_start_mkt1)
            END AS base_start_index_mkt1,

            -- Market 2 baseline timestamp
            CASE
                -- If vault start is after or at earliest SY data, use earliest SY data timestamp
                WHEN (SELECT start_ts FROM vault_mkt2 LIMIT 1) >= (SELECT start_epoch FROM sy_meta_start_mkt2)
                THEN (SELECT start_time FROM sy_meta_start_mkt2)
                -- If config exists and we're extrapolating, use vault start timestamp
                WHEN lc.env_start_date_mkt2 IS NOT NULL
                     AND lc.env_start_index_mkt2 IS NOT NULL
                     AND lc.env_start_index_mkt2 > 0
                     AND (SELECT start_ts FROM vault_mkt2 LIMIT 1) IS NOT NULL
                     AND (SELECT start_epoch FROM sy_meta_start_mkt2) > (SELECT start_ts FROM vault_mkt2 LIMIT 1)
                THEN to_timestamp((SELECT start_ts FROM vault_mkt2 LIMIT 1))
                -- Otherwise use earliest SY meta timestamp
                ELSE (SELECT start_time FROM sy_meta_start_mkt2)
            END AS base_start_ts_mkt2,

            -- Market 2 baseline index (with backward extrapolation if needed)
            CASE
                -- If vault start is after or at earliest SY data, no extrapolation needed
                WHEN (SELECT start_ts FROM vault_mkt2 LIMIT 1) >= (SELECT start_epoch FROM sy_meta_start_mkt2)
                THEN (SELECT start_rate FROM sy_meta_start_mkt2)
                -- If config exists and vault start is between config date and first observation,
                -- extrapolate from first observation back to vault start
                WHEN lc.env_start_date_mkt2 IS NOT NULL
                     AND lc.env_start_index_mkt2 IS NOT NULL
                     AND lc.env_start_index_mkt2 > 0
                     AND (SELECT start_ts FROM vault_mkt2 LIMIT 1) IS NOT NULL
                     AND (SELECT start_epoch FROM sy_meta_start_mkt2) > (SELECT start_ts FROM vault_mkt2 LIMIT 1)
                THEN (
                    -- Extrapolate backwards from first observation to vault start
                    -- Using growth rate from config baseline to first observation
                    -- Formula: observed_rate / (growth_factor ^ gap_fraction)
                    -- where growth_factor = observed_rate / config_baseline
                    -- and gap_fraction = (vault_start to first_obs) / (config_baseline to first_obs)
                    (SELECT start_rate FROM sy_meta_start_mkt2) / NULLIF(
                        POWER(
                            (SELECT start_rate FROM sy_meta_start_mkt2) / NULLIF(lc.env_start_index_mkt2, 0),
                            (
                                ((SELECT start_epoch FROM sy_meta_start_mkt2) - (SELECT start_ts FROM vault_mkt2 LIMIT 1))::DOUBLE PRECISION /
                                NULLIF(((SELECT start_epoch FROM sy_meta_start_mkt2) - EXTRACT(EPOCH FROM lc.env_start_date_mkt2)::INTEGER)::DOUBLE PRECISION, 0)
                            )
                        ),
                        0
                    )
                )
                -- Otherwise use earliest observed rate
                ELSE (SELECT start_rate FROM sy_meta_start_mkt2)
            END AS base_start_index_mkt2
        FROM lifetime_config lc
    ) AS base_values
),
yt_escrow_mkt2 AS (
    -- Get latest YT escrow data for mkt2
    SELECT DISTINCT ON (vault)
        vault,
        amount AS yt_balance
    FROM exponent.src_vault_yt_escrow
    WHERE vault = (SELECT vault_address FROM vault_mkt2 LIMIT 1)
    ORDER BY vault, time DESC
),
yt_escrow_mkt1 AS (
    -- Get latest YT escrow data for mkt1
    SELECT DISTINCT ON (vault)
        vault,
        amount AS yt_balance
    FROM exponent.src_vault_yt_escrow
    WHERE vault = (SELECT vault_address FROM vault_mkt1 LIMIT 1)
    ORDER BY vault, time DESC
),
underlying_escrow AS (
    -- Get latest underlying token escrow balance (eUSX locked)
    -- Assumes single escrow for the SY mint
    SELECT DISTINCT ON (mint)
        mint,
        (amount::DOUBLE PRECISION / NULLIF(POWER(10::DOUBLE PRECISION, COALESCE(akr.env_sy_decimals )), 0.0)) AS eusx_locked_amt
    FROM exponent.src_base_token_escrow AS ute
    LEFT JOIN exponent.aux_key_relations AS akr
        ON akr.underlying_escrow_address = ute.escrow_address
    WHERE mint IN (
        SELECT DISTINCT yield_bearing_mint
        FROM exponent.src_sy_meta_account
        WHERE mint_sy = (SELECT mint_sy FROM shared_mint_sy)
        LIMIT 1
    )
    ORDER BY mint, ute.time DESC
),
base_token_escrow_mkt1 AS (
    -- Get latest base token escrow balance for mkt1
    SELECT DISTINCT ON (mint)
        mint,
        amount,
        (amount::DOUBLE PRECISION / NULLIF(POWER(10::DOUBLE PRECISION, COALESCE(meta_base_decimals, 6)), 0.0)) AS amount_decimal
    FROM exponent.src_base_token_escrow
    WHERE mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)
    ORDER BY mint, time DESC
),
base_token_escrow_mkt2 AS (
    -- Get latest base token escrow balance for mkt2
    SELECT DISTINCT ON (mint)
        mint,
        amount,
        (amount::DOUBLE PRECISION / NULLIF(POWER(10::DOUBLE PRECISION, COALESCE(meta_base_decimals, 6)), 0.0)) AS amount_decimal
    FROM exponent.src_base_token_escrow
    WHERE mint = (SELECT base_mint_mkt2 FROM vault_base_tokens)
    ORDER BY mint, time DESC
),
base_token_escrow_unique AS (
    -- Get unique base token escrows (if both markets share same base token, only one row)
    SELECT DISTINCT ON (mint)
        mint,
        amount,
        meta_base_symbol,
        (amount::DOUBLE PRECISION / NULLIF(POWER(10::DOUBLE PRECISION, COALESCE(meta_base_decimals, 6)), 0.0)) AS amount_decimal
    FROM exponent.src_base_token_escrow
    WHERE mint IN (
        (SELECT base_mint_mkt1 FROM vault_base_tokens),
        (SELECT base_mint_mkt2 FROM vault_base_tokens)
    )
    ORDER BY mint, time DESC
),
base_token_sy_supply AS (
    -- Get SY token supply for each unique base token
    -- Get latest supply for each SY token that matches the base tokens
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
    -- Get base token symbols mapped to each market (mkt1, mkt2)
    -- Returns symbols in market order, with only unique values if both markets share same base token
    SELECT
        (SELECT meta_base_symbol FROM base_token_escrow_unique WHERE mint = (SELECT base_mint_mkt1 FROM vault_base_tokens) LIMIT 1) AS symbol_mkt1,
        (SELECT meta_base_symbol FROM base_token_escrow_unique WHERE mint = (SELECT base_mint_mkt2 FROM vault_base_tokens) LIMIT 1) AS symbol_mkt2
),
sy_meta_trailing AS (
    -- Get SY meta data for trailing APY calculations (24h, 7d) - general/legacy
    -- Uses shared_mint_sy for backward compatibility
    SELECT
        mint_sy,
        time,
        sy_exchange_rate
    FROM exponent.src_sy_meta_account
    WHERE mint_sy = (SELECT mint_sy FROM shared_mint_sy)
      AND time >= NOW() - INTERVAL '8 days'  -- Need extra for 7d lookback
),
sy_meta_trailing_mkt1 AS (
    -- Get SY meta data for trailing APY calculations (24h) for mkt1
    -- Filter by market-specific base token (meta_base_mint) from vault
    SELECT
        mint_sy,
        time,
        sy_exchange_rate
    FROM exponent.src_sy_meta_account
    WHERE meta_base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)
      AND time >= NOW() - INTERVAL '8 days'  -- Need extra for 7d lookback
),
sy_meta_trailing_mkt2 AS (
    -- Get SY meta data for trailing APY calculations (24h) for mkt2
    -- Filter by market-specific base token (meta_base_mint) from vault
    SELECT
        mint_sy,
        time,
        sy_exchange_rate
    FROM exponent.src_sy_meta_account
    WHERE meta_base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens)
      AND time >= NOW() - INTERVAL '8 days'  -- Need extra for 7d lookback
),
sy_meta_now AS (
    -- Current SY exchange rate (general/legacy)
    SELECT sy_exchange_rate AS rate_now
    FROM sy_meta_trailing
    ORDER BY time DESC
    LIMIT 1
),
sy_meta_now_mkt1 AS (
    -- Current SY exchange rate for mkt1
    SELECT sy_exchange_rate AS rate_now
    FROM sy_meta_trailing_mkt1
    ORDER BY time DESC
    LIMIT 1
),
sy_meta_now_mkt2 AS (
    -- Current SY exchange rate for mkt2
    SELECT sy_exchange_rate AS rate_now
    FROM sy_meta_trailing_mkt2
    ORDER BY time DESC
    LIMIT 1
),
sy_meta_24h_ago AS (
    -- SY exchange rate from 24 hours ago (general/legacy)
    -- Returns NULL if no data from >= 24h ago exists (ensures full window for accurate APY)
    SELECT
        sy_exchange_rate AS rate_24h_ago,
        time AS time_24h_ago
    FROM sy_meta_trailing
    WHERE time <= NOW() - INTERVAL '24 hours'
    ORDER BY time DESC  -- Most recent data from 24h+ ago
    LIMIT 1
),
sy_meta_24h_ago_mkt1 AS (
    -- SY exchange rate from 24 hours ago for mkt1
    -- Returns NULL if no data from >= 24h ago exists (ensures full window for accurate APY)
    SELECT
        sy_exchange_rate AS rate_24h_ago,
        time AS time_24h_ago
    FROM sy_meta_trailing_mkt1
    WHERE time <= NOW() - INTERVAL '24 hours'
    ORDER BY time DESC  -- Most recent data from 24h+ ago
    LIMIT 1
),
sy_meta_24h_ago_mkt2 AS (
    -- SY exchange rate from 24 hours ago for mkt2
    -- Returns NULL if no data from >= 24h ago exists (ensures full window for accurate APY)
    SELECT
        sy_exchange_rate AS rate_24h_ago,
        time AS time_24h_ago
    FROM sy_meta_trailing_mkt2
    WHERE time <= NOW() - INTERVAL '24 hours'
    ORDER BY time DESC  -- Most recent data from 24h+ ago
    LIMIT 1
),
sy_meta_7d_ago AS (
    -- SY exchange rate 7 days ago (general/legacy)
    SELECT sy_exchange_rate AS rate_7d_ago
    FROM sy_meta_trailing
    WHERE time <= NOW() - INTERVAL '7 days'
    ORDER BY time DESC
    LIMIT 1
),
sy_meta_7d_ago_mkt1 AS (
    -- SY exchange rate from 7d lookback window for mkt1
    SELECT
        sy_exchange_rate AS rate_7d_ago,
        time AS time_7d_ago
    FROM sy_meta_trailing_mkt1
    WHERE time <= NOW() - INTERVAL '7 days'
    ORDER BY time DESC
    LIMIT 1
),
sy_meta_7d_ago_mkt2 AS (
    -- SY exchange rate from 7d lookback window for mkt2
    SELECT
        sy_exchange_rate AS rate_7d_ago,
        time AS time_7d_ago
    FROM sy_meta_trailing_mkt2
    WHERE time <= NOW() - INTERVAL '7 days'
    ORDER BY time DESC
    LIMIT 1
),
base_token_24h_apy AS (
    -- Calculate 24h realized APY for each unique base token
    -- If both markets share same base token, only one calculation is done
    -- NOTE: Returns NULL until there is a full 24h window of data
    SELECT DISTINCT ON (base_mint)
        base_mint,
        CASE
            -- Use mkt1 data if base_mint matches mkt1
            WHEN base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)
                 AND (SELECT rate_24h_ago FROM sy_meta_24h_ago_mkt1) IS NOT NULL
                 AND (SELECT rate_now FROM sy_meta_now_mkt1) IS NOT NULL
            THEN (
                (
                    (SELECT rate_now FROM sy_meta_now_mkt1) /
                    NULLIF((SELECT rate_24h_ago FROM sy_meta_24h_ago_mkt1), 0) - 1.0
                ) * 365.0 * 100  -- Fixed 24h annualization
            )
            -- Use mkt2 data if base_mint matches mkt2 (and not mkt1)
            WHEN base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens)
                 AND base_mint != COALESCE((SELECT base_mint_mkt1 FROM vault_base_tokens), '')
                 AND (SELECT rate_24h_ago FROM sy_meta_24h_ago_mkt2) IS NOT NULL
                 AND (SELECT rate_now FROM sy_meta_now_mkt2) IS NOT NULL
            THEN (
                (
                    (SELECT rate_now FROM sy_meta_now_mkt2) /
                    NULLIF((SELECT rate_24h_ago FROM sy_meta_24h_ago_mkt2), 0) - 1.0
                ) * 365.0 * 100  -- Fixed 24h annualization
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
    -- Calculate 7d realized APY for each unique base token
    -- If both markets share same base token, only one calculation is done
    SELECT DISTINCT ON (base_mint)
        base_mint,
        CASE
            -- Use mkt1 data if base_mint matches mkt1
            WHEN base_mint = (SELECT base_mint_mkt1 FROM vault_base_tokens)
                 AND (SELECT rate_7d_ago FROM sy_meta_7d_ago_mkt1) IS NOT NULL
                 AND (SELECT rate_now FROM sy_meta_now_mkt1) IS NOT NULL
            THEN (
                (
                    (SELECT rate_now FROM sy_meta_now_mkt1) /
                    NULLIF((SELECT rate_7d_ago FROM sy_meta_7d_ago_mkt1), 0) - 1.0
                ) * (365.0 / 7.0) * 100
            )
            -- Use mkt2 data if base_mint matches mkt2 (and not mkt1)
            WHEN base_mint = (SELECT base_mint_mkt2 FROM vault_base_tokens)
                 AND base_mint != COALESCE((SELECT base_mint_mkt1 FROM vault_base_tokens), '')
                 AND (SELECT rate_7d_ago FROM sy_meta_7d_ago_mkt2) IS NOT NULL
                 AND (SELECT rate_now FROM sy_meta_now_mkt2) IS NOT NULL
            THEN (
                (
                    (SELECT rate_now FROM sy_meta_now_mkt2) /
                    NULLIF((SELECT rate_7d_ago FROM sy_meta_7d_ago_mkt2), 0) - 1.0
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
amm_pt_volume_24h AS (
    -- Calculate 24h PT trading volume per market from CAGG
    -- Volume = sum of PT in + PT out (both directions count as volume)
    SELECT
        market_address,
        SUM(COALESCE(amount_amm_pt_in, 0) + COALESCE(amount_amm_pt_out, 0)) AS pt_volume_24h
    FROM exponent.cagg_tx_events_5s
    WHERE event_type = 'trade_pt'
      AND market_address IS NOT NULL
      AND bucket_time >= NOW() - INTERVAL '24 hours'
    GROUP BY market_address
),
simple_apy AS (
    -- Simple (linear) annualized implied APY from PT price, matching Exponent web convention.
    -- Formula: (1/ptPrice - 1) / tte_years
    -- This replaces the continuously compounded exp(ln_implied_rate)-1 which overstates
    -- short-dated yields vs the simple annualization the Exponent UI uses.
    SELECT
        CASE
            WHEN (SELECT c_implied_pt_price FROM market_mkt1) IS NOT NULL
                 AND (SELECT c_implied_pt_price FROM market_mkt1) > 0
                 AND (SELECT c_implied_pt_price FROM market_mkt1) < 1.0
                 AND (SELECT maturity_ts FROM vault_mkt1) > EXTRACT(EPOCH FROM NOW())::INTEGER
            THEN (
                (1.0 / (SELECT c_implied_pt_price FROM market_mkt1) - 1.0) /
                GREATEST(
                    ((SELECT maturity_ts FROM vault_mkt1)::NUMERIC - EXTRACT(EPOCH FROM NOW())::NUMERIC) / 31536000.0,
                    1.0 / 365.0
                )
            )
            ELSE NULL
        END AS mkt1,
        CASE
            WHEN (SELECT c_implied_pt_price FROM market_mkt2) IS NOT NULL
                 AND (SELECT c_implied_pt_price FROM market_mkt2) > 0
                 AND (SELECT c_implied_pt_price FROM market_mkt2) < 1.0
                 AND (SELECT maturity_ts FROM vault_mkt2) > EXTRACT(EPOCH FROM NOW())::INTEGER
            THEN (
                (1.0 / (SELECT c_implied_pt_price FROM market_mkt2) - 1.0) /
                GREATEST(
                    ((SELECT maturity_ts FROM vault_mkt2)::NUMERIC - EXTRACT(EPOCH FROM NOW())::NUMERIC) / 31536000.0,
                    1.0 / 365.0
                )
            )
            ELSE NULL
        END AS mkt2
)
SELECT
    -- =================================================================
    -- MARKET IDENTIFICATION
    -- =================================================================
    COALESCE((SELECT vault_address FROM vault_mkt1), NULL) AS vault_address_mkt1,
    COALESCE((SELECT vault_address FROM vault_mkt2), NULL) AS vault_address_mkt2,

    -- =================================================================
    -- SY SUPPLY ANALYTICS (per market, decimal-adjusted)
    -- =================================================================

    -- SY total supply (decimal-adjusted, combined across all base tokens in USX terms)
    ROUND(COALESCE(
        (SELECT sy_total_supply_raw_usx_terms FROM sy_token_supply_combined) /
        POW(10, COALESCE((SELECT sy_usx_decimals FROM sy_token_supply_combined), 6)),
        0
    )::NUMERIC, 0) AS sy_total_supply,

    -- Market 1: SY total locked and percentage (decimal-adjusted)
    -- Locked amount stays in market's native units for absolute value
    ROUND(COALESCE(
        ((SELECT total_sy_in_escrow FROM vault_mkt1) +
         (SELECT sy_balance FROM market_mkt1)) / POW(10, (SELECT decimals_mkt1 FROM decimals_config)),
        0
    )::NUMERIC, 0) AS sy_total_locked_mkt1,

    -- Percentage uses combined total supply in USX terms as denominator
    -- Numerator is locked amount converted to USX terms
    ROUND(COALESCE(
        (SELECT locked_usx_terms_mkt1 FROM market_locked_sy_usx_terms) /
        NULLIF((SELECT sy_total_supply_raw_usx_terms FROM sy_token_supply_combined), 0) * 100,
        0
    )::NUMERIC, 1) AS sy_total_locked_pct_mkt1,

    -- Market 2: SY total locked and percentage (decimal-adjusted)
    -- Returns NULL if vault doesn't exist
    ROUND(CASE
        WHEN (SELECT vault_address FROM vault_mkt2) IS NOT NULL
        THEN ((SELECT total_sy_in_escrow FROM vault_mkt2) +
              (SELECT sy_balance FROM market_mkt2)) / POW(10, (SELECT decimals_mkt2 FROM decimals_config))
        ELSE NULL
    END::NUMERIC, 0) AS sy_total_locked_mkt2,

    -- Percentage uses combined total supply in USX terms as denominator
    ROUND(CASE
        WHEN (SELECT vault_address FROM vault_mkt2) IS NOT NULL
        THEN (SELECT locked_usx_terms_mkt2 FROM market_locked_sy_usx_terms) /
             NULLIF((SELECT sy_total_supply_raw_usx_terms FROM sy_token_supply_combined), 0) * 100
        ELSE NULL
    END::NUMERIC, 1) AS sy_total_locked_pct_mkt2,

    -- General: SY not in either market (absolute, decimal-adjusted)
    -- Uses combined total supply minus locked amounts converted to USX terms
    ROUND(COALESCE(
        ((SELECT sy_total_supply_raw_usx_terms FROM sy_token_supply_combined) -
         COALESCE((SELECT locked_usx_terms_mkt1 FROM market_locked_sy_usx_terms), 0) -
         COALESCE((SELECT locked_usx_terms_mkt2 FROM market_locked_sy_usx_terms), 0)) /
         POW(10, COALESCE((SELECT sy_usx_decimals FROM sy_token_supply_combined), 6)),
        0
    )::NUMERIC, 0) AS sy_not_in_mkt1_mkt2,

    -- Percentage uses combined total supply in USX terms
    ROUND(COALESCE(
        100.0 -
        (COALESCE((SELECT locked_usx_terms_mkt1 FROM market_locked_sy_usx_terms), 0) /
         NULLIF((SELECT sy_total_supply_raw_usx_terms FROM sy_token_supply_combined), 0) * 100) -
        (COALESCE((SELECT locked_usx_terms_mkt2 FROM market_locked_sy_usx_terms), 0) /
         NULLIF((SELECT sy_total_supply_raw_usx_terms FROM sy_token_supply_combined), 0) * 100),
        0
    )::NUMERIC, 1) AS sy_not_in_mkt1_mkt2_pct,

    -- =================================================================
    -- MATURITY ANALYTICS
    -- =================================================================

    -- Market 1 timing
    (SELECT start_ts FROM vault_mkt1) AS start_ts_mkt1,
    to_timestamp((SELECT start_ts FROM vault_mkt1)) AS start_datetime_mkt1,
    (SELECT duration FROM vault_mkt1) AS duration_mkt1,
    (SELECT maturity_ts FROM vault_mkt1) AS end_ts_mkt1,
    to_timestamp((SELECT maturity_ts FROM vault_mkt1)) AS end_datetime_mkt1,

    -- Market 2 timing
    (SELECT start_ts FROM vault_mkt2) AS start_ts_mkt2,
    to_timestamp((SELECT start_ts FROM vault_mkt2)) AS start_datetime_mkt2,
    (SELECT duration FROM vault_mkt2) AS duration_mkt2,
    (SELECT maturity_ts FROM vault_mkt2) AS end_ts_mkt2,
    to_timestamp((SELECT maturity_ts FROM vault_mkt2)) AS end_datetime_mkt2,

    -- Chart bounds (general)
    EXTRACT(EPOCH FROM (
        to_timestamp(LEAST(
            COALESCE((SELECT start_ts FROM vault_mkt1), 2147483647),
            COALESCE((SELECT start_ts FROM vault_mkt2), 2147483647)
        )) - INTERVAL '7 days'
    ))::INTEGER AS start_ts_chart,

    to_timestamp(LEAST(
        COALESCE((SELECT start_ts FROM vault_mkt1), 2147483647),
        COALESCE((SELECT start_ts FROM vault_mkt2), 2147483647)
    )) - INTERVAL '7 days' AS start_datetime_chart,

    EXTRACT(EPOCH FROM (
        to_timestamp(GREATEST(
            COALESCE((SELECT maturity_ts FROM vault_mkt1), 0),
            COALESCE((SELECT maturity_ts FROM vault_mkt2), 0)
        )) + INTERVAL '7 days'
    ))::INTEGER AS end_ts_chart,

    to_timestamp(GREATEST(
        COALESCE((SELECT maturity_ts FROM vault_mkt1), 0),
        COALESCE((SELECT maturity_ts FROM vault_mkt2), 0)
    )) + INTERVAL '7 days' AS end_datetime_chart,

    EXTRACT(EPOCH FROM NOW())::INTEGER AS now_ts,
    NOW() AS now_datetime,

    -- =================================================================
    -- MARKET IMPLIED APY (from AMM pricing)
    -- =================================================================

    -- Market 1: Implied APY from market pricing (simple annualization to match Exponent web)
    -- Returns NULL if market doesn't exist OR if market has expired
    ROUND(COALESCE((SELECT mkt1 FROM simple_apy) * 100, NULL)::NUMERIC, 2) AS apy_market_mkt1,

    -- Market 2: Implied APY from market pricing (simple annualization to match Exponent web)
    -- Returns NULL if market doesn't exist OR if market has expired
    ROUND(COALESCE((SELECT mkt2 FROM simple_apy) * 100, NULL)::NUMERIC, 2) AS apy_market_mkt2,

    -- =================================================================
    -- PT PRICE (in UNDERLYING/BASE terms - PT value as fraction of 1 underlying)
    -- =================================================================
    -- Note: c_implied_pt_price from the AMM is in UNDERLYING terms, not SY tokens.
    -- At maturity, PT price = 1.0 underlying (no time discount).
    -- Post-maturity: PT is redeemable for exactly 1.0 underlying.
    -- To get PT price in SY tokens: divide by sy_exchange_rate.

    -- Market 1: PT price in underlying (approaches 1.0 at maturity, equals 1.0 post-maturity)
    ROUND(CASE
        WHEN (SELECT maturity_ts FROM vault_mkt1) < EXTRACT(EPOCH FROM NOW())::INTEGER
        THEN 1.0  -- Post-maturity: PT = 1.0 underlying (redeemable)
        ELSE COALESCE((SELECT c_implied_pt_price FROM market_mkt1), 0)
    END::NUMERIC, 4) AS pt_base_price_mkt1,

    -- Market 2: PT price in underlying (approaches 1.0 at maturity, equals 1.0 post-maturity)
    -- Returns NULL if market doesn't exist
    ROUND(CASE
        WHEN (SELECT market_address FROM market_mkt2) IS NULL
        THEN NULL
        WHEN (SELECT maturity_ts FROM vault_mkt2) < EXTRACT(EPOCH FROM NOW())::INTEGER
        THEN 1.0  -- Post-maturity: PT = 1.0 underlying (redeemable)
        ELSE (SELECT c_implied_pt_price FROM market_mkt2)
    END::NUMERIC, 4) AS pt_base_price_mkt2,

    -- =================================================================
    -- PT PRICE (DEPRECATED - mislabelled, use pt_base_price_mktX instead)
    -- =================================================================
    -- DEPRECATED: These columns are mislabelled. The value is in UNDERLYING terms,
    -- not SY tokens. Kept for backward compatibility with live dashboard.
    -- TODO: Remove once dashboard is updated to use pt_base_price_mktX

    -- Market 1: PT price (DEPRECATED - actually in underlying terms, not SY)
    ROUND(CASE
        WHEN (SELECT maturity_ts FROM vault_mkt1) < EXTRACT(EPOCH FROM NOW())::INTEGER
        THEN 1.0  -- Post-maturity: PT = 1.0 underlying (redeemable)
        ELSE COALESCE((SELECT c_implied_pt_price FROM market_mkt1), 0)
    END::NUMERIC, 4) AS pt_sy_price_mkt1,

    -- Market 2: PT price (DEPRECATED - actually in underlying terms, not SY)
    -- Returns NULL if market doesn't exist
    ROUND(CASE
        WHEN (SELECT market_address FROM market_mkt2) IS NULL
        THEN NULL
        WHEN (SELECT maturity_ts FROM vault_mkt2) < EXTRACT(EPOCH FROM NOW())::INTEGER
        THEN 1.0  -- Post-maturity: PT = 1.0 underlying (redeemable)
        ELSE (SELECT c_implied_pt_price FROM market_mkt2)
    END::NUMERIC, 4) AS pt_sy_price_mkt2,

    -- =================================================================
    -- REALIZED UNDERLYING YIELD - OVER VAULT LIFE
    -- =================================================================

    -- Market 1: Annualized yield from start to end/now
    -- Returns NULL if vault_mkt1 doesn't exist
    -- Returns 0.00 if SY exchange rate is constant (no yield accrual)
    ROUND(CASE
        WHEN (SELECT vault_address FROM vault_mkt1) IS NULL
        THEN NULL
        WHEN (SELECT base_start_index_mkt1 FROM lifetime_start) IS NOT NULL
             AND (SELECT base_start_index_mkt1 FROM lifetime_start) > 0
             AND (SELECT base_start_epoch_mkt1 FROM lifetime_start) IS NOT NULL
             AND (SELECT end_rate FROM sy_meta_end_mkt1) IS NOT NULL
             AND EXTRACT(EPOCH FROM NOW())::NUMERIC > (SELECT base_start_epoch_mkt1 FROM lifetime_start)
        THEN
            -- Check if rate is constant (within 0.01% tolerance to account for rounding)
            CASE
                WHEN ABS((SELECT end_rate FROM sy_meta_end_mkt1) - (SELECT base_start_index_mkt1 FROM lifetime_start))
                     / NULLIF((SELECT base_start_index_mkt1 FROM lifetime_start), 0) < 0.0001
                THEN 0.00  -- Constant rate = 0% yield
                ELSE (
                    (SELECT end_rate FROM sy_meta_end_mkt1) /
                    NULLIF((SELECT base_start_index_mkt1 FROM lifetime_start), 0) - 1.0
                ) * (
                    31536000.0 / GREATEST(
                        EXTRACT(EPOCH FROM NOW())::NUMERIC - (SELECT base_start_epoch_mkt1 FROM lifetime_start),
                        3600.0  -- Minimum 1 hour to avoid extreme annualization
                    )
                ) * 100
            END
        ELSE NULL
    END::NUMERIC, 2) AS apy_realized_vault_life_mkt1,

    -- Market 2: Annualized yield from start to end/now
    -- Returns NULL if vault_mkt2 doesn't exist
    -- Returns 0.00 if SY exchange rate is constant (no yield accrual)
    ROUND(CASE
        WHEN (SELECT vault_address FROM vault_mkt2) IS NULL
        THEN NULL
        WHEN (SELECT base_start_index_mkt2 FROM lifetime_start) IS NOT NULL
             AND (SELECT base_start_index_mkt2 FROM lifetime_start) > 0
             AND (SELECT base_start_epoch_mkt2 FROM lifetime_start) IS NOT NULL
             AND (SELECT end_rate FROM sy_meta_end_mkt2) IS NOT NULL
             AND EXTRACT(EPOCH FROM NOW())::NUMERIC > (SELECT base_start_epoch_mkt2 FROM lifetime_start)
        THEN
            -- Check if rate is constant (within 0.01% tolerance to account for rounding)
            CASE
                WHEN ABS((SELECT end_rate FROM sy_meta_end_mkt2) - (SELECT base_start_index_mkt2 FROM lifetime_start))
                     / NULLIF((SELECT base_start_index_mkt2 FROM lifetime_start), 0) < 0.0001
                THEN 0.00  -- Constant rate = 0% yield
                ELSE (
                    (SELECT end_rate FROM sy_meta_end_mkt2) /
                    NULLIF((SELECT base_start_index_mkt2 FROM lifetime_start), 0) - 1.0
                ) * (
                    31536000.0 / GREATEST(
                        EXTRACT(EPOCH FROM NOW())::NUMERIC - (SELECT base_start_epoch_mkt2 FROM lifetime_start),
                        3600.0  -- Minimum 1 hour to avoid extreme annualization
                    )
                ) * 100
            END
        ELSE NULL
    END::NUMERIC, 2) AS apy_realized_vault_life_mkt2,

    -- =================================================================
    -- REALIZED UNDERLYING YIELD - TRAILING WINDOWS (general)
    -- NOTE: Returns NULL until there is a full window of data
    -- =================================================================

    -- 24h trailing APY (returns NULL if no data from >= 24h ago)
    ROUND(CASE
        WHEN (SELECT rate_24h_ago FROM sy_meta_24h_ago) IS NOT NULL
        THEN (
            (
                (SELECT rate_now FROM sy_meta_now) /
                NULLIF((SELECT rate_24h_ago FROM sy_meta_24h_ago), 0) - 1.0
            ) * 365.0 * 100  -- Fixed 24h annualization
        )
        ELSE NULL
    END::NUMERIC, 2) AS apy_realized_24h,

    -- 7d trailing APY (returns NULL if no data from >= 7d ago)
    ROUND(CASE
        WHEN (SELECT rate_7d_ago FROM sy_meta_7d_ago) IS NOT NULL
        THEN (
            (
                (SELECT rate_now FROM sy_meta_now) /
                NULLIF((SELECT rate_7d_ago FROM sy_meta_7d_ago), 0) - 1.0
            ) * (365.0 / 7.0) * 100
        )
        ELSE NULL
    END::NUMERIC, 2) AS apy_realized_7d,

    -- =================================================================
    -- APY DIVERGENCE (market implied vs realized 24h)
    -- =================================================================

    -- Market 1: Divergence between market pricing and actual trailing yield
    -- Uses market-specific SY exchange rate data based on market's base token
    -- NOTE: Returns NULL until there is a full 24h window of data OR if market has expired
    ROUND(CASE
        WHEN (SELECT rate_24h_ago FROM sy_meta_24h_ago_mkt1) IS NOT NULL
             AND (SELECT mkt1 FROM simple_apy) IS NOT NULL
        THEN (
            (SELECT mkt1 FROM simple_apy) * 100 -
            (
                (
                    (SELECT rate_now FROM sy_meta_now_mkt1) /
                    NULLIF((SELECT rate_24h_ago FROM sy_meta_24h_ago_mkt1), 0) - 1.0
                ) * 365.0 * 100
            )
        )
        ELSE NULL
    END::NUMERIC, 2) AS apy_divergence_wrt_24h_mkt1,

    -- Market 2: Divergence between market pricing and actual trailing yield
    -- Uses market-specific SY exchange rate data based on market's base token
    -- NOTE: Returns NULL until there is a full 24h window of data OR if market has expired
    ROUND(CASE
        WHEN (SELECT rate_24h_ago FROM sy_meta_24h_ago_mkt2) IS NOT NULL
             AND (SELECT mkt2 FROM simple_apy) IS NOT NULL
        THEN (
            (SELECT mkt2 FROM simple_apy) * 100 -
            (
                (
                    (SELECT rate_now FROM sy_meta_now_mkt2) /
                    NULLIF((SELECT rate_24h_ago FROM sy_meta_24h_ago_mkt2), 0) - 1.0
                ) * 365.0 * 100
            )
        )
        ELSE NULL
    END::NUMERIC, 2) AS apy_divergence_wrt_24h_mkt2,

    -- =================================================================
    -- APY DIVERGENCE (market implied vs realized 7d)
    -- =================================================================

    -- Market 1: Divergence between market pricing and actual 7d trailing yield
    -- Uses market-specific SY exchange rate data based on market's base token
    -- NOTE: Returns NULL if no trailing data OR if market has expired
    ROUND(CASE
        WHEN (SELECT rate_7d_ago FROM sy_meta_7d_ago_mkt1) IS NOT NULL
             AND (SELECT rate_now FROM sy_meta_now_mkt1) IS NOT NULL
             AND (SELECT mkt1 FROM simple_apy) IS NOT NULL
        THEN (
            (SELECT mkt1 FROM simple_apy) * 100 -
            (
                (
                    (SELECT rate_now FROM sy_meta_now_mkt1) /
                    NULLIF((SELECT rate_7d_ago FROM sy_meta_7d_ago_mkt1), 0) - 1.0
                ) * (365.0 / 7.0) * 100
            )
        )
        ELSE NULL
    END::NUMERIC, 2) AS apy_divergence_wrt_7d_mkt1,

    -- Market 2: Divergence between market pricing and actual 7d trailing yield
    -- Uses market-specific SY exchange rate data based on market's base token
    -- NOTE: Returns NULL if no trailing data OR if market has expired
    ROUND(CASE
        WHEN (SELECT rate_7d_ago FROM sy_meta_7d_ago_mkt2) IS NOT NULL
             AND (SELECT rate_now FROM sy_meta_now_mkt2) IS NOT NULL
             AND (SELECT mkt2 FROM simple_apy) IS NOT NULL
        THEN (
            (SELECT mkt2 FROM simple_apy) * 100 -
            (
                (
                    (SELECT rate_now FROM sy_meta_now_mkt2) /
                    NULLIF((SELECT rate_7d_ago FROM sy_meta_7d_ago_mkt2), 0) - 1.0
                ) * (365.0 / 7.0) * 100
            )
        )
        ELSE NULL
    END::NUMERIC, 2) AS apy_divergence_wrt_7d_mkt2,

    -- =================================================================
    -- DISCOUNT RATES (from market pricing)
    -- =================================================================

    -- Market 1: Discount rate from PT pricing
    -- Returns NULL for expired vaults (extreme rates not meaningful)
    CASE
        WHEN (SELECT maturity_ts FROM vault_mkt1) < EXTRACT(EPOCH FROM NOW())::INTEGER
        THEN NULL  -- Expired vault
        ELSE ROUND(COALESCE(
            (SELECT c_discount_rate FROM market_mkt1) * 100,
            0
        )::NUMERIC, 2)
    END AS discount_rate_mkt1,

    -- Market 2: Discount rate from PT pricing
    -- Returns NULL if market doesn't exist OR if market has expired
    ROUND(CASE
        WHEN (SELECT market_address FROM market_mkt2) IS NOT NULL
             AND (SELECT maturity_ts FROM vault_mkt2) >= EXTRACT(EPOCH FROM NOW())::INTEGER
        THEN (SELECT c_discount_rate FROM market_mkt2) * 100
        ELSE NULL  -- Market doesn't exist or has expired
    END::NUMERIC, 2) AS discount_rate_mkt2,

    -- =================================================================
    -- AMM PRICE IMPACT (for standardized trade size)
    -- =================================================================

    -- Trade size used for impact calculations (decimal-adjusted PT units)
    -- 100000 PT is a meaningful size relative to typical pool depths (5-10M PT)
    100000 AS amm_impact_trade_size_pt,

    -- DEPRECATED: kept for backward compatibility with live dashboard
    -- Note: This is now PT units (not SY), will be removed when dashboard updated
    100000 AS amm_price_impact_trade_size_sy,

    -- Market 1: Price impact as percentage of current PT price for buying 100000 PT
    ROUND(CASE
        WHEN (SELECT market_address FROM market_mkt1) IS NOT NULL
        THEN exponent.get_amm_price_impact(
            (SELECT market_address FROM market_mkt1),
            100000.0,
            NULL
        )
        ELSE NULL
    END::NUMERIC, 2) AS amm_price_impact_mkt1_pct,

    -- Market 2: Price impact as percentage of current PT price for buying 100000 PT
    -- Returns NULL if market doesn't exist
    ROUND(CASE
        WHEN (SELECT market_address FROM market_mkt2) IS NOT NULL
        THEN exponent.get_amm_price_impact(
            (SELECT market_address FROM market_mkt2),
            100000.0,
            NULL
        )
        ELSE NULL
    END::NUMERIC, 2) AS amm_price_impact_mkt2_pct,

    -- =================================================================
    -- AMM YIELD IMPACT (APY change from standardized trade)
    -- =================================================================
    -- How much implied APY changes from buying 100000 PT
    -- Negative = APY decreases (buying PT pushes price up, reducing discount)
    -- Uses get_amm_yield_impact which wraps get_amm_price_impact

    -- Market 1: APY change in percentage points from buying 100000 PT
    -- Returns NULL post-maturity (yield impact depends on time-to-maturity)
    ROUND(CASE
        WHEN (SELECT market_address FROM market_mkt1) IS NOT NULL
             AND (SELECT maturity_ts FROM vault_mkt1) >= EXTRACT(EPOCH FROM NOW())::INTEGER
        THEN exponent.get_amm_yield_impact(
            (SELECT market_address FROM market_mkt1),
            100000.0,
            NULL
        )
        ELSE NULL  -- Market doesn't exist or has expired
    END::NUMERIC, 2) AS amm_yield_impact_mkt1_pct,

    -- Market 2: APY change in percentage points from buying 100000 PT
    -- Returns NULL if market doesn't exist OR has expired
    ROUND(CASE
        WHEN (SELECT market_address FROM market_mkt2) IS NOT NULL
             AND (SELECT maturity_ts FROM vault_mkt2) >= EXTRACT(EPOCH FROM NOW())::INTEGER
        THEN exponent.get_amm_yield_impact(
            (SELECT market_address FROM market_mkt2),
            100000.0,
            NULL
        )
        ELSE NULL  -- Market doesn't exist or has expired
    END::NUMERIC, 2) AS amm_yield_impact_mkt2_pct,

    -- =================================================================
    -- SY CLAIMS (per market, decimal-adjusted)
    -- =================================================================

    -- Market 1: SY claims from vault (sy_for_pt + treasury_sy + uncollected_sy)
    ROUND(COALESCE(
        (SELECT sy_for_pt + treasury_sy + uncollected_sy FROM vault_mkt1) /
        POW(10, (SELECT decimals_mkt1 FROM decimals_config)),
        0
    )::NUMERIC, 0) AS sy_claims_mkt1,

    -- Market 2: SY claims from vault (sy_for_pt + treasury_sy + uncollected_sy)
    -- Returns NULL if vault doesn't exist
    ROUND(CASE
        WHEN (SELECT vault_address FROM vault_mkt2) IS NOT NULL
        THEN (SELECT sy_for_pt + treasury_sy + uncollected_sy FROM vault_mkt2) /
             POW(10, (SELECT decimals_mkt2 FROM decimals_config))
        ELSE NULL
    END::NUMERIC, 0) AS sy_claims_mkt2,

    -- Combined PT/YT supply (decimal-adjusted)
    ROUND(COALESCE(
        (
            COALESCE((SELECT pt_supply FROM vault_mkt1), 0) +
            COALESCE((SELECT pt_supply FROM vault_mkt2), 0)
        ) / POW(
            10,
            COALESCE(
                (SELECT decimals_mkt2 FROM decimals_config),
                (SELECT decimals_mkt1 FROM decimals_config),
                6
            )
        ),
        0
    )::NUMERIC, 0) AS pt_yt_supply,

    -- =================================================================
    -- LOCKED eUSX (general - not market specific)
    -- =================================================================

    ROUND(COALESCE((SELECT eusx_locked_amt FROM underlying_escrow), 0)::NUMERIC, 0) AS eusx_locked,

    -- eUSX collateralization ratio (both values decimal-adjusted)
    ROUND(COALESCE(
        (SELECT eusx_locked_amt FROM underlying_escrow) /
        NULLIF(
            (SELECT supply FROM sy_token_supply) / POW(10, (SELECT decimals_mkt2 FROM decimals_config)),
            0
        ),
        0
    )::NUMERIC, 2) AS eusx_collateralization_ratio,

    -- =================================================================
    -- VAULTS & MARKETS (per market)
    -- =================================================================

    -- Market 1 vault & market metrics
    ROUND(COALESCE(
        (SELECT total_sy_in_escrow FROM vault_mkt1) /
        NULLIF(
            (SELECT sy_for_pt + treasury_sy + uncollected_sy FROM vault_mkt1),
            0
        ),
        0
    )::NUMERIC, 2) AS sy_coll_ratio_mkt1,

    ROUND(COALESCE(
        (SELECT c_total_market_depth_in_sy FROM market_mkt1) / POW(10, (SELECT decimals_mkt1 FROM decimals_config)),
        0
    )::NUMERIC, 0) AS amm_depth_in_sy_mkt1,

    ROUND(COALESCE(
        (SELECT c_total_market_depth_in_sy FROM market_mkt1) /
        NULLIF(
            (SELECT sy_for_pt + treasury_sy + uncollected_sy FROM vault_mkt1),
            0
        ) * 100,
        0
    )::NUMERIC, 1) AS amm_pct_of_sy_claims_mkt1,

    ROUND(COALESCE(
        (SELECT sy_for_pt + treasury_sy + uncollected_sy FROM vault_mkt1) /
        NULLIF((SELECT c_total_market_depth_in_sy FROM market_mkt1), 0) * 100,
        0
    )::NUMERIC, 1) AS vault_sy_claims_pct_amm_mkt1,

    ROUND(COALESCE(
        (SELECT c_total_market_depth_in_sy FROM market_mkt1) /
        NULLIF((SELECT supply FROM sy_token_supply), 0) * 100,
        0
    )::NUMERIC, 1) AS amm_share_sy_pct_mkt1,

    -- Market 1: YT staked percentage
    -- Calculated as: (YT tokens staked in escrow / PT supply) * 100
    -- This shows what percentage of PT supply has been staked (via YT escrow)
    ROUND(COALESCE(
        CASE
            WHEN (SELECT pt_supply FROM vault_mkt1) > 0
            THEN COALESCE((SELECT yt_balance FROM yt_escrow_mkt1), 0) /
                 NULLIF((SELECT pt_supply FROM vault_mkt1), 0) * 100
            ELSE 0
        END,
        0
    )::NUMERIC, 1) AS yt_staked_pct_mkt1,

    -- Market 2 vault & market metrics
    -- All return NULL if vault doesn't exist
    ROUND(CASE
        WHEN (SELECT vault_address FROM vault_mkt2) IS NOT NULL
        THEN (SELECT total_sy_in_escrow FROM vault_mkt2) /
             NULLIF((SELECT sy_for_pt + treasury_sy + uncollected_sy FROM vault_mkt2), 0)
        ELSE NULL
    END::NUMERIC, 2) AS sy_coll_ratio_mkt2,

    ROUND(CASE
        WHEN (SELECT vault_address FROM vault_mkt2) IS NOT NULL
        THEN (SELECT c_total_market_depth_in_sy FROM market_mkt2) / POW(10, (SELECT decimals_mkt2 FROM decimals_config))
        ELSE NULL
    END::NUMERIC, 0) AS amm_depth_in_sy_mkt2,

    ROUND(CASE
        WHEN (SELECT vault_address FROM vault_mkt2) IS NOT NULL
        THEN (SELECT c_total_market_depth_in_sy FROM market_mkt2) /
             NULLIF((SELECT sy_for_pt + treasury_sy + uncollected_sy FROM vault_mkt2), 0) * 100
        ELSE NULL
    END::NUMERIC, 1) AS amm_pct_of_sy_claims_mkt2,

    ROUND(CASE
        WHEN (SELECT vault_address FROM vault_mkt2) IS NOT NULL
        THEN (SELECT sy_for_pt + treasury_sy + uncollected_sy FROM vault_mkt2) /
             NULLIF((SELECT c_total_market_depth_in_sy FROM market_mkt2), 0) * 100
        ELSE NULL
    END::NUMERIC, 1) AS vault_sy_claims_pct_amm_mkt2,

    ROUND(CASE
        WHEN (SELECT vault_address FROM vault_mkt2) IS NOT NULL
        THEN (SELECT c_total_market_depth_in_sy FROM market_mkt2) /
             NULLIF((SELECT supply FROM sy_token_supply), 0) * 100
        ELSE NULL
    END::NUMERIC, 1) AS amm_share_sy_pct_mkt2,

    -- Market 2: YT staked percentage
    -- Calculated as: (YT tokens staked in escrow / PT supply) * 100
    -- This shows what percentage of PT supply has been staked (via YT escrow)
    -- Returns NULL if vault doesn't exist
    ROUND(CASE
        WHEN (SELECT vault_address FROM vault_mkt2) IS NOT NULL AND (SELECT pt_supply FROM vault_mkt2) > 0
        THEN COALESCE((SELECT yt_balance FROM yt_escrow_mkt2), 0) /
             NULLIF((SELECT pt_supply FROM vault_mkt2), 0) * 100
        ELSE NULL
    END::NUMERIC, 1) AS yt_staked_pct_mkt2,

    -- =================================================================
    -- ARRAY COLUMNS
    -- =================================================================

    -- Market PT Symbol Arrays (2 elements: mkt1, mkt2)
    -- NULL values are included if market doesn't exist
    ARRAY[
        (SELECT meta_pt_symbol FROM market_mkt1),
        (SELECT meta_pt_symbol FROM market_mkt2)
    ] AS market_pt_symbol_array,

    -- Market PT Symbol Full Arrays (2 elements: mkt1, mkt2)
    -- NULL values are included if market doesn't exist
    ARRAY[
        (SELECT meta_pt_name FROM market_mkt1),
        (SELECT meta_pt_name FROM market_mkt2)
    ] AS market_pt_symbol_array_full,

    -- All available market PT names (for dropdowns/selectors)
    -- Returns all unique meta_pt_name values from aux_key_relations
    (SELECT ARRAY_AGG(DISTINCT meta_pt_name ORDER BY meta_pt_name)
     FROM exponent.aux_key_relations
     WHERE meta_pt_name IS NOT NULL
    ) AS market_pt_symbol_array_all,

    -- Base Tokens Locked Array (decimal-scaled, 0dp, market-ordered: mkt1, mkt2)
    -- If both markets share same base token, array has only one element
    -- Returns empty array if no escrows found
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
    END AS base_tokens_locked_array,

    -- Total Naive TVL: sum of all unique base token escrow amounts
    -- "Naive" because it sums raw amounts without accounting for different token prices
    -- If both markets share same base token, this equals that single escrow amount
    ROUND(COALESCE(
        (SELECT SUM(amount_decimal) FROM base_token_escrow_unique),
        0
    )::NUMERIC, 0) AS total_naive_tvl,

    -- Base Tokens Symbol Array (market-ordered: mkt1, mkt2)
    -- If both markets share same base token, array has only one element
    -- Returns empty array if no escrows found
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
    END AS base_tokens_symbol_array,

    -- Base Tokens Symbols Array (mapped to markets: mkt1, mkt2)
    -- Returns array of base token symbols in market order [mkt1, mkt2]
    -- If both markets share same base token, array has only one element
    -- If mkt2 doesn't exist, array has only one element (mkt1)
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
    END AS base_tokens_symbols_array,

    -- Base Token Collateralization Ratio Array (market-ordered: mkt1, mkt2)
    -- Calculated as: escrow_amount / sy_supply for each unique base token
    -- If both markets share same base token, array has only one element
    -- Returns empty array if no escrows found
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
    END AS base_token_collateralization_ratio_array,

    -- 24h Realized APY Array (market-ordered: mkt1, mkt2)
    -- Calculated as annualized yield from 24h trailing window for each unique base token
    -- If both markets share same base token, array has only one element
    -- Returns empty array if no data available; NULL values are included for markets without enough data
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
    END AS apy_realized_24hr_array,

    -- 7d Realized APY Array (market-ordered: mkt1, mkt2)
    -- Calculated as annualized yield from 7d trailing window for each unique base token
    -- If both markets share same base token, array has only one element
    -- Returns empty array if no data available; NULL values are included for markets without enough data
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
    END AS apy_realized_7d_array,

    -- AMM PT Trading Volume 24h Array (market-ordered: mkt1, mkt2)
    -- Sum of PT in + PT out from trade_pt events in the last 24 hours
    -- Values are decimal-adjusted PT amounts
    ARRAY[
        ROUND(COALESCE(
            (SELECT pt_volume_24h FROM amm_pt_volume_24h WHERE market_address = (SELECT market_address FROM market_mkt1)),
            0
        )::NUMERIC, 0)::DOUBLE PRECISION,
        ROUND(COALESCE(
            (SELECT pt_volume_24h FROM amm_pt_volume_24h WHERE market_address = (SELECT market_address FROM market_mkt2)),
            0
        )::NUMERIC, 0)::DOUBLE PRECISION
    ] AS amm_pt_vol_24h_array,

    -- =================================================================
    -- EXPIRY STATUS
    -- =================================================================
    -- Boolean flags indicating if each market has passed maturity
    -- Helps dashboard consumers identify and handle expired markets

    -- Market 1: TRUE if current time is past maturity
    CASE
        WHEN (SELECT maturity_ts FROM vault_mkt1) IS NOT NULL
        THEN (SELECT maturity_ts FROM vault_mkt1) < EXTRACT(EPOCH FROM NOW())::INTEGER
        ELSE NULL
    END AS is_expired_mkt1,

    -- Market 2: TRUE if current time is past maturity
    CASE
        WHEN (SELECT maturity_ts FROM vault_mkt2) IS NOT NULL
        THEN (SELECT maturity_ts FROM vault_mkt2) < EXTRACT(EPOCH FROM NOW())::INTEGER
        ELSE NULL
    END AS is_expired_mkt2,

    -- =================================================================
    -- METADATA
    -- =================================================================

    NOW() AS last_updated,
    GREATEST(
        COALESCE((SELECT vault_slot FROM vault_mkt1), 0),
        COALESCE((SELECT vault_slot FROM vault_mkt2), 0)
    ) AS slot;
END;
$$ LANGUAGE plpgsql STABLE;

-- Add function comment
COMMENT ON FUNCTION exponent.get_view_exponent_last(TEXT, TEXT) IS
'Dashboard function providing the most recent state for key metrics across two markets.

Parameters:
  p_mkt1_pt_name - Optional explicit market selection for mkt1 via meta_pt_name (e.g., ''PT-weUSX-26DEC2025'')
  p_mkt2_pt_name - Optional explicit market selection for mkt2 via meta_pt_name (e.g., ''PT-weUSX-26JUN2026'')

Market Selection Modes:
  1. DEFAULT MODE (both params NULL):
     - Uses recency-based selection by maturity_ts
     - mkt2 = vault with HIGHEST maturity_ts (furthest expiry)
     - mkt1 = vault with NEXT HIGHEST maturity_ts (nearer expiry)
     - If only 1 vault exists: mkt1 = that vault, mkt2 = NULL

  2. EXPLICIT MODE (both params provided):
     - Looks up vaults by meta_pt_name in aux_key_relations
     - mkt1 = vault matching p_mkt1_pt_name
     - mkt2 = vault matching p_mkt2_pt_name
     - Allows selecting any two markets regardless of maturity order

  3. INVALID (one param NULL, one not):
     - Raises SQL exception with descriptive error message

Metrics provided:
  - SY Supply Analytics:
    * sy_total_supply: total SY token supply (decimal-adjusted)
    * locked amounts and utilization percentages per market
  - SY Claims:
    * sy_claims_mkt1/mkt2: vault SY claims (sy_for_pt + treasury_sy + uncollected_sy, decimal-adjusted)
  - Maturity Analytics: start/end times and chart bounds
  - Market Implied APY: APY from AMM pricing (apy_market_mktX)
    * Returns NULL post-maturity (time-to-maturity calculations invalid after expiry)
  - PT Base Price: PT price in underlying/base terms (pt_base_price_mktX) - approaches 1.0 at maturity
  - PT-SY Price (DEPRECATED): mislabelled, actually same as pt_base_price - kept for backward compatibility
  - Realized Underlying Yield:
    * Over vault life (apy_realized_vault_life_mktX)
    * Trailing 24h (apy_realized_24h) - uses earliest available if < 24h of data
    * Trailing 7d (apy_realized_7d)
  - APY Divergence: difference between market pricing and realized yield
    * Returns NULL post-maturity (implied APY is invalid after expiry)
  - Discount Rates: effective discount rates from PT pricing
    * Returns NULL post-maturity (time-to-maturity calculations invalid)
  - Expiry Status (is_expired_mkt1, is_expired_mkt2):
    * Boolean flags indicating if each market has passed maturity
    * Helps dashboard consumers identify and handle expired markets
  - AMM Price Impact: expected slippage for standardized PT buy (100000 PT units)
    * amm_impact_trade_size_pt: reference trade size in PT (100000)
    * amm_price_impact_mktX_pct: price impact as percentage from buying 100000 PT
  - AMM Yield Impact: APY change from standardized PT buy (100000 PT units)
    * amm_yield_impact_mktX_pct: APY change in percentage points from buying 100000 PT
      (negative = APY decreases because buying PT pushes price up, reducing discount)
  - Locked eUSX: total locked and collateralization ratio (decimal-adjusted)
  - Vault & Market Metrics: collateral ratios, AMM depth, vault claims vs AMM depth, YT staking %
  - Array Columns:
    * market_pt_symbol_array: Array of PT symbols [mkt1, mkt2] from src_market_twos.meta_pt_symbol
    * market_pt_symbol_array_full: Array of PT names [mkt1, mkt2] from src_market_twos.meta_pt_name
    * market_pt_symbol_array_all: Array of ALL available market names from aux_key_relations.meta_pt_name
      (useful for dropdown selectors - provides valid values for get_view_exponent_last params)
    * base_tokens_locked_array: Array of decimal-scaled (0dp) base token escrow amounts from src_base_token_escrow
      (if both markets share same base token, array has only one element)
    * base_tokens_symbol_array: Array of base token symbols from src_base_token_escrow.meta_base_symbol
      (if both markets share same base token, array has only one element)
    * base_tokens_symbols_array: Array of base token symbols mapped to each market [mkt1 base, mkt2 base]
      from src_base_token_escrow.meta_base_symbol, preserving market order
      (if both markets share same base token, array has only one element; if mkt2 doesn''t exist, array has only mkt1)
    * base_token_collateralization_ratio_array: Array of collateralization ratios (escrow_amount / sy_supply)
      for each unique base token (if both markets share same base token, array has only one element)
    * apy_realized_24hr_array: Array of 24h realized APY (annualized yield from trailing 24h window)
      for each unique base token, displayed as percentage with 2 decimal places
      (if both markets share same base token, array has only one element)

All numeric values are formatted with appropriate precision:
  - Amounts: 0 decimals (including sy_total_supply, sy_claims, eusx_locked)
  - APY/Percentages: 1-2 decimals (most at 2dp, amm metrics at 1dp)
  - PT Base Price: 4 decimals (PT value in underlying terms, approaches 1.0 at maturity)
  - Ratios: 2 decimals (sy_coll_ratio_mkt1/mkt2, eusx_collateralization_ratio)
  - Discount Rate: 2 decimals (percentage basis)
  - AMM Price Impact: 2 decimals (basis points and percentage)
  - AMM Metrics: 1 decimal (amm_share_sy_pct, amm_pct_of_sy_claims)

Example usage:
  -- Backward compatible (via wrapper view): use recency-based market selection
  SELECT * FROM exponent.v_exponent_last;

  -- Function call (default mode): same as wrapper view
  SELECT * FROM exponent.get_view_exponent_last();

  -- Function call (explicit mode): select specific markets by meta_pt_name
  SELECT * FROM exponent.get_view_exponent_last(
    ''PT-USX-09FEB26'',   -- mkt1
    ''PT-eUSX-11MAR26''   -- mkt2
  );

  -- Check yield metrics (default mode)
  SELECT
    apy_market_mkt1,
    apy_realized_vault_life_mkt1,
    apy_realized_24h,
    apy_divergence_wrt_24h_mkt1
  FROM exponent.v_exponent_last;

  -- Monitor collateralization
  SELECT
    vault_address_mkt1,
    sy_coll_ratio_mkt1,
    eusx_collateralization_ratio
  FROM exponent.v_exponent_last;

  -- Compare market pricing vs realized yield
  SELECT
    vault_address_mkt1,
    apy_market_mkt1 AS market_expectation,
    apy_realized_24h AS actual_24h_yield,
    apy_divergence_wrt_24h_mkt1 AS divergence
  FROM exponent.v_exponent_last;

  -- Check AMM liquidity depth via price impact (100000 PT trade)
  SELECT
    vault_address_mkt1,
    vault_address_mkt2,
    amm_impact_trade_size_pt AS trade_size_pt,
    amm_price_impact_mkt1_pct AS impact_mkt1_pct,
    amm_price_impact_mkt2_pct AS impact_mkt2_pct,
    amm_yield_impact_mkt1_pct AS apy_impact_mkt1_ppts,
    amm_yield_impact_mkt2_pct AS apy_impact_mkt2_ppts,
    amm_depth_in_sy_mkt1,
    amm_depth_in_sy_mkt2
  FROM exponent.v_exponent_last;';

-- =============================================================================
-- WRAPPER VIEW: v_exponent_last
-- =============================================================================
-- Provides backward compatibility for existing queries using VIEW syntax
-- Calls the function with default parameters (NULL, NULL) for recency-based selection

CREATE OR REPLACE VIEW exponent.v_exponent_last AS
SELECT * FROM exponent.get_view_exponent_last();

COMMENT ON VIEW exponent.v_exponent_last IS
'Wrapper view for backward compatibility. Calls get_view_exponent_last() with default parameters.
For parameterized access (explicit market selection), use the function directly:
  SELECT * FROM exponent.get_view_exponent_last(''PT-USX-09FEB26'', ''PT-eUSX-11MAR26'');';
