-- Kamino Lend - Liquidation Cascade Amplification Simulation
--
-- Models second-order effects of collateral liquidation on DEX pools:
--   1. An exogenous price shock makes some loans unhealthy
--   2. Unhealthy collateral is seized and sold on the DEX pool
--   3. The sell pressure pushes the collateral price down further
--   4. The additional price drop makes more loans unhealthy
--   5. Repeat until equilibrium (fixed-point convergence)
--
-- Covers BOTH sides of the sensitivity curve:
--
--   LEFT SIDE (collateral decrease):
--     Single-axis cascade. Exogenous collateral decline -> liquidations -> more
--     collateral sold -> collateral drops further. The cascade stays on the same
--     axis. equilibrium_shock_pct reflects the total collateral decline.
--
--   RIGHT SIDE (debt value increase):
--     Cross-axis cascade. Exogenous debt increase -> liquidations -> collateral
--     sold on DEX -> collateral price DROPS (different axis). The induced collateral
--     decline can trigger additional liquidations beyond those from the debt increase.
--     induced_coll_decline_pct captures this cross-axis effect.
--
--     The combined sell pressure is conservatively estimated as:
--       L_total = L_debt(X%) + L_coll(induced_decline%)
--     This may overcount obligations unhealthy from both effects simultaneously,
--     making it a worst-case upper-bound estimate (consistent with the 100% sale
--     assumption used throughout).
--
-- Convergence is guaranteed because the sensitivity curve (liquidatable_value)
-- is monotonically increasing but bounded by total market borrowing.
--
-- IMPORTANT: For physically meaningful results, p_coll_assets should target the
-- specific collateral symbol being modeled (e.g., ARRAY['ONyc']), not all assets.
-- When all assets are stressed uniformly, the cascade from a single asset's DEX
-- impact understates the true amplification.
--
-- Parameters:
--   (Sensitivity pass-through)
--   p_query_id, assets_delta_bps, assets_delta_steps, liabilities_delta_bps,
--   liabilities_delta_steps, include_zero_borrows, p_coll_assets, p_lend_assets
--
--   (Cascade-specific)
--   p_coll_symbol: Which collateral token to model cascade for (resolved via resolve_dex_pool)
--   p_max_rounds: Maximum iteration rounds (default 10)
--   p_convergence_threshold_pct: Stop when shock changes < this % (default 0.1)

