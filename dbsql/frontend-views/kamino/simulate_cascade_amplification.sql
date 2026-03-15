-- Kamino Lend - Liquidation Cascade Amplification Simulation (Multi-Pool)
--
-- Models second-order effects of collateral liquidation on DEX pools:
--   1. An exogenous price shock makes some loans unhealthy
--   2. Unhealthy collateral is seized and sold on DEX pool(s)
--   3. The sell pressure pushes the collateral price down further
--   4. The additional price drop makes more loans unhealthy
--   5. Repeat until equilibrium (fixed-point convergence)
--
-- MULTI-POOL SUPPORT:
--   A collateral token may trade on multiple DEX pools (e.g. ONyc-USDC and USDG-ONyc).
--   p_pool_mode controls how sell pressure is routed:
--     - A specific pool address: 100% of sell pressure on that pool
--     - 'weighted' (default): sell qty split pro-rata by counter-pair stablecoin
--       liquidity across all pools. Models rational liquidators minimizing slippage.
--
--   ASSUMPTION: Counter-pair stablecoins (e.g. USDC, USDG) are treated at nominal
--   face value ($1) and therefore at par with each other for liquidity weighting.
--   This simplifies cross-pool weighting to a direct comparison of counter-pair
--   token quantities without requiring additional price feeds.
--
--   In weighted mode, the effective price impact is the liquidity-weighted average
--   of per-pool BPS impacts. This approximates the market-wide price effect under
--   the assumption that arbitrageurs keep prices aligned across pools.
--
-- Covers BOTH sides of the sensitivity curve:
--
--   LEFT SIDE (collateral decrease):
--     Single-axis cascade. Exogenous collateral decline -> liquidations -> more
--     collateral sold -> collateral drops further. equilibrium_shock_pct reflects
--     the total collateral decline.
--
--   RIGHT SIDE (debt value increase):
--     Cross-axis cascade. Exogenous debt increase -> liquidations -> collateral
--     sold on DEX -> collateral price DROPS (different axis).
--     induced_coll_decline_pct captures this cross-axis effect.
--     Combined sell pressure: L_total = L_debt + L_coll (conservative upper bound).
--
-- Parameters:
--   (Sensitivity pass-through)
--   p_query_id, assets_delta_bps, assets_delta_steps, liabilities_delta_bps,
--   liabilities_delta_steps, include_zero_borrows, p_coll_assets, p_lend_assets
--
--   (Cascade-specific)
--   p_coll_symbol: Which collateral token to model cascade for
--   p_pool_mode: Pool routing - 'weighted' (default) or a specific pool address
--   p_max_rounds: Maximum iteration rounds (default 10)
--   p_convergence_threshold_pct: Stop when shock changes < this % (default 0.1)

DROP FUNCTION IF EXISTS kamino_lend.simulate_cascade_amplification(
    BIGINT, INTEGER, INTEGER, INTEGER, INTEGER, BOOLEAN, TEXT[], TEXT[],
    TEXT, INTEGER, NUMERIC
);
DROP FUNCTION IF EXISTS kamino_lend.simulate_cascade_amplification(
    BIGINT, INTEGER, INTEGER, INTEGER, INTEGER, BOOLEAN, TEXT[], TEXT[],
    TEXT, TEXT, INTEGER, NUMERIC
);

