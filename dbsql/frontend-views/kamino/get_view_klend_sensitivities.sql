-- Kamino Lend - Complete Market Sensitivity Analysis Table Function
-- Supports both uniform and asset-level (partial) stress testing.
--
-- ASSET-LEVEL STRESS:
-- When p_coll_assets or p_lend_assets are provided, only the fraction of each
-- obligation's value in those symbols is shocked. The rest stays constant.
-- This uses per-asset position arrays from src_obligations_last.
--
-- Parameters:
--   p_query_id: Query ID to analyze (default: latest, deprecated)
--   assets_delta_bps: Asset price change per step (must be <= 0, e.g., -100 for -1%)
--   assets_delta_steps: Number of asset drop steps (unsigned)
--   liabilities_delta_bps: Liability change per step (must be >= 0, e.g., 100 for +1%)
--   liabilities_delta_steps: Number of liability increase steps (unsigned)
--   include_zero_borrows: If TRUE, includes obligations with borrow < $1 (defaults to FALSE)
--   p_coll_assets: Collateral symbols to stress (NULL = all, ARRAY['All'] = all)
--   p_lend_assets: Borrow/lending symbols to stress (NULL = all, ARRAY['All'] = all)
--
-- Returns:
--   TABLE with unnested arrays showing step-by-step sensitivity metrics

-- Drop old 6-param signature to avoid overload ambiguity
DROP FUNCTION IF EXISTS kamino_lend.get_view_klend_sensitivities(BIGINT, INTEGER, INTEGER, INTEGER, INTEGER, BOOLEAN);

CREATE OR REPLACE FUNCTION kamino_lend.get_view_klend_sensitivities(
    p_query_id BIGINT DEFAULT NULL,
    assets_delta_bps INTEGER DEFAULT -25,
    assets_delta_steps INTEGER DEFAULT 20,
    liabilities_delta_bps INTEGER DEFAULT 25,
    liabilities_delta_steps INTEGER DEFAULT 10,
    include_zero_borrows BOOLEAN DEFAULT FALSE,
    p_coll_assets TEXT[] DEFAULT NULL,
    p_lend_assets TEXT[] DEFAULT NULL
)
RETURNS TABLE (
    step_number INTEGER,
    scenario_type TEXT,
    bps_change INTEGER,
    pct_change NUMERIC(10,1),
    total_deposits BIGINT,
    total_borrows BIGINT,
    market_ltv_pct NUMERIC(10,1),
    avg_ltv_pct NUMERIC(10,1),
    avg_at_risk_ltv_pct NUMERIC(10,1),
    avg_at_risk_hf NUMERIC(10,2),
    unhealthy_debt BIGINT,
    unhealthy_debt_pct NUMERIC(10,1),
    bad_debt BIGINT,
    bad_debt_pct NUMERIC(10,1),
    total_at_risk_debt BIGINT,
    total_at_risk_debt_pct NUMERIC(10,1),
    unhealthy_liquidatable_value BIGINT,
    bad_liquidatable_value BIGINT,
    total_liquidatable_value BIGINT,
    liquidatable_value_pct_of_deposits NUMERIC(10,1),
    total_liquidatable_value_pct_of_loans NUMERIC(10,1),
    unhealthy_debt_less_liquidatable_part BIGINT,
    unhealthy_debt_less_liquidatable_part_pct NUMERIC(10,1),
    bad_debt_less_liquidatable_part BIGINT,
    bad_debt_less_liquidatable_part_pct NUMERIC(10,1),
    liquidation_distance_to_healthy BIGINT
) AS $$
DECLARE
    v_query_id BIGINT;
    v_total_steps INTEGER;
    v_asset_steps INTEGER;
    v_liability_steps INTEGER;
    v_coll_all BOOLEAN;
    v_lend_all BOOLEAN;
