-- Compare model outputs to observed liquidation/swap activity.
--
-- IMPORTANT:
-- src_obligations_last is latest-state by design, so this query is a forward/proxy
-- validation view unless historical obligation snapshots are provided separately.

WITH params AS (
    SELECT
        'ONyc'::TEXT AS p_coll_symbol,
        ARRAY['ONyc']::TEXT[] AS p_coll_assets,
        NULL::TEXT[] AS p_lend_assets,
        INTERVAL '14 days' AS p_observed_window,
        -20.0::NUMERIC AS p_proxy_shock_pct,
        'weighted'::TEXT AS p_pool_mode,
        'blended'::TEXT AS p_bonus_mode
),
target_reserve AS (
    SELECT
        mrt.reserve_address
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
        COALESCE(r.env_decimals, 0)::INTEGER AS token_decimals
    FROM kamino_lend.src_reserves r
    ORDER BY r.reserve_address, r.time DESC
),
observed_liq AS (
    SELECT
        date_trunc('day', e.meta_block_time) AS bucket_day,
        SUM(
            COALESCE(e.collateral_amount, 0)::NUMERIC
            / NULLIF(POWER(10::NUMERIC, GREATEST(COALESCE(lp.token_decimals, 0), 0)), 0)
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
observed_swaps AS (
    SELECT
        date_trunc('day', d.meta_block_time) AS bucket_day,
        AVG(ABS(COALESCE(d.c_swap_est_impact_bps, 0))) AS avg_abs_swap_impact_bps
    FROM params p
    JOIN dexes.src_tx_events d
      ON d.meta_success = TRUE
     AND d.meta_block_time >= NOW() - p.p_observed_window
     AND (d.swap_token_in_symbol = p.p_coll_symbol OR d.swap_token_out_symbol = p.p_coll_symbol)
    GROUP BY 1
),
protocol_curve AS (
    SELECT
        c.*
    FROM params p
    CROSS JOIN LATERAL kamino_lend.simulate_cascade_amplification(
        NULL, -100, 50, 100, 50, FALSE,
        p.p_coll_assets, p.p_lend_assets, p.p_coll_symbol, p.p_pool_mode, p.p_bonus_mode,
        'protocol', 10, 0.1
    ) c
),
heuristic_curve AS (
    SELECT
        c.*
    FROM params p
    CROSS JOIN LATERAL kamino_lend.simulate_cascade_amplification(
        NULL, -100, 50, 100, 50, FALSE,
        p.p_coll_assets, p.p_lend_assets, p.p_coll_symbol, p.p_pool_mode, p.p_bonus_mode,
        'heuristic', 10, 0.1
    ) c
),
model_proxy AS (
    SELECT
        'protocol'::TEXT AS model_mode,
        pc.initial_shock_pct,
        pc.liq_value_post_bonus_usd AS model_proxy_liq_usd,
        pc.pool_impact_pct AS model_proxy_pool_impact_pct
    FROM params p
    JOIN LATERAL (
        SELECT *
        FROM protocol_curve
        ORDER BY ABS(initial_shock_pct - p.p_proxy_shock_pct), pool_weight DESC
        LIMIT 1
    ) pc ON TRUE

    UNION ALL

    SELECT
        'heuristic'::TEXT,
        hc.initial_shock_pct,
        hc.liq_value_post_bonus_usd,
        hc.pool_impact_pct
    FROM params p
    JOIN LATERAL (
        SELECT *
        FROM heuristic_curve
        ORDER BY ABS(initial_shock_pct - p.p_proxy_shock_pct), pool_weight DESC
        LIMIT 1
    ) hc ON TRUE
),
observed_summary AS (
    SELECT
        COUNT(*) AS observed_days,
        COALESCE(AVG(ol.observed_collateral_usd), 0) AS observed_daily_avg_collateral_usd,
        COALESCE(SUM(ol.observed_collateral_usd), 0) AS observed_total_collateral_usd,
        COALESCE(AVG(os.avg_abs_swap_impact_bps), 0) AS observed_daily_avg_swap_impact_bps
    FROM observed_liq ol
    LEFT JOIN observed_swaps os
      ON os.bucket_day = ol.bucket_day
),
scored AS (
    SELECT
        mp.model_mode,
        mp.initial_shock_pct,
        mp.model_proxy_liq_usd,
        mp.model_proxy_pool_impact_pct,
        os.observed_days,
        os.observed_daily_avg_collateral_usd,
        os.observed_total_collateral_usd,
        os.observed_daily_avg_swap_impact_bps,
        ABS(mp.model_proxy_liq_usd - os.observed_daily_avg_collateral_usd) AS mae_proxy_liq_usd,
        CASE
            WHEN os.observed_daily_avg_collateral_usd = 0 THEN NULL
            ELSE ABS(mp.model_proxy_liq_usd - os.observed_daily_avg_collateral_usd)
                 / os.observed_daily_avg_collateral_usd
        END AS mape_proxy_liq
    FROM model_proxy mp
    CROSS JOIN observed_summary os
)
SELECT *
FROM scored
ORDER BY model_mode;
