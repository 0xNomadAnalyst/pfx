-- Compare heuristic vs protocol cascade outputs
-- Produces per-shock/per-pool diffs plus summary metrics.

WITH params AS (
    SELECT
        NULL::BIGINT AS p_query_id,
        -100::INTEGER AS p_assets_delta_bps,
        50::INTEGER AS p_assets_delta_steps,
        100::INTEGER AS p_liabilities_delta_bps,
        50::INTEGER AS p_liabilities_delta_steps,
        FALSE::BOOLEAN AS p_include_zero_borrows,
        ARRAY['ONyc']::TEXT[] AS p_coll_assets,
        NULL::TEXT[] AS p_lend_assets,
        'ONyc'::TEXT AS p_coll_symbol,
        'weighted'::TEXT AS p_pool_mode,
        'blended'::TEXT AS p_bonus_mode,
        10::INTEGER AS p_max_rounds,
        0.1::NUMERIC AS p_convergence_threshold_pct
),
heuristic AS (
    SELECT
        'heuristic'::TEXT AS model_mode,
        c.*
    FROM params p
    CROSS JOIN LATERAL kamino_lend.simulate_cascade_amplification(
        p.p_query_id,
        p.p_assets_delta_bps,
        p.p_assets_delta_steps,
        p.p_liabilities_delta_bps,
        p.p_liabilities_delta_steps,
        p.p_include_zero_borrows,
        p.p_coll_assets,
        p.p_lend_assets,
        p.p_coll_symbol,
        p.p_pool_mode,
        p.p_bonus_mode,
        'heuristic',
        p.p_max_rounds,
        p.p_convergence_threshold_pct
    ) c
),
protocol AS (
    SELECT
        'protocol'::TEXT AS model_mode,
        c.*
    FROM params p
    CROSS JOIN LATERAL kamino_lend.simulate_cascade_amplification(
        p.p_query_id,
        p.p_assets_delta_bps,
        p.p_assets_delta_steps,
        p.p_liabilities_delta_bps,
        p.p_liabilities_delta_steps,
        p.p_include_zero_borrows,
        p.p_coll_assets,
        p.p_lend_assets,
        p.p_coll_symbol,
        p.p_pool_mode,
        p.p_bonus_mode,
        'protocol',
        p.p_max_rounds,
        p.p_convergence_threshold_pct
    ) c
),
paired AS (
    SELECT
        COALESCE(h.initial_shock_pct, pr.initial_shock_pct) AS initial_shock_pct,
        COALESCE(h.pool_address, pr.pool_address) AS pool_address,
        h.total_liquidated_usd AS heuristic_total_liquidated_usd,
        pr.total_liquidated_usd AS protocol_total_liquidated_usd,
        h.sell_qty_tokens AS heuristic_sell_qty_tokens,
        pr.sell_qty_tokens AS protocol_sell_qty_tokens,
        h.pool_impact_pct AS heuristic_pool_impact_pct,
        pr.pool_impact_pct AS protocol_pool_impact_pct,
        h.cascade_rounds AS heuristic_cascade_rounds,
        pr.cascade_rounds AS protocol_cascade_rounds,
        CASE
            WHEN COALESCE(h.sell_qty_tokens, 0) = 0 THEN NULL
            ELSE (pr.sell_qty_tokens - h.sell_qty_tokens) / NULLIF(h.sell_qty_tokens, 0)
        END AS sell_qty_delta_ratio
    FROM heuristic h
    FULL OUTER JOIN protocol pr
      ON pr.initial_shock_pct = h.initial_shock_pct
     AND pr.pool_address = h.pool_address
),
summary AS (
    SELECT
        AVG(ABS(COALESCE(protocol_sell_qty_tokens, 0) - COALESCE(heuristic_sell_qty_tokens, 0))) AS mae_sell_qty_tokens,
        AVG(ABS(COALESCE(protocol_total_liquidated_usd, 0) - COALESCE(heuristic_total_liquidated_usd, 0))) AS mae_total_liquidated_usd,
        AVG(ABS(COALESCE(protocol_pool_impact_pct, 0) - COALESCE(heuristic_pool_impact_pct, 0))) AS mae_pool_impact_pct,
        AVG(COALESCE(sell_qty_delta_ratio, 0)) AS avg_sell_qty_delta_ratio,
        MAX(COALESCE(protocol_cascade_rounds, 0)) AS max_protocol_rounds,
        MAX(COALESCE(heuristic_cascade_rounds, 0)) AS max_heuristic_rounds
    FROM paired
)
SELECT
    'row_diff' AS record_type,
    p.initial_shock_pct,
    p.pool_address,
    p.heuristic_total_liquidated_usd,
    p.protocol_total_liquidated_usd,
    p.heuristic_sell_qty_tokens,
    p.protocol_sell_qty_tokens,
    p.heuristic_pool_impact_pct,
    p.protocol_pool_impact_pct,
    p.heuristic_cascade_rounds,
    p.protocol_cascade_rounds,
    p.sell_qty_delta_ratio,
    NULL::NUMERIC AS mae_sell_qty_tokens,
    NULL::NUMERIC AS mae_total_liquidated_usd,
    NULL::NUMERIC AS mae_pool_impact_pct,
    NULL::NUMERIC AS avg_sell_qty_delta_ratio
FROM paired p

UNION ALL

SELECT
    'summary',
    NULL::NUMERIC,
    NULL::TEXT,
    NULL::NUMERIC,
    NULL::NUMERIC,
    NULL::NUMERIC,
    NULL::NUMERIC,
    NULL::NUMERIC,
    NULL::NUMERIC,
    s.max_heuristic_rounds::INTEGER,
    s.max_protocol_rounds::INTEGER,
    NULL::NUMERIC,
    s.mae_sell_qty_tokens,
    s.mae_total_liquidated_usd,
    s.mae_pool_impact_pct,
    s.avg_sell_qty_delta_ratio
FROM summary s
ORDER BY record_type, initial_shock_pct NULLS LAST, pool_address NULLS LAST;
