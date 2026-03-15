-- Kamino Lend - Liquidation Cascade Amplification Simulation (Multi-Pool, Bonus-Aware)
--
-- Models second-order effects of collateral liquidation on DEX pools:
--   1. An exogenous price shock makes some loans unhealthy
--   2. Unhealthy collateral is seized and sold on DEX pool(s)
--   3. The sell pressure pushes the collateral price down further
--   4. The additional price drop makes more loans unhealthy
--   5. Repeat until equilibrium (fixed-point convergence)
--
-- LIQUIDATION BONUS GROSS-UP:
--   When a liquidator repays debt, they seize collateral worth debt * (1 + bonus).
--   The bonus depends on obligation state:
--     - Unhealthy (not bad debt): max_liquidation_bonus_bps from reserve config
--     - Bad debt: bad_debt_liquidation_bonus_bps from reserve config
--   p_bonus_mode controls the effective bonus:
--     - 'blended' (default): value-weighted blend of unhealthy and bad-debt bonuses
--       based on per-step composition from the sensitivity curve.
--     - 'max_conservative': flat max_liquidation_bonus_bps for all liquidations,
--       giving an upper-bound estimate of sell pressure (conservative stress mode).
--     - 'none': no bonus applied (legacy behavior).
--
-- BONUS FORMULA (Phase 1a heuristic — market-level aggregate):
--
--   At each shock step, sensitivity outputs provide:
--     total_liquidatable_value = TLV   (all unhealthy + bad-debt obligations)
--     bad_liquidatable_value   = BLV   (bad-debt obligations only)
--
--   bad_share = CLAMP(BLV / TLV, 0, 1)
--   effective_bonus_bps = bad_share * bad_debt_liquidation_bonus_bps
--                       + (1 - bad_share) * max_liquidation_bonus_bps
--
--   collateral_seized_usd = TLV * (1 + effective_bonus_bps / 10000)
--   sell_qty_tokens = collateral_seized_usd * (deposited_tokens / total_deposits_usd)
--     (heuristic mode conversion)
--
--   This heuristic uses max_bonus for all unhealthy obligations, which overstates
--   the bonus for mildly-unhealthy obligations (whose true bonus would be between
--   min_bonus and max_bonus). This conservative bias compounds in the fixed-point
--   loop: more sell pressure -> more impact -> more liquidations -> more sell pressure.
--   Outputs using this heuristic should be understood as upper-bound estimates when
--   the unhealthy share dominates.
--
-- BONUS FORMULA (Phase 3 protocol mode — per-obligation, precomputed curve):
--
--   For each obligation, given reserve params (min_bonus, max_bonus, bad_debt_bonus)
--   and market params (liquidation_ltv, insolvency_risk_ltv):
--
--   IF obligation is bad debt (user_ltv > insolvency_risk_ltv):
--       bonus_bps = bad_debt_liquidation_bonus_bps
--   ELSE (unhealthy, user_ltv between liquidation_ltv and insolvency_risk_ltv):
--       zone_pct = (user_ltv - liquidation_ltv) / (insolvency_risk_ltv - liquidation_ltv)
--       zone_pct = CLAMP(zone_pct, 0, 1)
--       bonus_bps = min_liquidation_bonus_bps
--                 + zone_pct * (max_liquidation_bonus_bps - min_liquidation_bonus_bps)
--
--   This per-obligation formula is implemented in protocol mode via
--   kamino_lend.simulate_protocol_liquidation and consumed by this cascade function.
--   In protocol mode, USD->token conversion uses the live reserve oracle price
--   (tokens_per_usd = 1 / oracle_price) instead of the market-level share proxy.
--
-- PHASE 2 PRE-CHECK (obligation-size distribution):
--   Analysis on 2026-03-11 found that the min_full_liquidation_value_threshold ($2)
--   is currently immaterial for the ONyc market:
--   - Only 19 obligations have borrow < $2 (total borrow: $12)
--   - Under -20% stress, only 1 such obligation becomes unhealthy ($0.01 borrow)
--   - The full-liquidation uplift vs close-factor treatment is < $0.01
--   This threshold can be safely deferred to Phase 3 implementation without
--   impacting current model accuracy.
--
-- RESERVE-SELECTION ASSUMPTIONS:
--   - The bonus parameters are sourced from the p_coll_symbol reserve (matched via
--     env_symbol on kamino_lend.src_reserves). This is correct because the collateral
--     reserve determines the bonus on the collateral leg that gets seized and sold.
--   - For multi-collateral obligations, the protocol selects which collateral to seize
--     based on internal priority logic (lowest-liquidation-LTV-first). This function
--     currently assumes all liquidated collateral is p_coll_symbol, which is valid
--     when p_coll_assets is filtered to a single asset via the sensitivity pass-through.
--   - ONyc reserves currently share identical bonus schedules across all reserves:
--     min=500 BPS, max=1000 BPS, bad_debt=99 BPS. Reserve-selection ambiguity is
--     therefore presently low-impact. This should be re-evaluated if reserve configs
--     diverge in future market updates.
--
-- MULTI-POOL SUPPORT:
--   p_pool_mode controls how sell pressure is routed:
--     - A specific pool address: 100% of sell pressure on that pool
--     - 'weighted' (default): sell qty split pro-rata by counter-pair stablecoin
--       liquidity across all pools. Models rational liquidators minimizing slippage.
--
--   ASSUMPTION: Counter-pair stablecoins (e.g. USDC, USDG) are treated at nominal
--   face value ($1) and therefore at par with each other for liquidity weighting.
--
-- Covers BOTH sides of the sensitivity curve:
--
--   LEFT SIDE (collateral decrease):
--     Single-axis cascade. equilibrium_shock_pct reflects the total collateral decline.
--
--   RIGHT SIDE (debt value increase):
--     Cross-axis cascade. induced_coll_decline_pct captures the effect.
--     Combined sell pressure: L_total = L_debt + L_coll (conservative upper bound).