BEGIN
    -- Validate constraints
    IF assets_delta_bps > 0 THEN
        RAISE EXCEPTION 'assets_delta_bps must be <= 0 (asset drops are negative)';
    END IF;
    
    IF liabilities_delta_bps < 0 THEN
        RAISE EXCEPTION 'liabilities_delta_bps must be >= 0 (liability increases are positive)';
    END IF;
    
    -- Get query_id (use latest if not provided)
    IF p_query_id IS NULL THEN
        SELECT MAX(query_id) INTO v_query_id FROM kamino_lend.src_obligations_last;
    ELSE
        v_query_id := p_query_id;
    END IF;
    
    -- Calculate total steps (assets + liabilities + 1 for current state)
    v_asset_steps := COALESCE(assets_delta_steps, 0);
    v_liability_steps := COALESCE(liabilities_delta_steps, 0);
    v_total_steps := v_asset_steps + v_liability_steps + 1;

    -- Determine whether to stress all assets (uniform) or a subset (partial)
    v_coll_all := (p_coll_assets IS NULL OR 'All' = ANY(p_coll_assets));
    v_lend_all := (p_lend_assets IS NULL OR 'All' = ANY(p_lend_assets));
    
    -- Generate sensitivity table
    RETURN QUERY
    WITH obligation_base AS MATERIALIZED (
        SELECT 
            o.obligation_address,
            o.c_user_total_deposit,
            o.c_user_total_borrow,
            o.c_loan_to_value_pct,
            o.c_unhealthy_ltv_obligation,
            o.mkt_insolvency_risk_unhealthy_ltv_pct,
            o.mkt_liquidation_max_debt_close_factor_pct,
            o.mkt_max_liquidatable_debt_market_value_at_once,
            CASE WHEN v_coll_all THEN 1.0
                 ELSE kamino_lend.compute_stressed_share(
                     o.deposit_reserve_by_asset,
                     o.deposit_market_value_sf_by_asset,
                     o.resrv_address,
                     o.resrv_symbol,
                     p_coll_assets
                 )
            END as deposit_stressed_share,
            CASE WHEN v_lend_all THEN 1.0
                 ELSE kamino_lend.compute_stressed_share(
                     o.borrow_reserve_by_asset,
                     o.borrow_market_value_sf_by_asset,
                     o.resrv_address,
                     o.resrv_symbol,
                     p_lend_assets
                 )
            END as borrow_stressed_share
        FROM kamino_lend.src_obligations_last o
        WHERE (include_zero_borrows OR o.c_user_total_borrow >= 1)
    ),
    asset_sensitivity AS MATERIALIZED (
        -- Asset-side: collateral drops, borrows stay constant
        SELECT 
            o.*,
            kamino_lend.sensitize_value_partial(o.c_user_total_deposit, o.deposit_stressed_share, assets_delta_bps, v_asset_steps) as deposit_array_asset,
            kamino_lend.sensitize_value_partial(o.c_user_total_borrow, 1.0, 0, v_asset_steps) as borrow_array_asset
        FROM obligation_base o
    ),
    liability_sensitivity AS MATERIALIZED (
        -- Liability-side: borrows increase, deposits stay constant
        SELECT 
            o.obligation_address,
            o.c_user_total_deposit,
            o.c_user_total_borrow,
            o.c_loan_to_value_pct,
            o.c_unhealthy_ltv_obligation,
            o.mkt_insolvency_risk_unhealthy_ltv_pct,
            o.mkt_liquidation_max_debt_close_factor_pct,
            o.mkt_max_liquidatable_debt_market_value_at_once,
            o.deposit_array_asset,
            o.borrow_array_asset,
            kamino_lend.sensitize_value_partial(o.c_user_total_deposit, 1.0, 0, v_liability_steps) as deposit_array_liability,
            kamino_lend.sensitize_value_partial(o.c_user_total_borrow, o.borrow_stressed_share, liabilities_delta_bps, v_liability_steps) as borrow_array_liability
        FROM asset_sensitivity o
    ),
    combined_arrays AS MATERIALIZED (
        -- Continuous spectrum: severe asset drops -> current state -> severe liability increases
        SELECT 
            ls.obligation_address,
            ls.c_user_total_deposit,
            ls.c_user_total_borrow,
            ls.c_unhealthy_ltv_obligation,
            ls.mkt_insolvency_risk_unhealthy_ltv_pct,
            ls.mkt_liquidation_max_debt_close_factor_pct,
            ls.mkt_max_liquidatable_debt_market_value_at_once,
            ARRAY(SELECT ls.deposit_array_asset[i] FROM generate_series(v_asset_steps + 1, 1, -1) i) ||
            CASE WHEN v_liability_steps > 0 THEN ARRAY(SELECT ls.deposit_array_liability[i] FROM generate_series(2, v_liability_steps + 1) i) ELSE ARRAY[]::NUMERIC[] END 
                as combined_deposit_array,
            ARRAY(SELECT ls.borrow_array_asset[i] FROM generate_series(v_asset_steps + 1, 1, -1) i) ||
            CASE WHEN v_liability_steps > 0 THEN ARRAY(SELECT ls.borrow_array_liability[i] FROM generate_series(2, v_liability_steps + 1) i) ELSE ARRAY[]::NUMERIC[] END 
                as combined_borrow_array
        FROM liability_sensitivity ls
    ),
    combined_with_ltv AS MATERIALIZED (
        -- Derive LTV from actual deposit/borrow arrays (correct for partial stress)
        SELECT
            ca.*,
            kamino_lend.compute_ltv_array(ca.combined_deposit_array, ca.combined_borrow_array) as combined_ltv_array
        FROM combined_arrays ca
    ),
    flag_arrays AS MATERIALIZED (
        SELECT 
            *,
            kamino_lend.is_unhealthy_from_values(
                combined_deposit_array, 
                combined_borrow_array, 
                c_unhealthy_ltv_obligation, 
                mkt_insolvency_risk_unhealthy_ltv_pct
            ) as unhealthy_flags,
            kamino_lend.is_bad_from_values(
                combined_deposit_array,
                combined_borrow_array,
                mkt_insolvency_risk_unhealthy_ltv_pct
            ) as bad_debt_flags
        FROM combined_with_ltv
    ),
    actual_current_state AS MATERIALIZED (
        SELECT 
            o.obligation_address,
            o.c_is_unhealthy,
            o.c_is_bad_debt,
            o.c_liquidatable_value,
            o.c_user_total_borrow
        FROM kamino_lend.src_obligations_last o
        WHERE (include_zero_borrows OR o.c_user_total_borrow >= 1)
    ),
    value_arrays AS MATERIALIZED (
        SELECT 
            fa.obligation_address,
            fa.c_user_total_deposit,
            fa.c_user_total_borrow,
            fa.combined_deposit_array,
            fa.combined_borrow_array,
            fa.combined_ltv_array,
            fa.c_unhealthy_ltv_obligation,
            fa.mkt_insolvency_risk_unhealthy_ltv_pct,
            fa.mkt_liquidation_max_debt_close_factor_pct,
            fa.mkt_max_liquidatable_debt_market_value_at_once,
            fa.unhealthy_flags,
            fa.bad_debt_flags,
            acs.c_is_unhealthy as actual_is_unhealthy,
            acs.c_is_bad_debt as actual_is_bad_debt,
            acs.c_liquidatable_value as actual_liquidatable_value,
            kamino_lend.calculate_health_factor_array(
                fa.combined_deposit_array,
                fa.combined_borrow_array,
                fa.c_unhealthy_ltv_obligation
            ) as health_factor_array,
            kamino_lend.sensitize_liquidation_distance(
                fa.combined_deposit_array,
                fa.combined_borrow_array,
                fa.c_unhealthy_ltv_obligation
            ) as liquidation_distance_array,
            ARRAY(
                SELECT 
                    CASE 
                        WHEN i = v_asset_steps + 1 THEN acs.c_liquidatable_value
                        WHEN fa.bad_debt_flags[i] = 1 THEN 
                            LEAST(fa.combined_borrow_array[i], fa.mkt_max_liquidatable_debt_market_value_at_once)
                        WHEN fa.unhealthy_flags[i] = 1 THEN 
                            LEAST(
                                fa.combined_borrow_array[i] * (fa.mkt_liquidation_max_debt_close_factor_pct::NUMERIC / 100.0),
                                fa.mkt_max_liquidatable_debt_market_value_at_once
                            )
                        ELSE 0
                    END
                FROM generate_series(1, v_total_steps) i
            ) as liquidatable_array,
            ARRAY(
                SELECT 
                    CASE
                        WHEN fa.unhealthy_flags[i] = 1 THEN 
                            LEAST(
                                fa.combined_borrow_array[i] * (fa.mkt_liquidation_max_debt_close_factor_pct::NUMERIC / 100.0),
                                fa.mkt_max_liquidatable_debt_market_value_at_once
                            )
                        ELSE 0
                    END
                FROM generate_series(1, v_total_steps) i
            ) as unhealthy_liquidatable_array,
            ARRAY(
                SELECT 
                    CASE
                        WHEN fa.bad_debt_flags[i] = 1 THEN 
                            LEAST(fa.combined_borrow_array[i], fa.mkt_max_liquidatable_debt_market_value_at_once)
                        ELSE 0
                    END
                FROM generate_series(1, v_total_steps) i
            ) as bad_liquidatable_array,
            ARRAY(
                SELECT 
                    CASE 
                        WHEN i = v_asset_steps + 1 THEN (acs.c_is_unhealthy::INTEGER)::NUMERIC * acs.c_user_total_borrow
                        ELSE fa.unhealthy_flags[i]::NUMERIC * fa.combined_borrow_array[i]
                    END
                FROM generate_series(1, v_total_steps) i
            ) as unhealthy_debt_array,
            ARRAY(
                SELECT 
                    CASE
                        WHEN i = v_asset_steps + 1 THEN (acs.c_is_bad_debt::INTEGER)::NUMERIC * acs.c_user_total_borrow
                        ELSE fa.bad_debt_flags[i]::NUMERIC * fa.combined_borrow_array[i]
                    END
                FROM generate_series(1, v_total_steps) i
            ) as bad_debt_array
        FROM flag_arrays fa
        JOIN actual_current_state acs ON fa.obligation_address = acs.obligation_address
    ),
    market_aggregates AS MATERIALIZED (
        SELECT 
            kamino_lend.sum_array_elementwise(ARRAY_AGG(combined_deposit_array)::NUMERIC[][]) as total_deposits_array,
            kamino_lend.sum_array_elementwise(ARRAY_AGG(combined_borrow_array)::NUMERIC[][]) as total_borrows_array,
            kamino_lend.sum_array_elementwise(ARRAY_AGG(unhealthy_debt_array)::NUMERIC[][]) as total_unhealthy_debt_array,
            kamino_lend.sum_array_elementwise(ARRAY_AGG(bad_debt_array)::NUMERIC[][]) as total_bad_debt_array,
            kamino_lend.sum_array_elementwise(ARRAY_AGG(liquidatable_array)::NUMERIC[][]) as total_liquidatable_array,
            kamino_lend.sum_array_elementwise(ARRAY_AGG(unhealthy_liquidatable_array)::NUMERIC[][]) as unhealthy_liquidatable_array,
            kamino_lend.sum_array_elementwise(ARRAY_AGG(bad_liquidatable_array)::NUMERIC[][]) as bad_liquidatable_array,
            kamino_lend.sum_array_elementwise(ARRAY_AGG(liquidation_distance_array)::NUMERIC[][]) as liquidation_distance_array,
            kamino_lend.average_array_elementwise(ARRAY_AGG(combined_ltv_array)::NUMERIC[][]) as avg_ltv_array,
            kamino_lend.average_array_elementwise(
                ARRAY_AGG(
                    ARRAY(
                        SELECT CASE WHEN (unhealthy_flags[idx] + bad_debt_flags[idx]) > 0 
                                   THEN health_factor_array[idx] 
                                   ELSE NULL END
                        FROM generate_series(1, v_total_steps) idx
                    )
                )::NUMERIC[][]
            ) as avg_at_risk_hf_array,
            kamino_lend.average_array_elementwise(
                ARRAY_AGG(
                    ARRAY(
                        SELECT CASE WHEN (unhealthy_flags[idx] + bad_debt_flags[idx]) > 0 
                                   THEN combined_ltv_array[idx]
                                   ELSE NULL END
                        FROM generate_series(1, v_total_steps) idx
                    )
                )::NUMERIC[][]
            ) as avg_at_risk_ltv_array
        FROM value_arrays
    ),
    step_generator AS (
        SELECT 
            i as array_index,
            CASE 
                WHEN i <= v_asset_steps + 1 THEN 'asset_drop'
                ELSE 'liability_increase'
            END as scenario_type,
            CASE
                WHEN i <= v_asset_steps + 1 THEN assets_delta_bps * (v_asset_steps - i + 1)
                ELSE liabilities_delta_bps * (i - v_asset_steps - 1)
            END as bps_change
        FROM generate_series(1, v_total_steps) i
    )
    SELECT 
        sg.array_index - 1 as step_number,
        sg.scenario_type,
        sg.bps_change,
        ROUND((sg.bps_change::NUMERIC / 10000.0 * 100)::NUMERIC, 1) as pct_change,
        ROUND(ma.total_deposits_array[sg.array_index])::BIGINT as total_deposits,
        ROUND(ma.total_borrows_array[sg.array_index])::BIGINT as total_borrows,
        ROUND((ma.total_borrows_array[sg.array_index] / NULLIF(ma.total_deposits_array[sg.array_index], 0)) * 100, 1) as market_ltv_pct,
        ROUND(ma.avg_ltv_array[sg.array_index], 1) as avg_ltv_pct,
        ROUND(ma.avg_at_risk_ltv_array[sg.array_index], 1) as avg_at_risk_ltv_pct,
        ROUND(ma.avg_at_risk_hf_array[sg.array_index], 2) as avg_at_risk_hf,
        ROUND(ma.total_unhealthy_debt_array[sg.array_index])::BIGINT as unhealthy_debt,
        ROUND((ma.total_unhealthy_debt_array[sg.array_index] / NULLIF(ma.total_borrows_array[sg.array_index], 0)) * 100, 1) as unhealthy_debt_pct,
        ROUND(ma.total_bad_debt_array[sg.array_index])::BIGINT as bad_debt,
        ROUND((ma.total_bad_debt_array[sg.array_index] / NULLIF(ma.total_borrows_array[sg.array_index], 0)) * 100, 1) as bad_debt_pct,
        ROUND(ma.total_bad_debt_array[sg.array_index] + ma.total_unhealthy_debt_array[sg.array_index])::BIGINT as total_at_risk_debt,
        ROUND(((ma.total_bad_debt_array[sg.array_index] + ma.total_unhealthy_debt_array[sg.array_index]) / NULLIF(ma.total_borrows_array[sg.array_index], 0)) * 100, 1) as total_at_risk_debt_pct,
        ROUND(ma.unhealthy_liquidatable_array[sg.array_index])::BIGINT as unhealthy_liquidatable_value,
        ROUND(ma.bad_liquidatable_array[sg.array_index])::BIGINT as bad_liquidatable_value,
        ROUND(ma.total_liquidatable_array[sg.array_index])::BIGINT as total_liquidatable_value,
        ROUND((ma.total_liquidatable_array[sg.array_index] / NULLIF(ma.total_deposits_array[sg.array_index], 0)) * 100, 1) as liquidatable_value_pct_of_deposits,
        ROUND((ma.total_liquidatable_array[sg.array_index] / NULLIF(ma.total_borrows_array[sg.array_index], 0)) * 100, 1) as total_liquidatable_value_pct_of_loans,
        ROUND(ma.total_unhealthy_debt_array[sg.array_index] - ma.unhealthy_liquidatable_array[sg.array_index])::BIGINT as unhealthy_debt_less_liquidatable_part,
        ROUND(((ma.total_unhealthy_debt_array[sg.array_index] - ma.unhealthy_liquidatable_array[sg.array_index]) / NULLIF(ma.total_borrows_array[sg.array_index], 0)) * 100, 1) as unhealthy_debt_less_liquidatable_part_pct,
        ROUND(ma.total_bad_debt_array[sg.array_index] - ma.bad_liquidatable_array[sg.array_index])::BIGINT as bad_debt_less_liquidatable_part,
        ROUND(((ma.total_bad_debt_array[sg.array_index] - ma.bad_liquidatable_array[sg.array_index]) / NULLIF(ma.total_borrows_array[sg.array_index], 0)) * 100, 1) as bad_debt_less_liquidatable_part_pct,
        ABS(ROUND(ma.liquidation_distance_array[sg.array_index]))::BIGINT as liquidation_distance_to_healthy
    FROM market_aggregates ma
    CROSS JOIN step_generator sg
    ORDER BY sg.array_index;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION kamino_lend.get_view_klend_sensitivities(BIGINT, INTEGER, INTEGER, INTEGER, INTEGER, BOOLEAN, TEXT[], TEXT[]) IS 
'Market sensitivity analysis with optional asset-level stress testing.
When p_coll_assets / p_lend_assets are NULL (default), applies uniform shock to all assets (original behavior).
When specific symbols are provided, only the fraction of each obligation''s value in those symbols is stressed.
Parameters: (query_id [deprecated], assets_delta_bps<=0, assets_steps, liabilities_delta_bps>=0,
liabilities_steps, include_zero_borrows, p_coll_assets, p_lend_assets).
Helper functions: compute_stressed_share, sensitize_value_partial, compute_ltv_array.';