CREATE OR REPLACE FUNCTION kamino_lend.simulate_cascade_amplification(
    -- Sensitivity pass-through parameters
    p_query_id                  BIGINT   DEFAULT NULL,
    p_assets_delta_bps          INTEGER  DEFAULT -100,
    p_assets_delta_steps        INTEGER  DEFAULT 50,
    p_liabilities_delta_bps     INTEGER  DEFAULT 100,
    p_liabilities_delta_steps   INTEGER  DEFAULT 50,
    p_include_zero_borrows      BOOLEAN  DEFAULT FALSE,
    p_coll_assets               TEXT[]   DEFAULT NULL,
    p_lend_assets               TEXT[]   DEFAULT NULL,
    -- Cascade-specific parameters
    p_coll_symbol               TEXT     DEFAULT NULL,
    p_pool_mode                 TEXT     DEFAULT 'weighted',
    p_max_rounds                INTEGER  DEFAULT 10,
    p_convergence_threshold_pct NUMERIC  DEFAULT 0.1
)
RETURNS TABLE (
    initial_shock_pct         NUMERIC,
    equilibrium_shock_pct     NUMERIC,
    amplification_factor      NUMERIC,
    cascade_rounds            INTEGER,
    cascade_impact_pct        NUMERIC,
    total_liquidated_usd      NUMERIC,
    induced_coll_decline_pct  NUMERIC,
    debt_triggered_liq_usd    NUMERIC,
    cascade_triggered_liq_usd NUMERIC,
    sell_qty_tokens           NUMERIC,
    pool_depth_used_pct       NUMERIC,
    liq_pct_of_deposits       NUMERIC,
    coll_tokens_deposited     NUMERIC,
    pool_address              TEXT,
    pool_weight               NUMERIC,
    counter_pair_symbol       TEXT,
    pool_impact_pct           NUMERIC
) AS $$
DECLARE
    v_token_price      NUMERIC;
    -- Multi-pool: parallel arrays
    v_pool_addresses   TEXT[];
    v_pool_sides       TEXT[];
    v_pool_weights     NUMERIC[];
    v_pool_depths      NUMERIC[];
    v_pool_counter_sym TEXT[];
    v_n_pools          INTEGER;
    v_p                INTEGER;
    -- Per-pool BPS after convergence (sign-corrected to collateral-decline direction)
    v_pool_bps_arr     DOUBLE PRECISION[];
    -- Temporaries for pool setup
    v_cp_values        NUMERIC[];
    v_cp_total         NUMERIC;
    v_depth_tmp        NUMERIC;
    v_cp_val           NUMERIC;
    -- Total deposits at baseline
    v_total_deposits   NUMERIC;
    -- Collateral token quantities
    v_coll_tokens_deposited NUMERIC;
    v_token_decimals   INTEGER;
    v_reserve_address  TEXT;
    -- Left-side curve arrays
    v_left_pct         NUMERIC[];
    v_left_liq         NUMERIC[];
    v_left_n           INTEGER;
    -- Right-side curve arrays
    v_right_pct        NUMERIC[];
    v_right_liq        NUMERIC[];
    v_right_n          INTEGER;
    -- Outer loop
    v_idx              INTEGER;
    -- Fixed-point iteration
    v_shock            NUMERIC;
    v_prev_shock       NUMERIC;
    v_liq_value        NUMERIC;
    v_qty              DOUBLE PRECISION;
    v_pool_qty         DOUBLE PRECISION;
    v_agg_bps          DOUBLE PRECISION;
    v_pool_bps         DOUBLE PRECISION;
    v_cascade_pct      NUMERIC;
    v_round            INTEGER;
    -- Right-side specific
    v_l_debt           NUMERIC;
    v_l_coll           NUMERIC;
    v_coll_decline     NUMERIC;
    v_prev_coll_decline NUMERIC;
    -- Linear interpolation
    v_lo               INTEGER;
    v_hi               INTEGER;
    v_frac             NUMERIC;
    j                  INTEGER;
