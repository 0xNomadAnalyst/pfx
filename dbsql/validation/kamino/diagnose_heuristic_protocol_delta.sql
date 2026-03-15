-- Diagnose heuristic-vs-protocol divergence by shock level.
-- Focus: where sell-qty deltas concentrate and whether full-liquidation overrides
-- or bad-debt composition explain the gap.

WITH params AS (
    SELECT
        'ONyc'::TEXT AS p_coll_symbol,
        ARRAY['ONyc']::TEXT[] AS p_coll_assets,
        NULL::TEXT[] AS p_lend_assets,
        'weighted'::TEXT AS p_pool_mode,
        'blended'::TEXT AS p_bonus_mode,
        10::INTEGER AS p_max_rounds,
        0.1::NUMERIC AS p_convergence_threshold_pct
),
heuristic_run AS (
    SELECT c.*
    FROM params p
    CROSS JOIN LATERAL kamino_lend.simulate_cascade_amplification(
        NULL, -100, 50, 100, 50, FALSE,
        p.p_coll_assets, p.p_lend_assets, p.p_coll_symbol, p.p_pool_mode, p.p_bonus_mode,
        'heuristic', p.p_max_rounds, p.p_convergence_threshold_pct
    ) c
),
protocol_run AS (
    SELECT c.*
    FROM params p
    CROSS JOIN LATERAL kamino_lend.simulate_cascade_amplification(
        NULL, -100, 50, 100, 50, FALSE,
        p.p_coll_assets, p.p_lend_assets, p.p_coll_symbol, p.p_pool_mode, p.p_bonus_mode,
        'protocol', p.p_max_rounds, p.p_convergence_threshold_pct
    ) c
),
curve_protocol AS (
    SELECT
        s.pct_change::NUMERIC AS initial_shock_pct,
        s.bad_debt_share,
        s.full_liq_override_share,
        s.obligations_full_liq_override,
        s.obligations_unhealthy,
        s.obligations_bad_debt
    FROM params p
    CROSS JOIN LATERAL kamino_lend.simulate_protocol_liquidation(
        NULL, -100, 50, 100, 50, FALSE,
        p.p_coll_assets, p.p_lend_assets, p.p_coll_symbol
    ) s
),
shock_agg AS (
    SELECT
        COALESCE(h.initial_shock_pct, pr.initial_shock_pct) AS initial_shock_pct,
        SUM(COALESCE(h.sell_qty_tokens, 0)) AS heuristic_sell_qty_tokens,
        SUM(COALESCE(pr.sell_qty_tokens, 0)) AS protocol_sell_qty_tokens,
        SUM(COALESCE(h.total_liquidated_usd, 0)) AS heuristic_total_liq_usd,
        SUM(COALESCE(pr.total_liquidated_usd, 0)) AS protocol_total_liq_usd,
        AVG(COALESCE(h.pool_impact_pct, 0)) AS heuristic_avg_pool_impact_pct,
        AVG(COALESCE(pr.pool_impact_pct, 0)) AS protocol_avg_pool_impact_pct
    FROM heuristic_run h
    FULL OUTER JOIN protocol_run pr
      ON pr.initial_shock_pct = h.initial_shock_pct
     AND pr.pool_address = h.pool_address
    GROUP BY 1
),
ranked AS (
    SELECT
        sa.*,
        (sa.protocol_sell_qty_tokens - sa.heuristic_sell_qty_tokens) AS delta_sell_qty_tokens,
        CASE
            WHEN sa.heuristic_sell_qty_tokens = 0 THEN NULL
            ELSE (sa.protocol_sell_qty_tokens / sa.heuristic_sell_qty_tokens) - 1
        END AS delta_sell_qty_ratio,
        ABS(sa.protocol_sell_qty_tokens - sa.heuristic_sell_qty_tokens) AS abs_delta_sell_qty_tokens
    FROM shock_agg sa
)
SELECT
    r.initial_shock_pct,
    r.heuristic_sell_qty_tokens,
    r.protocol_sell_qty_tokens,
    r.delta_sell_qty_tokens,
    r.delta_sell_qty_ratio,
    r.heuristic_total_liq_usd,
    r.protocol_total_liq_usd,
    r.heuristic_avg_pool_impact_pct,
    r.protocol_avg_pool_impact_pct,
    cp.bad_debt_share,
    cp.full_liq_override_share,
    cp.obligations_full_liq_override,
    cp.obligations_unhealthy,
    cp.obligations_bad_debt
FROM ranked r
LEFT JOIN curve_protocol cp
  ON cp.initial_shock_pct = r.initial_shock_pct
ORDER BY r.initial_shock_pct;
