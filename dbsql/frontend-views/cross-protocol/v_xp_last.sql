-- v_xp_last: Frontend view over the cross-protocol snapshot table.
-- Returns one row with latest ONyc ecosystem state across DEXes, Kamino, and Exponent.
-- Signature matches the output of mat_xp_last; kept as a view so the API layer
-- can SELECT * FROM cross_protocol.v_xp_last without knowing the table internals.

CREATE OR REPLACE VIEW cross_protocol.v_xp_last AS
SELECT
    -- TVL distribution (decimal-adjusted ONyc)
    onyc_in_dexes,
    onyc_in_kamino,
    onyc_in_exponent,
    onyc_tracked_total,

    -- TVL percentages
    onyc_in_dexes_pct,
    onyc_in_kamino_pct,
    onyc_in_exponent_pct,

    -- Yields
    ROUND(COALESCE(kam_onyc_supply_apy * 100, 0)::NUMERIC, 2)  AS kam_onyc_supply_apy_pct,
    ROUND(COALESCE(kam_onyc_borrow_apy * 100, 0)::NUMERIC, 2)  AS kam_onyc_borrow_apy_pct,
    ROUND(COALESCE(kam_onyc_utilization * 100, 0)::NUMERIC, 1)  AS kam_onyc_utilization_pct,
    ROUND(COALESCE(exp_weighted_implied_apy * 100, 0)::NUMERIC, 2) AS exp_weighted_implied_apy_pct,

    -- DEX price
    dex_avg_price_t1_per_t0,

    -- Kamino risk
    kam_total_collateral_value,
    kam_total_borrow_value,
    ROUND(COALESCE(kam_weighted_avg_ltv * 100, 0)::NUMERIC, 1) AS kam_weighted_avg_ltv_pct,

    -- Metadata
    refreshed_at
FROM cross_protocol.mat_xp_last
WHERE id = 1;