BEGIN
    -- ---------------------------------------------------------------
    -- 1. Resolve DEX pool(s) for the collateral symbol
    -- ---------------------------------------------------------------
    IF p_coll_symbol IS NULL THEN
        -- No cascade: return raw sensitivity curve
        RETURN QUERY
        SELECT
            s.pct_change, s.pct_change, 1.0::NUMERIC, 0, 0.0::NUMERIC,
            s.total_liquidatable_value::NUMERIC, 0.0::NUMERIC,
            s.total_liquidatable_value::NUMERIC, 0.0::NUMERIC,
            0.0::NUMERIC, 0.0::NUMERIC, 0.0::NUMERIC, NULL::NUMERIC,
            NULL::TEXT, NULL::NUMERIC, NULL::TEXT, NULL::NUMERIC
        FROM kamino_lend.get_view_klend_sensitivities(
            p_query_id, p_assets_delta_bps, p_assets_delta_steps,
            p_liabilities_delta_bps, p_liabilities_delta_steps,
            p_include_zero_borrows, p_coll_assets, p_lend_assets
        ) s
        ORDER BY s.pct_change;
        RETURN;
    END IF;

    IF p_pool_mode IS NOT NULL AND p_pool_mode != 'weighted' THEN
        -- Single specific pool
        SELECT ARRAY[rdp.pool_address], ARRAY[rdp.token_side],
               ARRAY[CASE WHEN rdp.token_side = 't0' THEN rdp.token1_symbol
                          ELSE rdp.token0_symbol END]
        INTO v_pool_addresses, v_pool_sides, v_pool_counter_sym
        FROM kamino_lend.resolve_dex_pool(p_coll_symbol) rdp
        WHERE rdp.pool_address = p_pool_mode
        LIMIT 1;

        IF v_pool_addresses IS NULL THEN
            RAISE EXCEPTION 'Pool % not found for symbol %', p_pool_mode, p_coll_symbol;
        END IF;

        v_pool_weights := ARRAY[1.0];
        v_n_pools := 1;
    ELSE
        -- Weighted mode: resolve ALL pools for this symbol
        SELECT
            array_agg(rdp.pool_address),
            array_agg(rdp.token_side),
            array_agg(CASE WHEN rdp.token_side = 't0' THEN rdp.token1_symbol
                           ELSE rdp.token0_symbol END)
        INTO v_pool_addresses, v_pool_sides, v_pool_counter_sym
        FROM kamino_lend.resolve_dex_pool(p_coll_symbol) rdp;

        v_n_pools := COALESCE(array_length(v_pool_addresses, 1), 0);

        IF v_n_pools = 0 THEN
            -- No pools found: return raw sensitivity curve
            RETURN QUERY
            SELECT
                s.pct_change, s.pct_change, 1.0::NUMERIC, 0, 0.0::NUMERIC,
                s.total_liquidatable_value::NUMERIC, 0.0::NUMERIC,
                s.total_liquidatable_value::NUMERIC, 0.0::NUMERIC,
                0.0::NUMERIC, 0.0::NUMERIC, 0.0::NUMERIC, NULL::NUMERIC,
                NULL::TEXT, NULL::NUMERIC, NULL::TEXT, NULL::NUMERIC
            FROM kamino_lend.get_view_klend_sensitivities(
                p_query_id, p_assets_delta_bps, p_assets_delta_steps,
                p_liabilities_delta_bps, p_liabilities_delta_steps,
                p_include_zero_borrows, p_coll_assets, p_lend_assets
            ) s
            ORDER BY s.pct_change;
            RETURN;
        END IF;

        -- Compute counter-pair liquidity weights.
        -- ASSUMPTION: USDC, USDG, and other stablecoins are at par ($1 face value).
        -- Weight = pool's counter-pair token value / total across all pools.
        v_cp_values := ARRAY[]::NUMERIC[];
        v_cp_total  := 0;

        FOR v_p IN 1..v_n_pools LOOP
            IF v_pool_sides[v_p] = 't0' THEN
                -- Collateral is t0 -> counter-pair is t1
                SELECT COALESCE(SUM(td.token1_value), 0) INTO v_cp_val
                FROM dexes.src_acct_tickarray_tokendist_latest td
                WHERE td.pool_address = v_pool_addresses[v_p];
            ELSE
                -- Collateral is t1 -> counter-pair is t0
                SELECT COALESCE(SUM(td.token0_value), 0) INTO v_cp_val
                FROM dexes.src_acct_tickarray_tokendist_latest td
                WHERE td.pool_address = v_pool_addresses[v_p];
            END IF;
            v_cp_values := v_cp_values || v_cp_val;
            v_cp_total  := v_cp_total + v_cp_val;
        END LOOP;

        -- Normalize to weights (0..1)
        IF v_cp_total > 0 THEN
            v_pool_weights := ARRAY[]::NUMERIC[];
            FOR v_p IN 1..v_n_pools LOOP
                v_pool_weights := v_pool_weights || (v_cp_values[v_p] / v_cp_total);
            END LOOP;
        ELSE
            -- Equal weights if no liquidity data
            v_pool_weights := ARRAY[]::NUMERIC[];
            FOR v_p IN 1..v_n_pools LOOP
                v_pool_weights := v_pool_weights || (1.0 / v_n_pools);
            END LOOP;
        END IF;
    END IF;

    -- ---------------------------------------------------------------
    -- 2. Per-pool downside depth
    -- ---------------------------------------------------------------
    v_pool_depths := ARRAY[]::NUMERIC[];
    FOR v_p IN 1..v_n_pools LOOP
        IF v_pool_sides[v_p] = 't0' THEN
            SELECT COALESCE(MAX(td.token0_sold_cumul), 0) INTO v_depth_tmp
            FROM dexes.src_acct_tickarray_tokendist_latest td
            WHERE td.pool_address = v_pool_addresses[v_p];
        ELSE
            SELECT COALESCE(MAX(td.token1_sold_cumul), 0) INTO v_depth_tmp
            FROM dexes.src_acct_tickarray_tokendist_latest td
            WHERE td.pool_address = v_pool_addresses[v_p];
        END IF;
        v_pool_depths := v_pool_depths || v_depth_tmp;
    END LOOP;

    -- ---------------------------------------------------------------
    -- 2b. Get current token price from Kamino oracle CAGG
    -- ---------------------------------------------------------------
    SELECT cr.market_price INTO v_token_price
    FROM kamino_lend.cagg_reserves_5s cr
    WHERE cr.symbol = p_coll_symbol
    ORDER BY cr.bucket DESC
    LIMIT 1;

    IF v_token_price IS NULL OR v_token_price <= 0 THEN
        RAISE EXCEPTION 'No valid market_price found in cagg_reserves_5s for symbol %', p_coll_symbol;
    END IF;

    -- ---------------------------------------------------------------
    -- 2c. Get total deposits at baseline (pct_change = 0)
    -- ---------------------------------------------------------------
    SELECT s.total_deposits INTO v_total_deposits
    FROM kamino_lend.get_view_klend_sensitivities(
        p_query_id, p_assets_delta_bps, p_assets_delta_steps,
        p_liabilities_delta_bps, p_liabilities_delta_steps,
        p_include_zero_borrows, p_coll_assets, p_lend_assets
    ) s
    WHERE s.pct_change = 0.0
    LIMIT 1;
    v_total_deposits := COALESCE(v_total_deposits, 0);

    -- ---------------------------------------------------------------
    -- 2d. Collateral token quantities from obligation deposit data
    -- ---------------------------------------------------------------
    SELECT mrt.reserve_address, mrt.token_decimals
    INTO v_reserve_address, v_token_decimals
    FROM kamino_lend.aux_market_reserve_tokens mrt
    WHERE mrt.token_symbol = p_coll_symbol
      AND mrt.env_market_address_matches = TRUE
    LIMIT 1;

    IF v_reserve_address IS NOT NULL THEN
        SELECT COALESCE(SUM(
            dep_amt::NUMERIC / POW(10, v_token_decimals)
        ), 0) INTO v_coll_tokens_deposited
        FROM kamino_lend.src_obligations_last o,
             LATERAL unnest(o.deposit_reserve_by_asset, o.deposited_amount_by_asset)
                 AS t(dep_addr, dep_amt)
        WHERE o.c_user_total_borrow >= 1
          AND dep_addr = v_reserve_address;
    ELSE
        v_coll_tokens_deposited := 0;
    END IF;

    -- ---------------------------------------------------------------
    -- 3. Materialize BOTH sides of the sensitivity curve
    -- ---------------------------------------------------------------
    SELECT
        array_agg(s.pct_change ORDER BY s.pct_change),
        array_agg(s.total_liquidatable_value::NUMERIC ORDER BY s.pct_change)
    INTO v_left_pct, v_left_liq
    FROM kamino_lend.get_view_klend_sensitivities(
        p_query_id, p_assets_delta_bps, p_assets_delta_steps,
        p_liabilities_delta_bps, p_liabilities_delta_steps,
        p_include_zero_borrows, p_coll_assets, p_lend_assets
    ) s
    WHERE s.pct_change <= 0;

    v_left_n := COALESCE(array_length(v_left_pct, 1), 0);

    SELECT
        array_agg(s.pct_change ORDER BY s.pct_change),
        array_agg(s.total_liquidatable_value::NUMERIC ORDER BY s.pct_change)
    INTO v_right_pct, v_right_liq
    FROM kamino_lend.get_view_klend_sensitivities(
        p_query_id, p_assets_delta_bps, p_assets_delta_steps,
        p_liabilities_delta_bps, p_liabilities_delta_steps,
        p_include_zero_borrows, p_coll_assets, p_lend_assets
    ) s
    WHERE s.pct_change > 0;

    v_right_n := COALESCE(array_length(v_right_pct, 1), 0);

    -- ---------------------------------------------------------------
    -- 4. LEFT SIDE: single-axis cascade (collateral decrease)
    -- ---------------------------------------------------------------
    FOR v_idx IN 1..v_left_n LOOP
        initial_shock_pct := v_left_pct[v_idx];

        IF initial_shock_pct = 0 THEN
            FOR v_p IN 1..v_n_pools LOOP
                equilibrium_shock_pct     := 0;
                amplification_factor      := 1.0;
                cascade_rounds            := 0;
                cascade_impact_pct        := 0;
                total_liquidated_usd      := v_left_liq[v_idx];
                induced_coll_decline_pct  := 0;
                debt_triggered_liq_usd    := 0;
                cascade_triggered_liq_usd := 0;
                sell_qty_tokens           := 0;
                pool_depth_used_pct       := 0;
                liq_pct_of_deposits       := 0;
                coll_tokens_deposited     := v_coll_tokens_deposited;
                pool_address              := v_pool_addresses[v_p];
                pool_weight               := ROUND(v_pool_weights[v_p], 4);
                counter_pair_symbol       := v_pool_counter_sym[v_p];
                pool_impact_pct           := 0;
                RETURN NEXT;
            END LOOP;
            CONTINUE;
        END IF;

        v_shock := initial_shock_pct;
        v_round := 0;

        LOOP
            v_round := v_round + 1;

            -- Interpolate liquidatable value from left-side curve
            IF v_shock <= v_left_pct[1] THEN
                v_liq_value := v_left_liq[1];
            ELSIF v_shock >= v_left_pct[v_left_n] THEN
                v_liq_value := v_left_liq[v_left_n];
            ELSE
                v_lo := 1;
                FOR j IN 1..v_left_n - 1 LOOP
                    IF v_left_pct[j] <= v_shock AND v_left_pct[j + 1] >= v_shock THEN
                        v_lo := j;
                        EXIT;
                    END IF;
                END LOOP;
                v_hi := v_lo + 1;
                IF v_left_pct[v_hi] = v_left_pct[v_lo] THEN
                    v_frac := 0;
                ELSE
                    v_frac := (v_shock - v_left_pct[v_lo])
                            / (v_left_pct[v_hi] - v_left_pct[v_lo]);
                END IF;
                v_liq_value := v_left_liq[v_lo]
                             + v_frac * (v_left_liq[v_hi] - v_left_liq[v_lo]);
            END IF;

            v_qty := (v_liq_value * v_coll_tokens_deposited / NULLIF(v_total_deposits, 0))::DOUBLE PRECISION;
            IF v_qty <= 0 THEN EXIT; END IF;

            -- Weighted-average BPS across pools. Also store per-pool BPS
            -- (sign-corrected to collateral-decline direction) for output.
            v_agg_bps := 0;
            v_pool_bps_arr := ARRAY[]::DOUBLE PRECISION[];
            FOR v_p IN 1..v_n_pools LOOP
                v_pool_qty := v_qty * v_pool_weights[v_p]::DOUBLE PRECISION;
                IF v_pool_qty > 0 THEN
                    v_pool_bps := dexes.impact_bps_from_qsell_latest(
                        v_pool_addresses[v_p], v_pool_sides[v_p], v_pool_qty
                    );
                    IF v_pool_bps IS NOT NULL THEN
                        -- impact_bps returns signed BPS on pool's native t1/t0 basis:
                        --   t0 sell -> negative BPS, t1 sell -> positive BPS
                        -- Normalize to collateral-decline direction (negative = decline).
                        v_pool_bps := v_pool_bps * CASE WHEN v_pool_sides[v_p] = 't0' THEN 1.0 ELSE -1.0 END;
                        v_agg_bps := v_agg_bps + v_pool_bps * v_pool_weights[v_p]::DOUBLE PRECISION;
                        v_pool_bps_arr := v_pool_bps_arr || v_pool_bps;
                    ELSE
                        v_pool_bps_arr := v_pool_bps_arr || 0::DOUBLE PRECISION;
                    END IF;
                ELSE
                    v_pool_bps_arr := v_pool_bps_arr || 0::DOUBLE PRECISION;
                END IF;
            END LOOP;

            v_cascade_pct := (v_agg_bps::NUMERIC / 100.0);
            v_prev_shock  := v_shock;
            v_shock       := initial_shock_pct + v_cascade_pct;

            IF ABS(v_shock - v_prev_shock) < p_convergence_threshold_pct THEN EXIT; END IF;
            IF v_round >= p_max_rounds THEN EXIT; END IF;
        END LOOP;

        FOR v_p IN 1..v_n_pools LOOP
            equilibrium_shock_pct     := ROUND(v_shock, 3);
            cascade_impact_pct        := ROUND(v_shock - initial_shock_pct, 3);
            induced_coll_decline_pct  := cascade_impact_pct;
            amplification_factor      := CASE
                WHEN initial_shock_pct != 0
                THEN ROUND(v_shock / initial_shock_pct, 4)
                ELSE 1.0
            END;
            cascade_rounds            := v_round;
            total_liquidated_usd      := ROUND(v_liq_value, 0);
            debt_triggered_liq_usd    := 0;
            cascade_triggered_liq_usd := ROUND(v_liq_value, 0);

            -- Per-pool: this pool's share of the total sell
            sell_qty_tokens := ROUND(
                v_liq_value * v_coll_tokens_deposited / NULLIF(v_total_deposits, 0)
                * v_pool_weights[v_p], 0
            );
            pool_depth_used_pct := CASE WHEN v_pool_depths[v_p] > 0 THEN ROUND(
                (v_liq_value * v_coll_tokens_deposited / NULLIF(v_total_deposits, 0)
                 * v_pool_weights[v_p]) / v_pool_depths[v_p] * 100, 1
            ) ELSE NULL END;
            liq_pct_of_deposits := CASE WHEN v_total_deposits > 0
                THEN ROUND(v_liq_value / v_total_deposits * 100, 2)
                ELSE NULL END;
            coll_tokens_deposited := v_coll_tokens_deposited;
            pool_address          := v_pool_addresses[v_p];
            pool_weight           := ROUND(v_pool_weights[v_p], 4);
            counter_pair_symbol   := v_pool_counter_sym[v_p];
            pool_impact_pct       := CASE
                WHEN v_pool_bps_arr IS NOT NULL AND array_length(v_pool_bps_arr, 1) >= v_p
                THEN ROUND((v_pool_bps_arr[v_p]::NUMERIC / 100.0), 3)
                ELSE 0 END;

            RETURN NEXT;
        END LOOP;
    END LOOP;

    -- ---------------------------------------------------------------
    -- 5. RIGHT SIDE: cross-axis cascade (debt increase -> collateral sold)
    -- ---------------------------------------------------------------
    FOR v_idx IN 1..v_right_n LOOP
        initial_shock_pct := v_right_pct[v_idx];
        v_l_debt          := v_right_liq[v_idx];
        v_coll_decline    := 0;
        v_round           := 0;
        v_liq_value       := v_l_debt;

        IF v_l_debt <= 0 THEN
            FOR v_p IN 1..v_n_pools LOOP
                equilibrium_shock_pct     := initial_shock_pct;
                amplification_factor      := 1.0;
                cascade_rounds            := 0;
                cascade_impact_pct        := 0;
                total_liquidated_usd      := 0;
                induced_coll_decline_pct  := 0;
                debt_triggered_liq_usd    := 0;
                cascade_triggered_liq_usd := 0;
                sell_qty_tokens           := 0;
                pool_depth_used_pct       := 0;
                liq_pct_of_deposits       := 0;
                coll_tokens_deposited     := v_coll_tokens_deposited;
                pool_address              := v_pool_addresses[v_p];
                pool_weight               := ROUND(v_pool_weights[v_p], 4);
                counter_pair_symbol       := v_pool_counter_sym[v_p];
                pool_impact_pct           := 0;
                RETURN NEXT;
            END LOOP;
            CONTINUE;
        END IF;

        LOOP
            v_round := v_round + 1;

            -- Interpolate L_coll from LEFT-side curve at v_coll_decline
            v_l_coll := 0;
            IF v_left_n > 0 AND v_coll_decline < 0 THEN
                IF v_coll_decline <= v_left_pct[1] THEN
                    v_l_coll := v_left_liq[1];
                ELSIF v_coll_decline >= v_left_pct[v_left_n] THEN
                    v_l_coll := v_left_liq[v_left_n];
                ELSE
                    v_lo := 1;
                    FOR j IN 1..v_left_n - 1 LOOP
                        IF v_left_pct[j] <= v_coll_decline AND v_left_pct[j + 1] >= v_coll_decline THEN
                            v_lo := j;
                            EXIT;
                        END IF;
                    END LOOP;
                    v_hi := v_lo + 1;
                    IF v_left_pct[v_hi] = v_left_pct[v_lo] THEN
                        v_frac := 0;
                    ELSE
                        v_frac := (v_coll_decline - v_left_pct[v_lo])
                                / (v_left_pct[v_hi] - v_left_pct[v_lo]);
                    END IF;
                    v_l_coll := v_left_liq[v_lo]
                              + v_frac * (v_left_liq[v_hi] - v_left_liq[v_lo]);
                END IF;
            END IF;

            -- Conservative combined sell pressure
            v_liq_value := v_l_debt + v_l_coll;

            v_qty := (v_liq_value * v_coll_tokens_deposited / NULLIF(v_total_deposits, 0))::DOUBLE PRECISION;
            IF v_qty <= 0 THEN EXIT; END IF;

            v_agg_bps := 0;
            v_pool_bps_arr := ARRAY[]::DOUBLE PRECISION[];
            FOR v_p IN 1..v_n_pools LOOP
                v_pool_qty := v_qty * v_pool_weights[v_p]::DOUBLE PRECISION;
                IF v_pool_qty > 0 THEN
                    v_pool_bps := dexes.impact_bps_from_qsell_latest(
                        v_pool_addresses[v_p], v_pool_sides[v_p], v_pool_qty
                    );
                    IF v_pool_bps IS NOT NULL THEN
                        v_pool_bps := v_pool_bps * CASE WHEN v_pool_sides[v_p] = 't0' THEN 1.0 ELSE -1.0 END;
                        v_agg_bps := v_agg_bps + v_pool_bps * v_pool_weights[v_p]::DOUBLE PRECISION;
                        v_pool_bps_arr := v_pool_bps_arr || v_pool_bps;
                    ELSE
                        v_pool_bps_arr := v_pool_bps_arr || 0::DOUBLE PRECISION;
                    END IF;
                ELSE
                    v_pool_bps_arr := v_pool_bps_arr || 0::DOUBLE PRECISION;
                END IF;
            END LOOP;

            v_prev_coll_decline := v_coll_decline;
            v_coll_decline      := (v_agg_bps::NUMERIC / 100.0);

            IF ABS(v_coll_decline - v_prev_coll_decline) < p_convergence_threshold_pct THEN EXIT; END IF;
            IF v_round >= p_max_rounds THEN EXIT; END IF;
        END LOOP;

        -- Emit one row per pool
        FOR v_p IN 1..v_n_pools LOOP
            equilibrium_shock_pct     := initial_shock_pct;
            amplification_factor      := 1.0;
            cascade_rounds            := v_round;
            cascade_impact_pct        := 0;
            total_liquidated_usd      := ROUND(v_liq_value, 0);
            induced_coll_decline_pct  := ROUND(v_coll_decline, 3);
            debt_triggered_liq_usd    := ROUND(v_l_debt, 0);
            cascade_triggered_liq_usd := ROUND(GREATEST(v_l_coll, 0), 0);

            sell_qty_tokens := ROUND(
                v_liq_value * v_coll_tokens_deposited / NULLIF(v_total_deposits, 0)
                * v_pool_weights[v_p], 0
            );
            pool_depth_used_pct := CASE WHEN v_pool_depths[v_p] > 0 THEN ROUND(
                (v_liq_value * v_coll_tokens_deposited / NULLIF(v_total_deposits, 0)
                 * v_pool_weights[v_p]) / v_pool_depths[v_p] * 100, 1
            ) ELSE NULL END;
            liq_pct_of_deposits := CASE WHEN v_total_deposits > 0
                THEN ROUND(v_liq_value / v_total_deposits * 100, 2)
                ELSE NULL END;
            coll_tokens_deposited := v_coll_tokens_deposited;
            pool_address          := v_pool_addresses[v_p];
            pool_weight           := ROUND(v_pool_weights[v_p], 4);
            counter_pair_symbol   := v_pool_counter_sym[v_p];
            pool_impact_pct       := CASE
                WHEN v_pool_bps_arr IS NOT NULL AND array_length(v_pool_bps_arr, 1) >= v_p
                THEN ROUND((v_pool_bps_arr[v_p]::NUMERIC / 100.0), 3)
                ELSE 0 END;

            RETURN NEXT;
        END LOOP;
    END LOOP;