-- PHASE 3 IMPLEMENTATION SUMMARY (protocol-faithful liquidation engine):
--
--   Target: new function kamino_lend.simulate_protocol_liquidation(...)
--   that replaces the aggregate heuristic with per-obligation mechanics.
--
--   Algorithm per scenario step:
--     1. For each obligation, recompute deposits/borrows under stress
--     2. Classify: healthy / unhealthy / bad-debt (using per-obligation LTV thresholds)
--     3. For unhealthy obligations:
--        a. Determine close factor: if borrow < min_full_liquidation_value_threshold
--           then 100%, else liquidation_max_debt_close_factor_pct
--        b. Select collateral leg: lowest-liquidation-LTV reserve first (protocol priority)
--        c. Select debt leg: highest-borrow-value reserve first
--        d. Compute debt_repaid = MIN(borrow * close_factor, max_liq_at_once)
--        e. Compute bonus_bps via interpolation formula (see Phase 3 formula above)
--        f. Compute collateral_seized = debt_repaid * (1 + bonus_bps / 10000)
--     4. For bad-debt obligations:
--        a. Full liquidation: debt_repaid = MIN(borrow, max_liq_at_once)
--        b. bonus_bps = bad_debt_liquidation_bonus_bps
--        c. collateral_seized = MIN(debt_repaid * (1 + bonus_bps / 10000), deposit)
--     5. Aggregate per-reserve collateral_seized -> sell_qty_tokens per pool
--     6. Feed into DEX impact and fixed-point iteration (same as current cascade)
--
--   Mode flag: p_model_mode = 'heuristic' (current) | 'protocol' (Phase 3)
--   Keep both modes available for diff testing and rollout safety.
--
--   Implementation notes:
--     - Use materialized CTEs staging per-obligation arrays
--     - Prune healthy obligations early to avoid O(n*steps) blowup
--     - Target: 2-3 weeks initial implementation, 1-2 weeks hardening
--
-- PHASE 4 VALIDATION SUMMARY (validation and calibration):
--
--   1. Side-by-side comparison: heuristic vs protocol mode for:
--      total_liquidatable_value, total_liq_value_coll_side, sell_qty_tokens,
--      pool_depth_used_pct, induced price impact
--   2. Backtest against known liquidation windows (on-chain swap events)
--   3. Acceptance thresholds:
--      - Median absolute error for collateral sold < 10% of observed
--      - Monotonicity: increasing stress -> non-decreasing liquidation values
--      - No negative flows: sell_qty_tokens >= 0 at all steps
--      - Fixed-point convergence: all steps converge within p_max_rounds
--   4. Runtime guardrails:
--      - Convergence failure warning if v_round >= p_max_rounds
--      - Negative flow detection and logging
--      - Mode-switch gate: protocol mode becomes default only after passing
--        all acceptance thresholds on live data for 2 consecutive weeks

