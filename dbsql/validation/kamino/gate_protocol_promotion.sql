-- Protocol promotion gate
-- Returns readiness decision, hard failures, and non-blocking warnings.

WITH params AS (
    SELECT
        'ONyc'::TEXT AS p_coll_symbol,
        ARRAY['ONyc']::TEXT[] AS p_coll_assets,
        NULL::TEXT[] AS p_lend_assets,
        'weighted'::TEXT AS p_pool_mode,
        'blended'::TEXT AS p_bonus_mode,
        10::INTEGER AS p_max_rounds,
        0.1::NUMERIC AS p_convergence_threshold_pct,
        INTERVAL '14 days' AS p_observed_window,
        -20.0::NUMERIC AS p_proxy_shock_pct,
        0.10::NUMERIC AS p_max_observed_mape
),
helpers AS (
    SELECT
        to_regprocedure('kamino_lend.simulate_protocol_liquidation(bigint,integer,integer,integer,integer,boolean,text[],text[],text)') IS NOT NULL
            AS protocol_function_present
),
model_window AS (
    SELECT
        MIN(o.block_time) AS model_min_ts,
        MAX(o.block_time) AS model_max_ts
    FROM kamino_lend.src_obligations_last o
),
observed_window AS (
    SELECT
        MIN(e.meta_block_time) FILTER (WHERE e.activity_category = 'liquidate') AS obs_min_ts,
        MAX(e.meta_block_time) FILTER (WHERE e.activity_category = 'liquidate') AS obs_max_ts
    FROM kamino_lend.src_txn_events e
),
coverage_check AS (
    SELECT
        mw.model_min_ts,
        mw.model_max_ts,
        ow.obs_min_ts,
        ow.obs_max_ts,
        GREATEST(mw.model_min_ts, ow.obs_min_ts) AS overlap_start,
        LEAST(mw.model_max_ts, ow.obs_max_ts) AS overlap_end,
        CASE
            WHEN GREATEST(mw.model_min_ts, ow.obs_min_ts) <= LEAST(mw.model_max_ts, ow.obs_max_ts) THEN TRUE
            ELSE FALSE
        END AS has_overlap
    FROM model_window mw
    CROSS JOIN observed_window ow
),
target_reserve AS (
    SELECT mrt.reserve_address
    FROM params p
    JOIN kamino_lend.aux_market_reserve_tokens mrt
      ON mrt.token_symbol = p.p_coll_symbol
     AND mrt.env_market_address_matches = TRUE
    LIMIT 1
),
latest_reserve_price AS (
    SELECT DISTINCT ON (r.reserve_address)
        r.reserve_address,
        COALESCE(r.oracle_price, 0)::NUMERIC AS oracle_price,
        GREATEST(COALESCE(r.env_decimals, 0), 0)::INTEGER AS token_decimals
    FROM kamino_lend.src_reserves r
    ORDER BY r.reserve_address, r.time DESC
),
observed_liq AS (
    SELECT
        date_trunc('day', e.meta_block_time) AS bucket_day,
        SUM(
            COALESCE(e.collateral_amount, 0)::NUMERIC
            / NULLIF(POWER(10::NUMERIC, lp.token_decimals), 0)
            * COALESCE(lp.oracle_price, 0)
        ) AS observed_collateral_usd
    FROM params p
    JOIN target_reserve tr ON TRUE
    JOIN kamino_lend.src_txn_events e
      ON e.activity_category = 'liquidate'
     AND e.withdraw_reserve_address = tr.reserve_address
     AND e.meta_block_time >= NOW() - p.p_observed_window
    LEFT JOIN latest_reserve_price lp
      ON lp.reserve_address = e.withdraw_reserve_address
    GROUP BY 1
),
observed_summary AS (
    SELECT
        COUNT(*)::INTEGER AS observed_days,
        COALESCE(AVG(ol.observed_collateral_usd), 0)::NUMERIC AS observed_daily_avg_collateral_usd
    FROM observed_liq ol
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
heuristic_run AS (
    SELECT c.*
    FROM params p
    CROSS JOIN LATERAL kamino_lend.simulate_cascade_amplification(
        NULL, -100, 50, 100, 50, FALSE,
        p.p_coll_assets, p.p_lend_assets, p.p_coll_symbol, p.p_pool_mode, p.p_bonus_mode,
        'heuristic', p.p_max_rounds, p.p_convergence_threshold_pct
    ) c
),
invariants AS (
    SELECT
        BOOL_AND(COALESCE(pr.sell_qty_tokens, 0) >= 0) AS protocol_non_negative_sell_qty,
        BOOL_AND(COALESCE(pr.pool_depth_used_pct, 0) >= 0) AS protocol_non_negative_depth_pct,
        BOOL_AND(pr.cascade_rounds <= (SELECT p_max_rounds FROM params)) AS protocol_converged_within_limit
    FROM protocol_run pr
),
monotonic_left AS (
    SELECT
        COALESCE(BOOL_AND(curr.total_liquidated_usd >= curr.prev_total_liq), TRUE) AS left_monotonic_non_decreasing
    FROM (
        SELECT
            initial_shock_pct,
            MAX(total_liquidated_usd) AS total_liquidated_usd,
            LAG(MAX(total_liquidated_usd)) OVER (ORDER BY initial_shock_pct DESC) AS prev_total_liq
        FROM protocol_run
        WHERE initial_shock_pct <= 0
        GROUP BY initial_shock_pct
    ) curr
    WHERE curr.prev_total_liq IS NOT NULL
),
monotonic_right AS (
    SELECT
        COALESCE(BOOL_AND(curr.total_liquidated_usd >= curr.prev_total_liq), TRUE) AS right_monotonic_non_decreasing
    FROM (
        SELECT
            initial_shock_pct,
            MAX(total_liquidated_usd) AS total_liquidated_usd,
            LAG(MAX(total_liquidated_usd)) OVER (ORDER BY initial_shock_pct) AS prev_total_liq
        FROM protocol_run
        WHERE initial_shock_pct > 0
        GROUP BY initial_shock_pct
    ) curr
    WHERE curr.prev_total_liq IS NOT NULL
),
mode_diff AS (
    SELECT
        AVG(ABS(COALESCE(pr.sell_qty_tokens, 0) - COALESCE(hr.sell_qty_tokens, 0))) AS mae_sell_qty_tokens,
        AVG(ABS(COALESCE(pr.pool_impact_pct, 0) - COALESCE(hr.pool_impact_pct, 0))) AS mae_pool_impact_pct
    FROM protocol_run pr
    JOIN heuristic_run hr
      ON hr.initial_shock_pct = pr.initial_shock_pct
     AND hr.pool_address = pr.pool_address
),
protocol_proxy AS (
    SELECT
        pr.initial_shock_pct,
        pr.liq_value_post_bonus_usd AS proxy_liq_usd
    FROM params p
    JOIN LATERAL (
        SELECT *
        FROM protocol_run
        ORDER BY ABS(initial_shock_pct - p.p_proxy_shock_pct), pool_weight DESC
        LIMIT 1
    ) pr ON TRUE
),
observed_accuracy AS (
    SELECT
        os.observed_days,
        os.observed_daily_avg_collateral_usd,
        pp.proxy_liq_usd,
        CASE
            WHEN os.observed_daily_avg_collateral_usd = 0 THEN NULL
            ELSE ABS(pp.proxy_liq_usd - os.observed_daily_avg_collateral_usd)
                 / os.observed_daily_avg_collateral_usd
        END AS observed_mape
    FROM observed_summary os
    CROSS JOIN protocol_proxy pp
),
fail_reasons AS (
    SELECT ARRAY_REMOVE(ARRAY[
        CASE WHEN NOT h.protocol_function_present THEN 'missing_protocol_function' END,
        CASE WHEN oa.observed_days > 0 AND NOT cc.has_overlap THEN 'insufficient_model_observed_overlap' END,
        CASE WHEN NOT i.protocol_non_negative_sell_qty THEN 'negative_sell_qty_detected' END,
        CASE WHEN NOT i.protocol_non_negative_depth_pct THEN 'negative_pool_depth_detected' END,
        CASE WHEN NOT i.protocol_converged_within_limit THEN 'convergence_limit_exceeded' END,
        CASE WHEN NOT ml.left_monotonic_non_decreasing THEN 'left_side_monotonicity_failed' END,
        CASE WHEN NOT mr.right_monotonic_non_decreasing THEN 'right_side_monotonicity_failed' END,
        CASE
            WHEN oa.observed_days > 0
             AND oa.observed_mape IS NOT NULL
             AND oa.observed_mape > (SELECT p_max_observed_mape FROM params)
            THEN 'observed_accuracy_threshold_failed'
        END
    ], NULL) AS reasons
    FROM helpers h
    CROSS JOIN coverage_check cc
    CROSS JOIN invariants i
    CROSS JOIN monotonic_left ml
    CROSS JOIN monotonic_right mr
    CROSS JOIN observed_accuracy oa
),
validation_warnings AS (
    SELECT ARRAY_REMOVE(ARRAY[
        CASE WHEN oa.observed_days = 0 THEN 'no_observed_liquidation_data_in_window' END
    ], NULL) AS warnings
    FROM observed_accuracy oa
)
SELECT
    (CARDINALITY(fr.reasons) = 0) AS protocol_default_ready,
    fr.reasons AS failure_reasons,
    vw.warnings AS validation_warnings,
    md.mae_sell_qty_tokens,
    md.mae_pool_impact_pct,
    oa.observed_days,
    oa.observed_daily_avg_collateral_usd,
    oa.proxy_liq_usd AS protocol_proxy_liq_usd,
    oa.observed_mape,
    cc.model_min_ts,
    cc.model_max_ts,
    cc.obs_min_ts,
    cc.obs_max_ts,
    cc.overlap_start,
    cc.overlap_end
FROM fail_reasons fr
CROSS JOIN validation_warnings vw
CROSS JOIN mode_diff md
CROSS JOIN observed_accuracy oa
CROSS JOIN coverage_check cc;