DROP FUNCTION IF EXISTS kamino_lend.simulate_cascade_amplification(
    BIGINT, INTEGER, INTEGER, INTEGER, INTEGER, BOOLEAN, TEXT[], TEXT[],
    TEXT, INTEGER, NUMERIC
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
    liq_pct_of_deposits       NUMERIC
) AS $$
DECLARE
    v_pool_address     TEXT;
    v_token_side       TEXT;
    v_token_price      NUMERIC;
    v_sign_multiplier  NUMERIC;
    -- Pool depth
    v_pool_depth_tokens NUMERIC;
    -- Total deposits at baseline
    v_total_deposits   NUMERIC;
    -- Left-side curve arrays (sorted ascending: most negative first)
    v_left_pct         NUMERIC[];
    v_left_liq         NUMERIC[];
    v_left_n           INTEGER;
    -- Right-side curve arrays (sorted ascending: 0 first, most positive last)
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
    v_bps              DOUBLE PRECISION;
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
    -- 1. Resolve DEX pool for the collateral symbol
    -- ---------------------------------------------------------------
    IF p_coll_symbol IS NOT NULL THEN
        SELECT rdp.pool_address, rdp.token_side
        INTO v_pool_address, v_token_side
        FROM kamino_lend.resolve_dex_pool(p_coll_symbol) rdp;
    END IF;

    IF v_pool_address IS NULL THEN
        RETURN QUERY
        SELECT
            s.pct_change                          AS initial_shock_pct,
            s.pct_change                          AS equilibrium_shock_pct,
            1.0::NUMERIC                          AS amplification_factor,
            0                                     AS cascade_rounds,
            0.0::NUMERIC                          AS cascade_impact_pct,
            s.total_liquidatable_value::NUMERIC   AS total_liquidated_usd,
            0.0::NUMERIC                          AS induced_coll_decline_pct,
            s.total_liquidatable_value::NUMERIC   AS debt_triggered_liq_usd,
            0.0::NUMERIC                          AS cascade_triggered_liq_usd,
            0.0::NUMERIC                          AS sell_qty_tokens,
            0.0::NUMERIC                          AS pool_depth_used_pct,
            0.0::NUMERIC                          AS liq_pct_of_deposits
        FROM kamino_lend.get_view_klend_sensitivities(
            p_query_id, p_assets_delta_bps, p_assets_delta_steps,
            p_liabilities_delta_bps, p_liabilities_delta_steps,
            p_include_zero_borrows, p_coll_assets, p_lend_assets
        ) s
        ORDER BY s.pct_change;
        RETURN;
    END IF;

    v_sign_multiplier := CASE WHEN v_token_side = 't0' THEN 1.0 ELSE -1.0 END;

    -- ---------------------------------------------------------------
    -- 2. Get current token price from Kamino oracle CAGG
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
    -- 2b. Get DEX pool total downside depth (max tokens sellable before exhaustion)
    -- ---------------------------------------------------------------
    IF v_token_side = 't0' THEN
        SELECT MAX(token0_sold_cumul) INTO v_pool_depth_tokens
        FROM dexes.src_acct_tickarray_tokendist_latest
        WHERE pool_address = v_pool_address;
    ELSE
        SELECT MAX(token1_sold_cumul) INTO v_pool_depth_tokens
        FROM dexes.src_acct_tickarray_tokendist_latest
        WHERE pool_address = v_pool_address;
    END IF;
    v_pool_depth_tokens := COALESCE(v_pool_depth_tokens, 0);

    -- ---------------------------------------------------------------
    -- 2c. Get total deposits at baseline (pct_change = 0) for ratio context
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
    -- 3. Materialize BOTH sides of the sensitivity curve
    -- ---------------------------------------------------------------
    -- Left side: collateral decrease (pct_change <= 0, ascending)
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

    -- Right side: debt increase (pct_change > 0, ascending)
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
            RETURN NEXT;
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

            v_qty := (v_liq_value / v_token_price)::DOUBLE PRECISION;
            IF v_qty <= 0 THEN EXIT; END IF;

            v_bps := dexes.impact_bps_from_qsell_latest(
                v_pool_address, v_token_side, v_qty
            );
            IF v_bps IS NULL THEN EXIT; END IF;

            v_cascade_pct := (v_bps::NUMERIC / 100.0) * v_sign_multiplier;
            v_prev_shock  := v_shock;
            v_shock       := initial_shock_pct + v_cascade_pct;

            IF ABS(v_shock - v_prev_shock) < p_convergence_threshold_pct THEN EXIT; END IF;
            IF v_round >= p_max_rounds THEN EXIT; END IF;
        END LOOP;

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
        sell_qty_tokens           := ROUND(v_liq_value / v_token_price, 0);
        pool_depth_used_pct       := CASE WHEN v_pool_depth_tokens > 0
            THEN ROUND((v_liq_value / v_token_price) / v_pool_depth_tokens * 100, 1)
            ELSE NULL END;
        liq_pct_of_deposits       := CASE WHEN v_total_deposits > 0
            THEN ROUND(v_liq_value / v_total_deposits * 100, 2)
            ELSE NULL END;

        RETURN NEXT;
    END LOOP;

    -- ---------------------------------------------------------------
    -- 5. RIGHT SIDE: cross-axis cascade (debt increase -> collateral sold)
    --
    --    Iteration:
    --      L_debt = liquidatable from debt increase (right-side curve, fixed)
    --      coll_decline = 0
    --      repeat:
    --        L_coll = liquidatable at coll_decline (left-side curve)
    --        L_total = L_debt + L_coll  (conservative upper bound)
    --        qty = L_total / token_price
    --        bps = DEX_impact(qty) -> new coll_decline
    --        converge
    --
    --    The sum L_debt + L_coll is a worst-case estimate: some obligations
    --    may be counted in both (unhealthy from debt AND collateral effects).
    --    This is consistent with the conservative 100% sale assumption.
    -- ---------------------------------------------------------------
    FOR v_idx IN 1..v_right_n LOOP
        initial_shock_pct := v_right_pct[v_idx];
        v_l_debt          := v_right_liq[v_idx];
        v_coll_decline    := 0;
        v_round           := 0;
        v_liq_value       := v_l_debt;

        IF v_l_debt <= 0 THEN
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
            RETURN NEXT;
            CONTINUE;
        END IF;

        LOOP
            v_round := v_round + 1;

            -- Interpolate L_coll from LEFT-side curve at v_coll_decline
            -- v_coll_decline is negative (collateral drops)
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

            v_qty := (v_liq_value / v_token_price)::DOUBLE PRECISION;
            IF v_qty <= 0 THEN EXIT; END IF;

            v_bps := dexes.impact_bps_from_qsell_latest(
                v_pool_address, v_token_side, v_qty
            );
            IF v_bps IS NULL THEN EXIT; END IF;

            v_prev_coll_decline := v_coll_decline;
            v_coll_decline      := (v_bps::NUMERIC / 100.0) * v_sign_multiplier;

            IF ABS(v_coll_decline - v_prev_coll_decline) < p_convergence_threshold_pct THEN EXIT; END IF;
            IF v_round >= p_max_rounds THEN EXIT; END IF;
        END LOOP;

        equilibrium_shock_pct     := initial_shock_pct;
        amplification_factor      := 1.0;
        cascade_rounds            := v_round;
        cascade_impact_pct        := 0;
        total_liquidated_usd      := ROUND(v_liq_value, 0);
        induced_coll_decline_pct  := ROUND(v_coll_decline, 3);
        debt_triggered_liq_usd    := ROUND(v_l_debt, 0);
        cascade_triggered_liq_usd := ROUND(GREATEST(v_l_coll, 0), 0);
        sell_qty_tokens           := ROUND(v_liq_value / v_token_price, 0);
        pool_depth_used_pct       := CASE WHEN v_pool_depth_tokens > 0
            THEN ROUND((v_liq_value / v_token_price) / v_pool_depth_tokens * 100, 1)
            ELSE NULL END;
        liq_pct_of_deposits       := CASE WHEN v_total_deposits > 0
            THEN ROUND(v_liq_value / v_total_deposits * 100, 2)
            ELSE NULL END;

        RETURN NEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql STABLE