DROP FUNCTION IF EXISTS kamino_lend.simulate_cascade_amplification(
    BIGINT, INTEGER, INTEGER, INTEGER, INTEGER, BOOLEAN, TEXT[], TEXT[],
    TEXT, INTEGER, NUMERIC
);
DROP FUNCTION IF EXISTS kamino_lend.simulate_cascade_amplification(
    BIGINT, INTEGER, INTEGER, INTEGER, INTEGER, BOOLEAN, TEXT[], TEXT[],
    TEXT, TEXT, INTEGER, NUMERIC
);
DROP FUNCTION IF EXISTS kamino_lend.simulate_cascade_amplification(
    BIGINT, INTEGER, INTEGER, INTEGER, INTEGER, BOOLEAN, TEXT[], TEXT[],
    TEXT, TEXT, TEXT, INTEGER, NUMERIC
);
DROP FUNCTION IF EXISTS kamino_lend.simulate_cascade_amplification(
    BIGINT, INTEGER, INTEGER, INTEGER, INTEGER, BOOLEAN, TEXT[], TEXT[],
    TEXT, TEXT, TEXT, TEXT, INTEGER, NUMERIC
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
    p_bonus_mode                TEXT     DEFAULT 'blended',
    p_model_mode                TEXT     DEFAULT 'heuristic',
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
    pool_impact_pct           NUMERIC,
    effective_bonus_bps       NUMERIC,
    liq_value_pre_bonus_usd   NUMERIC,
    liq_value_post_bonus_usd  NUMERIC
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
    -- Per-pool BPS after convergence
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
    -- Liquidation bonus params (from reserve config)
    v_max_bonus_bps    INTEGER;
    v_bad_debt_bonus_bps INTEGER;
    -- Per-step bonus calculation
    v_bad_share        NUMERIC;
    v_eff_bonus_bps    NUMERIC;
    v_bonus_mult       NUMERIC;
    v_liq_pre_bonus    NUMERIC;
    v_liq_post_bonus   NUMERIC;
    v_model_mode       TEXT;
    -- Left-side curve arrays
    v_left_pct         NUMERIC[];
    v_left_liq         NUMERIC[];
    v_left_bad_liq     NUMERIC[];
    v_left_liq_coll    NUMERIC[];
    v_left_n           INTEGER;
    -- Right-side curve arrays
    v_right_pct        NUMERIC[];
    v_right_liq        NUMERIC[];
    v_right_bad_liq    NUMERIC[];
    v_right_liq_coll   NUMERIC[];
    v_right_n          INTEGER;
    -- Interpolated bad-liq value
    v_bad_liq_value    NUMERIC;
    v_liq_coll_value   NUMERIC;
    v_tokens_per_usd   NUMERIC;
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
    v_l_debt_bad       NUMERIC;
    v_l_coll_bad       NUMERIC;
    v_l_debt_coll      NUMERIC;
    v_l_coll_coll      NUMERIC;
    -- Linear interpolation
    v_lo               INTEGER;
    v_hi               INTEGER;
    v_frac             NUMERIC;
    j                  INTEGER;
BEGIN
    v_model_mode := LOWER(COALESCE(p_model_mode, 'heuristic'));
    IF v_model_mode NOT IN ('heuristic', 'protocol') THEN
        RAISE EXCEPTION 'Unsupported p_model_mode: %. Expected heuristic|protocol', p_model_mode;
    END IF;

    -- ---------------------------------------------------------------
    -- 1. Resolve DEX pool(s) for the collateral symbol
    -- ---------------------------------------------------------------
    IF p_coll_symbol IS NULL THEN
        RETURN QUERY
        SELECT
            s.pct_change, s.pct_change, 1.0::NUMERIC, 0, 0.0::NUMERIC,
            s.total_liquidatable_value::NUMERIC, 0.0::NUMERIC,
            s.total_liquidatable_value::NUMERIC, 0.0::NUMERIC,
            0.0::NUMERIC, 0.0::NUMERIC, 0.0::NUMERIC, NULL::NUMERIC,
            NULL::TEXT, NULL::NUMERIC, NULL::TEXT, NULL::NUMERIC,
            NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC
        FROM (
            SELECT
                x.pct_change,
                x.total_liquidatable_value
            FROM kamino_lend.get_view_klend_sensitivities(
                p_query_id, p_assets_delta_bps, p_assets_delta_steps,
                p_liabilities_delta_bps, p_liabilities_delta_steps,
                p_include_zero_borrows, p_coll_assets, p_lend_assets
            ) x
        ) s
        ORDER BY s.pct_change;
        RETURN;
    END IF;

    IF p_pool_mode IS NOT NULL AND p_pool_mode != 'weighted' THEN
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
        SELECT
            array_agg(rdp.pool_address),
            array_agg(rdp.token_side),
            array_agg(CASE WHEN rdp.token_side = 't0' THEN rdp.token1_symbol
                           ELSE rdp.token0_symbol END)
        INTO v_pool_addresses, v_pool_sides, v_pool_counter_sym
        FROM kamino_lend.resolve_dex_pool(p_coll_symbol) rdp;

        v_n_pools := COALESCE(array_length(v_pool_addresses, 1), 0);

        IF v_n_pools = 0 THEN
            RETURN QUERY
            SELECT
                s.pct_change, s.pct_change, 1.0::NUMERIC, 0, 0.0::NUMERIC,
                s.total_liquidatable_value::NUMERIC, 0.0::NUMERIC,
                s.total_liquidatable_value::NUMERIC, 0.0::NUMERIC,
                0.0::NUMERIC, 0.0::NUMERIC, 0.0::NUMERIC, NULL::NUMERIC,
                NULL::TEXT, NULL::NUMERIC, NULL::TEXT, NULL::NUMERIC,
                NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC
            FROM (
                SELECT
                    x.pct_change,
                    x.total_liquidatable_value
                FROM kamino_lend.get_view_klend_sensitivities(
                    p_query_id, p_assets_delta_bps, p_assets_delta_steps,
                    p_liabilities_delta_bps, p_liabilities_delta_steps,
                    p_include_zero_borrows, p_coll_assets, p_lend_assets
                ) x
            ) s
            ORDER BY s.pct_change;
            RETURN;
        END IF;

        -- ASSUMPTION: USDC, USDG, and other stablecoins at par ($1 face value).
        v_cp_values := ARRAY[]::NUMERIC[];
        v_cp_total  := 0;

        FOR v_p IN 1..v_n_pools LOOP
            IF v_pool_sides[v_p] = 't0' THEN
                SELECT COALESCE(SUM(td.token1_value), 0) INTO v_cp_val
                FROM dexes.src_acct_tickarray_tokendist_latest td
                WHERE td.pool_address = v_pool_addresses[v_p];
            ELSE
                SELECT COALESCE(SUM(td.token0_value), 0) INTO v_cp_val
                FROM dexes.src_acct_tickarray_tokendist_latest td
                WHERE td.pool_address = v_pool_addresses[v_p];
            END IF;
            v_cp_values := v_cp_values || v_cp_val;
            v_cp_total  := v_cp_total + v_cp_val;
        END LOOP;

        IF v_cp_total > 0 THEN
            v_pool_weights := ARRAY[]::NUMERIC[];
            FOR v_p IN 1..v_n_pools LOOP
                v_pool_weights := v_pool_weights || (v_cp_values[v_p] / v_cp_total);
            END LOOP;
        ELSE
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
    -- 2e. Liquidation bonus parameters from reserve config
    --     Market-scoped via aux_market_reserve_tokens to avoid symbol
    --     collisions if the same symbol exists in multiple markets.
    -- ---------------------------------------------------------------
    SELECT r.max_liquidation_bonus_bps, r.bad_debt_liquidation_bonus_bps
    INTO v_max_bonus_bps, v_bad_debt_bonus_bps
    FROM kamino_lend.src_reserves r
    JOIN kamino_lend.aux_market_reserve_tokens mrt
      ON mrt.token_symbol = r.env_symbol
     AND mrt.env_market_address_matches = TRUE
    WHERE r.env_symbol = p_coll_symbol
      AND r.env_market_address = mrt.market_address
      AND r.max_liquidation_bonus_bps > 0
    ORDER BY r.time DESC
    LIMIT 1;

    v_max_bonus_bps      := COALESCE(v_max_bonus_bps, 0);
    v_bad_debt_bonus_bps := COALESCE(v_bad_debt_bonus_bps, 0);

    IF p_bonus_mode = 'none' THEN
        v_max_bonus_bps      := 0;
        v_bad_debt_bonus_bps := 0;
    END IF;

    -- ---------------------------------------------------------------
    -- 3. Materialize curve once per mode (baseline + left + right)
    -- ---------------------------------------------------------------
    IF v_model_mode = 'protocol' THEN
        SELECT
            MAX(s.total_deposits) FILTER (WHERE s.pct_change = 0.0),
            array_agg(s.pct_change ORDER BY s.pct_change) FILTER (WHERE s.pct_change <= 0),
            array_agg(s.total_liquidatable_value::NUMERIC ORDER BY s.pct_change) FILTER (WHERE s.pct_change <= 0),
            array_agg(s.bad_liquidatable_value::NUMERIC ORDER BY s.pct_change) FILTER (WHERE s.pct_change <= 0),
            array_agg(s.total_liq_value_coll_side::NUMERIC ORDER BY s.pct_change) FILTER (WHERE s.pct_change <= 0),
            array_agg(s.pct_change ORDER BY s.pct_change) FILTER (WHERE s.pct_change > 0),
            array_agg(s.total_liquidatable_value::NUMERIC ORDER BY s.pct_change) FILTER (WHERE s.pct_change > 0),
            array_agg(s.bad_liquidatable_value::NUMERIC ORDER BY s.pct_change) FILTER (WHERE s.pct_change > 0),
            array_agg(s.total_liq_value_coll_side::NUMERIC ORDER BY s.pct_change) FILTER (WHERE s.pct_change > 0)
        INTO
            v_total_deposits,
            v_left_pct, v_left_liq, v_left_bad_liq, v_left_liq_coll,
            v_right_pct, v_right_liq, v_right_bad_liq, v_right_liq_coll
        FROM kamino_lend.simulate_protocol_liquidation(
            p_query_id, p_assets_delta_bps, p_assets_delta_steps,
            p_liabilities_delta_bps, p_liabilities_delta_steps,
            p_include_zero_borrows, p_coll_assets, p_lend_assets, p_coll_symbol
        ) s;
    ELSE
        SELECT
            MAX(s.total_deposits) FILTER (WHERE s.pct_change = 0.0),
            array_agg(s.pct_change ORDER BY s.pct_change) FILTER (WHERE s.pct_change <= 0),
            array_agg(s.total_liquidatable_value::NUMERIC ORDER BY s.pct_change) FILTER (WHERE s.pct_change <= 0),
            array_agg(s.bad_liquidatable_value::NUMERIC ORDER BY s.pct_change) FILTER (WHERE s.pct_change <= 0),
            array_agg(s.pct_change ORDER BY s.pct_change) FILTER (WHERE s.pct_change > 0),
            array_agg(s.total_liquidatable_value::NUMERIC ORDER BY s.pct_change) FILTER (WHERE s.pct_change > 0),
            array_agg(s.bad_liquidatable_value::NUMERIC ORDER BY s.pct_change) FILTER (WHERE s.pct_change > 0)
        INTO
            v_total_deposits,
            v_left_pct, v_left_liq, v_left_bad_liq,
            v_right_pct, v_right_liq, v_right_bad_liq
        FROM kamino_lend.get_view_klend_sensitivities(
            p_query_id, p_assets_delta_bps, p_assets_delta_steps,
            p_liabilities_delta_bps, p_liabilities_delta_steps,
            p_include_zero_borrows, p_coll_assets, p_lend_assets
        ) s;

        v_left_liq_coll := NULL;
        v_right_liq_coll := NULL;
    END IF;

    v_total_deposits := COALESCE(v_total_deposits, 0);
    v_left_n := COALESCE(array_length(v_left_pct, 1), 0);
    v_right_n := COALESCE(array_length(v_right_pct, 1), 0);
    v_tokens_per_usd := CASE
        WHEN v_model_mode = 'protocol' AND v_token_price > 0 THEN 1.0 / v_token_price
        WHEN v_total_deposits > 0 THEN v_coll_tokens_deposited / v_total_deposits
        ELSE 0
    END;

    -- ---------------------------------------------------------------
    -- 4. LEFT SIDE: single-axis cascade (collateral decrease)
    -- ---------------------------------------------------------------
    FOR v_idx IN 1..v_left_n LOOP
        initial_shock_pct := v_left_pct[v_idx];

        IF initial_shock_pct = 0 THEN
            v_liq_value     := v_left_liq[v_idx];
            v_bad_liq_value := v_left_bad_liq[v_idx];
            v_liq_coll_value := CASE
                WHEN v_left_liq_coll IS NOT NULL AND array_length(v_left_liq_coll, 1) >= v_idx
                THEN v_left_liq_coll[v_idx]
                ELSE v_liq_value
            END;

            IF v_model_mode = 'protocol' AND p_bonus_mode <> 'none' THEN
                v_liq_pre_bonus := v_liq_value;
                v_liq_post_bonus := COALESCE(v_liq_coll_value, v_liq_value);
                v_eff_bonus_bps := CASE
                    WHEN v_liq_pre_bonus > 0
                    THEN (v_liq_post_bonus / v_liq_pre_bonus - 1.0) * 10000.0
                    ELSE 0
                END;
            ELSIF p_bonus_mode = 'max_conservative' OR v_liq_value <= 0 THEN
                v_eff_bonus_bps := CASE WHEN v_liq_value > 0 THEN v_max_bonus_bps ELSE 0 END;
                v_liq_pre_bonus := v_liq_value;
                v_liq_post_bonus := v_liq_value * (1.0 + v_eff_bonus_bps / 10000.0);
            ELSE
                v_bad_share     := LEAST(GREATEST(v_bad_liq_value / v_liq_value, 0), 1);
                v_eff_bonus_bps := v_bad_share * v_bad_debt_bonus_bps
                                 + (1 - v_bad_share) * v_max_bonus_bps;
                v_liq_pre_bonus := v_liq_value;
                v_liq_post_bonus := v_liq_value * (1.0 + v_eff_bonus_bps / 10000.0);
            END IF;
            v_bonus_mult := CASE
                WHEN v_liq_pre_bonus > 0 THEN v_liq_post_bonus / v_liq_pre_bonus
                ELSE 1.0
            END;

            FOR v_p IN 1..v_n_pools LOOP
                equilibrium_shock_pct     := 0;
                amplification_factor      := 1.0;
                cascade_rounds            := 0;
                cascade_impact_pct        := 0;
                total_liquidated_usd      := ROUND(v_liq_value, 0);
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
                effective_bonus_bps       := ROUND(v_eff_bonus_bps, 0);
                liq_value_pre_bonus_usd   := ROUND(v_liq_pre_bonus, 0);
                liq_value_post_bonus_usd  := ROUND(v_liq_post_bonus, 0);
                RETURN NEXT;
            END LOOP;
            CONTINUE;
        END IF;

        v_shock := initial_shock_pct;
        v_round := 0;

        LOOP
            v_round := v_round + 1;

            -- Interpolate total liquidatable value from left-side curve
            IF v_shock <= v_left_pct[1] THEN
                v_liq_value     := v_left_liq[1];
                v_bad_liq_value := v_left_bad_liq[1];
                v_liq_coll_value := CASE
                    WHEN v_left_liq_coll IS NOT NULL AND array_length(v_left_liq_coll, 1) >= 1
                    THEN v_left_liq_coll[1]
                    ELSE v_liq_value
                END;
            ELSIF v_shock >= v_left_pct[v_left_n] THEN
                v_liq_value     := v_left_liq[v_left_n];
                v_bad_liq_value := v_left_bad_liq[v_left_n];
                v_liq_coll_value := CASE
                    WHEN v_left_liq_coll IS NOT NULL AND array_length(v_left_liq_coll, 1) >= v_left_n
                    THEN v_left_liq_coll[v_left_n]
                    ELSE v_liq_value
                END;
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
                v_liq_value     := v_left_liq[v_lo]
                                 + v_frac * (v_left_liq[v_hi] - v_left_liq[v_lo]);
                v_bad_liq_value := v_left_bad_liq[v_lo]
                                 + v_frac * (v_left_bad_liq[v_hi] - v_left_bad_liq[v_lo]);
                v_liq_coll_value := CASE
                    WHEN v_left_liq_coll IS NOT NULL AND array_length(v_left_liq_coll, 1) >= v_hi
                    THEN v_left_liq_coll[v_lo] + v_frac * (v_left_liq_coll[v_hi] - v_left_liq_coll[v_lo])
                    ELSE v_liq_value
                END;
            END IF;

            -- Compute bonus multiplier: debt-side -> collateral-side conversion.
            -- Liquidators seize collateral worth debt_repaid * (1 + bonus).
            IF v_model_mode = 'protocol' AND p_bonus_mode <> 'none' THEN
                v_liq_pre_bonus := v_liq_value;
                v_liq_post_bonus := COALESCE(v_liq_coll_value, v_liq_value);
                v_eff_bonus_bps := CASE
                    WHEN v_liq_pre_bonus > 0
                    THEN (v_liq_post_bonus / v_liq_pre_bonus - 1.0) * 10000.0
                    ELSE 0
                END;
            ELSIF p_bonus_mode = 'max_conservative' OR v_liq_value <= 0 THEN
                v_eff_bonus_bps := v_max_bonus_bps;
                v_liq_pre_bonus := v_liq_value;
                v_liq_post_bonus := v_liq_value * (1.0 + v_eff_bonus_bps / 10000.0);
            ELSE
                v_bad_share     := LEAST(GREATEST(v_bad_liq_value / v_liq_value, 0), 1);
                v_eff_bonus_bps := v_bad_share * v_bad_debt_bonus_bps
                                 + (1 - v_bad_share) * v_max_bonus_bps;
                v_liq_pre_bonus := v_liq_value;
                v_liq_post_bonus := v_liq_value * (1.0 + v_eff_bonus_bps / 10000.0);
            END IF;
            v_bonus_mult := CASE
                WHEN v_liq_pre_bonus > 0 THEN v_liq_post_bonus / v_liq_pre_bonus
                ELSE 1.0
            END;

            v_qty := (v_liq_post_bonus * v_tokens_per_usd)::DOUBLE PRECISION;
            IF v_qty <= 0 THEN EXIT; END IF;

            -- Weighted-average BPS across pools
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

            v_cascade_pct := (v_agg_bps::NUMERIC / 100.0);
            v_prev_shock  := v_shock;
            v_shock       := initial_shock_pct + v_cascade_pct;

            IF ABS(v_shock - v_prev_shock) < p_convergence_threshold_pct THEN EXIT; END IF;
            IF v_round >= p_max_rounds THEN EXIT; END IF;
        END LOOP;

        -- Compute final bonus diagnostics from converged state
        v_liq_pre_bonus := v_liq_value;
        IF v_model_mode = 'protocol' AND p_bonus_mode <> 'none' THEN
            v_liq_post_bonus := COALESCE(v_liq_coll_value, v_liq_value);
            v_eff_bonus_bps := CASE
                WHEN v_liq_pre_bonus > 0
                THEN (v_liq_post_bonus / v_liq_pre_bonus - 1.0) * 10000.0
                ELSE 0
            END;
        ELSE
            v_liq_post_bonus := v_liq_value * v_bonus_mult;
        END IF;

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

            sell_qty_tokens := ROUND(v_liq_post_bonus * v_tokens_per_usd * v_pool_weights[v_p], 0);
            pool_depth_used_pct := CASE WHEN v_pool_depths[v_p] > 0 THEN ROUND(
                (v_liq_post_bonus * v_tokens_per_usd * v_pool_weights[v_p]) / v_pool_depths[v_p] * 100, 1
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

            effective_bonus_bps      := ROUND(v_eff_bonus_bps, 0);
            liq_value_pre_bonus_usd  := ROUND(v_liq_pre_bonus, 0);
            liq_value_post_bonus_usd := ROUND(v_liq_post_bonus, 0);

            RETURN NEXT;
        END LOOP;
    END LOOP;

    -- ---------------------------------------------------------------
    -- 5. RIGHT SIDE: cross-axis cascade (debt increase -> collateral sold)
    -- ---------------------------------------------------------------
    FOR v_idx IN 1..v_right_n LOOP
        initial_shock_pct := v_right_pct[v_idx];
        v_l_debt          := v_right_liq[v_idx];
        v_l_debt_bad      := v_right_bad_liq[v_idx];
        v_l_debt_coll     := CASE
            WHEN v_right_liq_coll IS NOT NULL AND array_length(v_right_liq_coll, 1) >= v_idx
            THEN v_right_liq_coll[v_idx]
            ELSE v_l_debt
        END;
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
                effective_bonus_bps       := 0;
                liq_value_pre_bonus_usd   := 0;
                liq_value_post_bonus_usd  := 0;
                RETURN NEXT;
            END LOOP;
            CONTINUE;
        END IF;

        LOOP
            v_round := v_round + 1;

            -- Interpolate L_coll and L_coll_bad from LEFT-side curve at v_coll_decline
            v_l_coll     := 0;
            v_l_coll_bad := 0;
            v_l_coll_coll := 0;
            IF v_left_n > 0 AND v_coll_decline < 0 THEN
                IF v_coll_decline <= v_left_pct[1] THEN
                    v_l_coll     := v_left_liq[1];
                    v_l_coll_bad := v_left_bad_liq[1];
                    v_l_coll_coll := CASE
                        WHEN v_left_liq_coll IS NOT NULL AND array_length(v_left_liq_coll, 1) >= 1
                        THEN v_left_liq_coll[1]
                        ELSE v_l_coll
                    END;
                ELSIF v_coll_decline >= v_left_pct[v_left_n] THEN
                    v_l_coll     := v_left_liq[v_left_n];
                    v_l_coll_bad := v_left_bad_liq[v_left_n];
                    v_l_coll_coll := CASE
                        WHEN v_left_liq_coll IS NOT NULL AND array_length(v_left_liq_coll, 1) >= v_left_n
                        THEN v_left_liq_coll[v_left_n]
                        ELSE v_l_coll
                    END;
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
                    v_l_coll     := v_left_liq[v_lo]
                                  + v_frac * (v_left_liq[v_hi] - v_left_liq[v_lo]);
                    v_l_coll_bad := v_left_bad_liq[v_lo]
                                  + v_frac * (v_left_bad_liq[v_hi] - v_left_bad_liq[v_lo]);
                    v_l_coll_coll := CASE
                        WHEN v_left_liq_coll IS NOT NULL AND array_length(v_left_liq_coll, 1) >= v_hi
                        THEN v_left_liq_coll[v_lo] + v_frac * (v_left_liq_coll[v_hi] - v_left_liq_coll[v_lo])
                        ELSE v_l_coll
                    END;
                END IF;
            END IF;

            v_liq_value     := v_l_debt + v_l_coll;
            v_bad_liq_value := v_l_debt_bad + v_l_coll_bad;

            -- Compute bonus multiplier
            IF v_model_mode = 'protocol' AND p_bonus_mode <> 'none' THEN
                v_liq_pre_bonus := v_liq_value;
                v_liq_post_bonus := COALESCE(v_l_debt_coll, v_l_debt) + COALESCE(v_l_coll_coll, v_l_coll);
                v_eff_bonus_bps := CASE
                    WHEN v_liq_pre_bonus > 0
                    THEN (v_liq_post_bonus / v_liq_pre_bonus - 1.0) * 10000.0
                    ELSE 0
                END;
            ELSIF p_bonus_mode = 'max_conservative' OR v_liq_value <= 0 THEN
                v_eff_bonus_bps := v_max_bonus_bps;
                v_liq_pre_bonus := v_liq_value;
                v_liq_post_bonus := v_liq_value * (1.0 + v_eff_bonus_bps / 10000.0);
            ELSE
                v_bad_share     := LEAST(GREATEST(v_bad_liq_value / v_liq_value, 0), 1);
                v_eff_bonus_bps := v_bad_share * v_bad_debt_bonus_bps
                                 + (1 - v_bad_share) * v_max_bonus_bps;
                v_liq_pre_bonus := v_liq_value;
                v_liq_post_bonus := v_liq_value * (1.0 + v_eff_bonus_bps / 10000.0);
            END IF;
            v_bonus_mult := CASE
                WHEN v_liq_pre_bonus > 0 THEN v_liq_post_bonus / v_liq_pre_bonus
                ELSE 1.0
            END;

            v_qty := (v_liq_post_bonus * v_tokens_per_usd)::DOUBLE PRECISION;
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

        v_liq_pre_bonus := v_liq_value;
        IF v_model_mode = 'protocol' AND p_bonus_mode <> 'none' THEN
            v_liq_post_bonus := COALESCE(v_l_debt_coll, v_l_debt) + COALESCE(v_l_coll_coll, v_l_coll);
            v_eff_bonus_bps := CASE
                WHEN v_liq_pre_bonus > 0
                THEN (v_liq_post_bonus / v_liq_pre_bonus - 1.0) * 10000.0
                ELSE 0
            END;
        ELSE
            v_liq_post_bonus := v_liq_value * v_bonus_mult;
        END IF;

        FOR v_p IN 1..v_n_pools LOOP
            equilibrium_shock_pct     := initial_shock_pct;
            amplification_factor      := 1.0;
            cascade_rounds            := v_round;
            cascade_impact_pct        := 0;
            total_liquidated_usd      := ROUND(v_liq_value, 0);
            induced_coll_decline_pct  := ROUND(v_coll_decline, 3);
            debt_triggered_liq_usd    := ROUND(v_l_debt, 0);
            cascade_triggered_liq_usd := ROUND(GREATEST(v_l_coll, 0), 0);

            sell_qty_tokens := ROUND(v_liq_post_bonus * v_tokens_per_usd * v_pool_weights[v_p], 0);
            pool_depth_used_pct := CASE WHEN v_pool_depths[v_p] > 0 THEN ROUND(
                (v_liq_post_bonus * v_tokens_per_usd * v_pool_weights[v_p]) / v_pool_depths[v_p] * 100, 1
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

            effective_bonus_bps      := ROUND(v_eff_bonus_bps, 0);
            liq_value_pre_bonus_usd  := ROUND(v_liq_pre_bonus, 0);
            liq_value_post_bonus_usd := ROUND(v_liq_post_bonus, 0);

            RETURN NEXT;
        END LOOP;
    END LOOP;
END;
$$ LANGUAGE plpgsql STABLE
SET search_path TO kamino_lend, dexes, public;

COMMENT ON FUNCTION kamino_lend.simulate_cascade_amplification(
    BIGINT, INTEGER, INTEGER, INTEGER, INTEGER, BOOLEAN, TEXT[], TEXT[],
    TEXT, TEXT, TEXT, TEXT, INTEGER, NUMERIC
) IS
'Simulates liquidation cascade amplification with multi-pool, bonus-aware, and model-mode support.

MODEL MODES (p_model_mode):
  ''heuristic'' (default): uses get_view_klend_sensitivities curve and blended bonus heuristic.
  ''protocol'': uses precomputed per-obligation protocol curve from simulate_protocol_liquidation
  and reuses the same cascade interpolation/fixed-point loop.

BONUS MODES (p_bonus_mode):
  ''blended'' (default): value-weighted blend of max_liquidation_bonus_bps (unhealthy)
  and bad_debt_liquidation_bonus_bps (bad debt) based on per-step composition.
  ''max_conservative'': flat max_liquidation_bonus_bps for all — upper-bound stress mode.
  ''none'': no bonus applied (legacy behavior, understates sell pressure).

POOL MODES (p_pool_mode):
  ''weighted'' (default): sell pressure split pro-rata by counter-pair liquidity.
  <pool_address>: 100% sell pressure on a specific pool.

BONUS DIAGNOSTICS:
  effective_bonus_bps: applied or implied bonus at each step.
  liq_value_pre_bonus_usd: debt-side liquidatable value (from sensitivity curve).
  liq_value_post_bonus_usd: collateral-side value after bonus gross-up.
  sell_qty_tokens and pool_depth_used_pct use the post-bonus (collateral-side) value.
  In protocol mode, USD->token conversion uses oracle price (1 / market_price);
  heuristic mode retains market-level deposited_tokens / total_deposits proxy.

ASSUMPTIONS:
  - Reserve bonus params sourced from p_coll_symbol reserve (env_symbol match).
  - ONyc reserves currently share uniform bonus schedules; reserve-selection
    ambiguity is low-impact but documented for future divergence.
  - Counter-pair stablecoins at $1 face value for pool weighting.';