END;
$$ LANGUAGE plpgsql STABLE
SET search_path TO kamino_lend, dexes, public;

COMMENT ON FUNCTION kamino_lend.simulate_cascade_amplification(
    BIGINT, INTEGER, INTEGER, INTEGER, INTEGER, BOOLEAN, TEXT[], TEXT[],
    TEXT, TEXT, INTEGER, NUMERIC
) IS
'Simulates liquidation cascade amplification for a collateral token across both sides
of the sensitivity curve, with multi-pool support.

POOL MODES:
  p_pool_mode = ''weighted'' (default): sell pressure split pro-rata by counter-pair
  stablecoin liquidity across all DEX pools. Returns one row per pool per shock level.
  p_pool_mode = <pool_address>: 100% sell pressure on a specific pool.

ASSUMPTIONS:
  - Counter-pair stablecoins (USDC, USDG, etc.) treated at $1 face value and at par
    with each other for liquidity weighting purposes.
  - Weighted-average BPS approximates market-wide price impact, assuming arbitrageurs
    keep prices aligned across pools.
  - Rational liquidators split sales across pools to minimize slippage.

LEFT SIDE: Single-axis cascade on collateral decline axis.
RIGHT SIDE: Cross-axis cascade from debt increase to induced collateral decline.
Per-pool rows share cascade-level metrics but have pool-specific sell_qty_tokens
and pool_depth_used_pct.';