SET search_path TO kamino_lend, dexes, public;

COMMENT ON FUNCTION kamino_lend.simulate_cascade_amplification(
    BIGINT, INTEGER, INTEGER, INTEGER, INTEGER, BOOLEAN, TEXT[], TEXT[],
    TEXT, INTEGER, NUMERIC
) IS
'Simulates liquidation cascade amplification for a collateral token across both sides
of the sensitivity curve.

LEFT SIDE (collateral decrease): Single-axis cascade. Exogenous collateral decline
triggers liquidations, selling collateral on DEX pushes price down further, creating
a feedback loop on the same axis. Returns equilibrium_shock_pct > initial_shock_pct.
cascade_triggered_liq_usd = total (all liquidations arise from collateral decline).

RIGHT SIDE (debt increase): Cross-axis cascade. Exogenous debt increase triggers
liquidations. Selling seized collateral on DEX pushes collateral price down (different
axis). The induced collateral decline can trigger additional liquidations. The combined
sell pressure is conservatively estimated as L_debt + L_coll (worst-case upper bound).
debt_triggered_liq_usd = from debt increase alone; cascade_triggered_liq_usd = additional
from the induced collateral decline. induced_coll_decline_pct shows collateral impact.

NOTE: induced_coll_decline_pct may saturate when sell quantity exceeds the DEX pool
total available liquidity depth. This represents a real constraint, not a precision issue.

Requires DEX liquidity data in dexes.src_acct_tickarray_tokendist_latest and the
collateral symbol in dexes.pool_tokens_reference.';
