-- Kamino Lend - Protocol-Mode Liquidation Curve Generator
--
-- Produces a stress curve compatible with cascade interpolation, but computes
-- liquidation amounts using per-obligation state and per-leg reserve params.
--
-- Notes:
-- - This function is designed for protocol-mode curve precomputation.
-- - Cascade should interpolate these outputs; it should not recompute this
--   function inside fixed-point iterations.

DROP FUNCTION IF EXISTS kamino_lend.simulate_protocol_liquidation(
    BIGINT, INTEGER, INTEGER, INTEGER, INTEGER, BOOLEAN, TEXT[], TEXT[]
);
DROP FUNCTION IF EXISTS kamino_lend.simulate_protocol_liquidation(
    BIGINT, INTEGER, INTEGER, INTEGER, INTEGER, BOOLEAN, TEXT[], TEXT[], TEXT
);

CREATE OR REPLACE FUNCTION kamino_lend.simulate_protocol_liquidation(
    p_query_id BIGINT DEFAULT NULL,
    assets_delta_bps INTEGER DEFAULT -100,
    assets_delta_steps INTEGER DEFAULT 50,
    liabilities_delta_bps INTEGER DEFAULT 100,
    liabilities_delta_steps INTEGER DEFAULT 50,
    include_zero_borrows BOOLEAN DEFAULT FALSE,
    p_coll_assets TEXT[] DEFAULT NULL,
    p_lend_assets TEXT[] DEFAULT NULL,
    p_coll_symbol TEXT DEFAULT NULL
)
RETURNS TABLE (
    step_number INTEGER,
    scenario_type TEXT,
    bps_change INTEGER,
    pct_change NUMERIC,
    total_deposits NUMERIC,
    total_borrows NUMERIC,
    unhealthy_liquidatable_value NUMERIC,
    bad_liquidatable_value NUMERIC,
    total_liquidatable_value NUMERIC,
    unhealthy_liq_value_coll_side NUMERIC,
    bad_liq_value_coll_side NUMERIC,
    total_liq_value_coll_side NUMERIC,
    unhealthy_share NUMERIC,
    bad_debt_share NUMERIC,
    obligations_evaluated INTEGER,
    obligations_pruned INTEGER,
    obligations_full_liq_override INTEGER,
    obligations_unhealthy INTEGER,
    obligations_bad_debt INTEGER,
    full_liq_override_value NUMERIC,
    full_liq_override_share NUMERIC
) AS $$
DECLARE
    v_asset_steps INTEGER;
    v_liability_steps INTEGER;
    v_total_steps INTEGER;
    v_coll_all BOOLEAN;
    v_lend_all BOOLEAN;
    v_coll_reserve_addrs TEXT[];
    v_lend_reserve_addrs TEXT[];
    v_target_reserve_addrs TEXT[];
BEGIN
    IF assets_delta_bps > 0 THEN
        RAISE EXCEPTION 'assets_delta_bps must be <= 0';
    END IF;
    IF liabilities_delta_bps < 0 THEN
        RAISE EXCEPTION 'liabilities_delta_bps must be >= 0';
    END IF;

    v_asset_steps := COALESCE(assets_delta_steps, 0);
    v_liability_steps := COALESCE(liabilities_delta_steps, 0);
    v_total_steps := v_asset_steps + v_liability_steps + 1;

    v_coll_all := (p_coll_assets IS NULL OR 'All' = ANY(p_coll_assets));
    v_lend_all := (p_lend_assets IS NULL OR 'All' = ANY(p_lend_assets));

    IF NOT v_coll_all THEN
        SELECT array_agg(mrt.reserve_address)
        INTO v_coll_reserve_addrs
        FROM kamino_lend.aux_market_reserve_tokens mrt
        WHERE mrt.token_symbol = ANY(p_coll_assets)
          AND mrt.env_market_address_matches = TRUE;
    END IF;

    IF NOT v_lend_all THEN
        SELECT array_agg(mrt.reserve_address)
        INTO v_lend_reserve_addrs
        FROM kamino_lend.aux_market_reserve_tokens mrt
        WHERE mrt.token_symbol = ANY(p_lend_assets)
          AND mrt.env_market_address_matches = TRUE;
    END IF;

    IF p_coll_symbol IS NOT NULL THEN
        SELECT array_agg(mrt.reserve_address)
        INTO v_target_reserve_addrs
        FROM kamino_lend.aux_market_reserve_tokens mrt
        WHERE mrt.token_symbol = p_coll_symbol
          AND mrt.env_market_address_matches = TRUE;
    END IF;

    RETURN QUERY
    WITH latest_reserve_params AS MATERIALIZED (
        SELECT DISTINCT ON (r.reserve_address)
            r.reserve_address,
            r.liquidation_threshold_pct,
            r.min_liquidation_bonus_bps,
            r.max_liquidation_bonus_bps,
            r.bad_debt_liquidation_bonus_bps
        FROM kamino_lend.src_reserves r
        WHERE r.reserve_address IS NOT NULL
        ORDER BY r.reserve_address, r.time DESC
    ),
    latest_market_params AS MATERIALIZED (
        SELECT DISTINCT ON (m.market_address)
            m.market_address,
            m.min_full_liquidation_value_threshold,
            m.liquidation_max_debt_close_factor_pct,
            m.max_liquidatable_debt_market_value_at_once,
            m.insolvency_risk_unhealthy_ltv_pct
        FROM kamino_lend.src_lending_market m
        ORDER BY m.market_address, m.time DESC
    ),
    obligation_base AS MATERIALIZED (
        SELECT
            o.obligation_address,
            o.market_address,
            o.c_user_total_deposit::NUMERIC AS base_deposit,
            o.c_user_total_borrow::NUMERIC AS base_borrow,
            o.c_unhealthy_ltv_obligation::NUMERIC AS unhealthy_ltv,
            COALESCE(o.mkt_insolvency_risk_unhealthy_ltv_pct, lmp.insolvency_risk_unhealthy_ltv_pct)::NUMERIC AS insolvency_ltv,
            COALESCE(o.mkt_liquidation_max_debt_close_factor_pct, lmp.liquidation_max_debt_close_factor_pct)::NUMERIC AS close_factor_pct,
            COALESCE(o.mkt_max_liquidatable_debt_market_value_at_once, lmp.max_liquidatable_debt_market_value_at_once)::NUMERIC AS max_liq_at_once,
            COALESCE(lmp.min_full_liquidation_value_threshold, 0)::NUMERIC AS min_full_liq_threshold,
            o.resrv_address,
            o.resrv_liquidation_threshold_pct,
            o.deposit_reserve_by_asset,
            o.deposit_market_value_sf_by_asset,
            o.borrow_reserve_by_asset,
            o.borrow_market_value_sf_by_asset,
            -- stressed share for partial stressing
            CASE
                WHEN v_coll_all THEN 1.0
                ELSE kamino_lend.compute_stressed_share(
                    o.deposit_reserve_by_asset,
                    o.deposit_market_value_sf_by_asset,
                    o.resrv_address,
                    o.resrv_symbol,
                    p_coll_assets
                )
            END AS deposit_stressed_share,
            CASE
                WHEN v_lend_all THEN 1.0
                ELSE kamino_lend.compute_stressed_share(
                    o.borrow_reserve_by_asset,
                    o.borrow_market_value_sf_by_asset,
                    o.resrv_address,
                    o.resrv_symbol,
                    p_lend_assets
                )
            END AS borrow_stressed_share,
            -- selected collateral reserve: lowest liquidation threshold first
            coll.sel_coll_reserve,
            coll.sel_coll_threshold_pct,
            coll.sel_coll_dep_mv_sf,
            coll.coll_total_mv_sf,
            coll.sel_coll_min_bonus_bps,
            coll.sel_coll_max_bonus_bps,
            coll.sel_coll_bad_bonus_bps,
            -- selected debt reserve: highest borrow market value first
            debt.sel_debt_reserve,
            debt.sel_debt_mv_sf,
            debt.debt_total_mv_sf
        FROM kamino_lend.src_obligations_last o
        LEFT JOIN latest_market_params lmp
          ON lmp.market_address = o.market_address
        LEFT JOIN LATERAL (
            SELECT
                d.dep_addr AS sel_coll_reserve,
                COALESCE(rp.liquidation_threshold_pct, o.c_unhealthy_ltv_obligation)::NUMERIC AS sel_coll_threshold_pct,
                d.dep_mv::NUMERIC AS sel_coll_dep_mv_sf,
                totals.total_dep_mv_sf::NUMERIC AS coll_total_mv_sf,
                COALESCE(rp.min_liquidation_bonus_bps, 0)::NUMERIC AS sel_coll_min_bonus_bps,
                COALESCE(rp.max_liquidation_bonus_bps, 0)::NUMERIC AS sel_coll_max_bonus_bps,
                COALESCE(rp.bad_debt_liquidation_bonus_bps, 0)::NUMERIC AS sel_coll_bad_bonus_bps
            FROM unnest(o.deposit_reserve_by_asset, o.deposit_market_value_sf_by_asset)
                AS d(dep_addr, dep_mv)
            LEFT JOIN latest_reserve_params rp
              ON rp.reserve_address = d.dep_addr
            CROSS JOIN LATERAL (
                SELECT COALESCE(SUM(x.dep_mv), 0)::NUMERIC AS total_dep_mv_sf
                FROM unnest(o.deposit_reserve_by_asset, o.deposit_market_value_sf_by_asset)
                    AS x(dep_addr, dep_mv)
            ) totals
            ORDER BY COALESCE(rp.liquidation_threshold_pct, 9999) ASC, d.dep_mv DESC
            LIMIT 1
        ) coll ON TRUE
        LEFT JOIN LATERAL (
            SELECT
                b.br_addr AS sel_debt_reserve,
                b.br_mv::NUMERIC AS sel_debt_mv_sf,
                totals.total_br_mv_sf::NUMERIC AS debt_total_mv_sf
            FROM unnest(o.borrow_reserve_by_asset, o.borrow_market_value_sf_by_asset)
                AS b(br_addr, br_mv)
            CROSS JOIN LATERAL (
                SELECT COALESCE(SUM(x.br_mv), 0)::NUMERIC AS total_br_mv_sf
                FROM unnest(o.borrow_reserve_by_asset, o.borrow_market_value_sf_by_asset)
                    AS x(br_addr, br_mv)
            ) totals
            ORDER BY b.br_mv DESC
            LIMIT 1
        ) debt ON TRUE
        WHERE (include_zero_borrows OR o.c_user_total_borrow >= 1)
          AND (v_coll_reserve_addrs IS NULL OR o.deposit_reserve_by_asset && v_coll_reserve_addrs)
          AND (v_lend_reserve_addrs IS NULL OR o.borrow_reserve_by_asset && v_lend_reserve_addrs)
    ),
    step_generator AS (
        SELECT
            i AS array_index,
            i - 1 AS step_number,
            CASE WHEN i <= v_asset_steps + 1 THEN 'asset_drop' ELSE 'liability_increase' END AS scenario_type,
            CASE
                WHEN i <= v_asset_steps + 1 THEN assets_delta_bps * (v_asset_steps - i + 1)
                ELSE liabilities_delta_bps * (i - v_asset_steps - 1)
            END AS bps_change
        FROM generate_series(1, v_total_steps) i
    ),
    candidate_step_counts AS MATERIALIZED (
        SELECT
            sg.step_number,
            COUNT(*)::INTEGER AS candidate_count
        FROM obligation_base ob
        CROSS JOIN step_generator sg
        WHERE ob.base_borrow > 0
        GROUP BY sg.step_number
    ),
    obligation_step AS MATERIALIZED (
        SELECT
            sg.step_number,
            sg.scenario_type,
            sg.bps_change,
            ROUND((sg.bps_change::NUMERIC / 10000.0 * 100)::NUMERIC, 3) AS pct_change,
            ob.obligation_address,
            ob.base_deposit,
            ob.base_borrow,
            ob.unhealthy_ltv,
            ob.insolvency_ltv,
            ob.close_factor_pct,
            ob.max_liq_at_once,
            ob.min_full_liq_threshold,
            ob.deposit_stressed_share,
            ob.borrow_stressed_share,
            ob.sel_coll_reserve,
            ob.sel_coll_threshold_pct,
            ob.sel_coll_dep_mv_sf,
            ob.coll_total_mv_sf,
            ob.sel_coll_min_bonus_bps,
            ob.sel_coll_max_bonus_bps,
            ob.sel_coll_bad_bonus_bps,
            ob.sel_debt_reserve,
            ob.sel_debt_mv_sf,
            ob.debt_total_mv_sf,
            CASE
                WHEN sg.bps_change <= 0
                    THEN ob.base_deposit * (1 + (sg.bps_change::NUMERIC / 10000.0) * ob.deposit_stressed_share)
                ELSE ob.base_deposit
            END AS stressed_deposit,
            CASE
                WHEN sg.bps_change > 0
                    THEN ob.base_borrow * (1 + (sg.bps_change::NUMERIC / 10000.0) * ob.borrow_stressed_share)
                ELSE ob.base_borrow
            END AS stressed_borrow
        FROM obligation_base ob
        CROSS JOIN step_generator sg
        WHERE ob.base_borrow > 0
          AND (
              ABS(sg.bps_change) >= 500
              OR (ob.base_deposit * (ob.unhealthy_ltv / 100.0) - ob.base_borrow) <= (ob.base_borrow * 0.50)
          )
    ),
    liquidation_calc AS MATERIALIZED (
        SELECT
            os.*,
            CASE
                WHEN os.stressed_deposit <= 0 OR os.stressed_borrow <= 0 THEN NULL
                ELSE (os.stressed_borrow / os.stressed_deposit) * 100
            END AS step_ltv_pct,
            CASE
                WHEN os.stressed_borrow <= 0 THEN NULL
                ELSE (os.stressed_deposit * (os.unhealthy_ltv / 100.0)) / os.stressed_borrow
            END AS step_health_factor,
            -- scale selected legs by stressed total ratio
            CASE
                WHEN COALESCE(os.base_deposit, 0) > 0 AND COALESCE(os.coll_total_mv_sf, 0) > 0
                    THEN os.stressed_deposit * (COALESCE(os.sel_coll_dep_mv_sf, 0) / NULLIF(os.coll_total_mv_sf, 0))
                ELSE 0
            END AS selected_collateral_usd,
            CASE
                WHEN COALESCE(os.base_borrow, 0) > 0 AND COALESCE(os.debt_total_mv_sf, 0) > 0
                    THEN os.stressed_borrow * (COALESCE(os.sel_debt_mv_sf, 0) / NULLIF(os.debt_total_mv_sf, 0))
                ELSE os.stressed_borrow
            END AS selected_debt_usd
        FROM obligation_step os
    ),
    liquidation_amounts AS MATERIALIZED (
        SELECT
            lc.*,
            CASE
                WHEN lc.stressed_deposit <= 0 OR lc.stressed_borrow <= 0 THEN 0
                WHEN lc.step_ltv_pct >= lc.insolvency_ltv THEN 1
                ELSE 0
            END AS is_bad_debt,
            CASE
                WHEN lc.stressed_deposit <= 0 OR lc.stressed_borrow <= 0 THEN 0
                WHEN lc.step_ltv_pct >= lc.insolvency_ltv THEN 0
                WHEN lc.step_health_factor <= 1.0 THEN 1
                ELSE 0
            END AS is_unhealthy,
            CASE
                WHEN lc.stressed_borrow < lc.min_full_liq_threshold THEN 1
                ELSE 0
            END AS full_liq_override,
            CASE
                WHEN lc.stressed_deposit <= 0 OR lc.stressed_borrow <= 0 THEN 0
                WHEN lc.step_ltv_pct >= lc.insolvency_ltv
                    THEN LEAST(lc.stressed_borrow, lc.max_liq_at_once)
                WHEN lc.step_health_factor <= 1.0 THEN LEAST(
                    lc.stressed_borrow *
                        (CASE WHEN lc.stressed_borrow < lc.min_full_liq_threshold
                            THEN 1.0
                            ELSE COALESCE(lc.close_factor_pct, 0) / 100.0
                        END),
                    lc.max_liq_at_once
                )
                ELSE 0
            END AS debt_repay_usd
        FROM liquidation_calc lc
    ),
    liquidation_with_bonus AS MATERIALIZED (
        SELECT
            la.*,
            LEAST(COALESCE(la.debt_repay_usd, 0), GREATEST(COALESCE(la.selected_debt_usd, 0), 0)) AS debt_repay_selected_leg_usd,
            CASE
                WHEN la.is_bad_debt = 1 THEN COALESCE(la.sel_coll_bad_bonus_bps, 0)
                WHEN la.is_unhealthy = 1 THEN
                    COALESCE(la.sel_coll_min_bonus_bps, 0) + LEAST(GREATEST(
                        (COALESCE(la.step_ltv_pct, 0) - COALESCE(la.sel_coll_threshold_pct, la.unhealthy_ltv))
                        / NULLIF(COALESCE(la.insolvency_ltv, 0) - COALESCE(la.sel_coll_threshold_pct, la.unhealthy_ltv), 0),
                    0), 1) * (COALESCE(la.sel_coll_max_bonus_bps, 0) - COALESCE(la.sel_coll_min_bonus_bps, 0))
                ELSE 0
            END AS bonus_bps
        FROM liquidation_amounts la
    ),
    liquidation_final AS MATERIALIZED (
        SELECT
            lwb.*,
            CASE
                WHEN p_coll_symbol IS NULL
                     OR (v_target_reserve_addrs IS NOT NULL AND lwb.sel_coll_reserve = ANY(v_target_reserve_addrs))
                THEN LEAST(
                    lwb.debt_repay_selected_leg_usd * (1 + lwb.bonus_bps / 10000.0),
                    GREATEST(COALESCE(lwb.selected_collateral_usd, 0), 0)
                )
                ELSE 0
            END AS collateral_seized_usd
        FROM liquidation_with_bonus lwb
    ),
    aggregated AS (
        SELECT
            lf.step_number,
            lf.scenario_type,
            lf.bps_change,
            lf.pct_change,
            SUM(lf.stressed_deposit) AS total_deposits,
            SUM(lf.stressed_borrow) AS total_borrows,
            SUM(CASE WHEN lf.is_unhealthy = 1 THEN lf.debt_repay_selected_leg_usd ELSE 0 END) AS unhealthy_liquidatable_value,
            SUM(CASE WHEN lf.is_bad_debt = 1 THEN lf.debt_repay_selected_leg_usd ELSE 0 END) AS bad_liquidatable_value,
            SUM(CASE WHEN lf.is_unhealthy = 1 THEN lf.collateral_seized_usd ELSE 0 END) AS unhealthy_liq_value_coll_side,
            SUM(CASE WHEN lf.is_bad_debt = 1 THEN lf.collateral_seized_usd ELSE 0 END) AS bad_liq_value_coll_side,
            COUNT(*)::INTEGER AS obligations_evaluated,
            GREATEST(COALESCE(csc.candidate_count, 0) - COUNT(*), 0)::INTEGER AS obligations_pruned,
            COUNT(*) FILTER (WHERE lf.is_unhealthy = 1)::INTEGER AS obligations_unhealthy,
            COUNT(*) FILTER (WHERE lf.is_bad_debt = 1)::INTEGER AS obligations_bad_debt,
            COUNT(*) FILTER (
                WHERE lf.full_liq_override = 1
                  AND lf.is_unhealthy = 1
            )::INTEGER AS obligations_full_liq_override,
            SUM(
                CASE
                    WHEN lf.full_liq_override = 1 AND lf.is_unhealthy = 1
                    THEN lf.debt_repay_selected_leg_usd
                    ELSE 0
                END
            ) AS full_liq_override_value
        FROM liquidation_final lf
        LEFT JOIN candidate_step_counts csc
          ON csc.step_number = lf.step_number
        GROUP BY lf.step_number, lf.scenario_type, lf.bps_change, lf.pct_change, csc.candidate_count
    )
    SELECT
        a.step_number,
        a.scenario_type,
        a.bps_change,
        a.pct_change,
        a.total_deposits,
        a.total_borrows,
        a.unhealthy_liquidatable_value,
        a.bad_liquidatable_value,
        (a.unhealthy_liquidatable_value + a.bad_liquidatable_value) AS total_liquidatable_value,
        a.unhealthy_liq_value_coll_side,
        a.bad_liq_value_coll_side,
        (a.unhealthy_liq_value_coll_side + a.bad_liq_value_coll_side) AS total_liq_value_coll_side,
        CASE WHEN (a.unhealthy_liquidatable_value + a.bad_liquidatable_value) > 0
            THEN a.unhealthy_liquidatable_value / (a.unhealthy_liquidatable_value + a.bad_liquidatable_value)
            ELSE 0 END AS unhealthy_share,
        CASE WHEN (a.unhealthy_liquidatable_value + a.bad_liquidatable_value) > 0
            THEN a.bad_liquidatable_value / (a.unhealthy_liquidatable_value + a.bad_liquidatable_value)
            ELSE 0 END AS bad_debt_share,
        a.obligations_evaluated,
        a.obligations_pruned,
        a.obligations_full_liq_override,
        a.obligations_unhealthy,
        a.obligations_bad_debt,
        a.full_liq_override_value,
        CASE WHEN (a.unhealthy_liquidatable_value + a.bad_liquidatable_value) > 0
            THEN a.full_liq_override_value / (a.unhealthy_liquidatable_value + a.bad_liquidatable_value)
            ELSE 0 END AS full_liq_override_share
    FROM aggregated a
    ORDER BY a.step_number;
END;
$$ LANGUAGE plpgsql STABLE
SET search_path TO kamino_lend, public;

COMMENT ON FUNCTION kamino_lend.simulate_protocol_liquidation(
    BIGINT, INTEGER, INTEGER, INTEGER, INTEGER, BOOLEAN, TEXT[], TEXT[], TEXT
) IS
'Protocol-mode liquidation curve generator.

Generates a full stress curve in one pass and is intended to be interpolated by
simulate_cascade_amplification in protocol mode (not recomputed per iteration).

Implements:
- per-obligation unhealthy/bad-debt classification
- close-factor vs full-liquidation override
- debt/collateral leg selection heuristics
- reserve-level bonus interpolation for unhealthy obligations
- bad-debt bonus handling

Outputs both debt-side and collateral-side liquidation values plus diagnostics,
including full-liquidation-override contribution per stress step.';
