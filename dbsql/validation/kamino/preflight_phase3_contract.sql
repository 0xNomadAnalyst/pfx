-- Phase 3/4 Preflight Contract Checks
-- Purpose:
--   1) Verify helper-function availability
--   2) Verify per-leg array alignment on src_obligations_last
--   3) Verify snapshot semantics and historical backtest feasibility
--   4) Verify observed-event coverage windows overlap model inputs

WITH required_helpers AS (
    SELECT unnest(ARRAY[
        'kamino_lend.compute_stressed_share(text[],numeric[],text[],text[],text[])',
        'kamino_lend.sensitize_value_partial(numeric,numeric,integer,integer)',
        'kamino_lend.compute_ltv_array(numeric[],numeric[])',
        'kamino_lend.resolve_dex_pool(text)',
        'kamino_lend.is_unhealthy_from_values(numeric[],numeric[],numeric,numeric)',
        'kamino_lend.is_bad_from_values(numeric[],numeric[],numeric)',
        'kamino_lend.calculate_health_factor_array(numeric[],numeric[],numeric)',
        'kamino_lend.sum_array_elementwise(numeric[][])',
        'kamino_lend.average_array_elementwise(numeric[][])',
        'kamino_lend.sensitize_liquidation_distance(numeric[],numeric[],numeric)'
    ]) AS helper_signature
),
helper_presence AS (
    SELECT
        rh.helper_signature,
        to_regprocedure(rh.helper_signature) IS NOT NULL AS is_available
    FROM required_helpers rh
),
array_alignment AS (
    SELECT
        COUNT(*) AS obligations_checked,
        COUNT(*) FILTER (
            WHERE COALESCE(array_length(deposit_reserve_by_asset, 1), 0)
               != COALESCE(array_length(deposit_market_value_sf_by_asset, 1), 0)
               OR COALESCE(array_length(deposit_reserve_by_asset, 1), 0)
               != COALESCE(array_length(deposited_amount_by_asset, 1), 0)
        ) AS deposit_array_mismatches,
        COUNT(*) FILTER (
            WHERE COALESCE(array_length(borrow_reserve_by_asset, 1), 0)
               != COALESCE(array_length(borrow_market_value_sf_by_asset, 1), 0)
               OR COALESCE(array_length(borrow_reserve_by_asset, 1), 0)
               != COALESCE(array_length(borrowed_amount_sf_by_asset, 1), 0)
               OR COALESCE(array_length(borrow_reserve_by_asset, 1), 0)
               != COALESCE(array_length(borrow_factor_adjusted_market_value_sf_by_asset, 1), 0)
        ) AS borrow_array_mismatches,
        COUNT(*) FILTER (
            WHERE COALESCE(array_length(resrv_address, 1), 0)
               != COALESCE(array_length(resrv_symbol, 1), 0)
               OR COALESCE(array_length(resrv_address, 1), 0)
               != COALESCE(array_length(resrv_loan_to_value_pct, 1), 0)
               OR COALESCE(array_length(resrv_address, 1), 0)
               != COALESCE(array_length(resrv_liquidation_threshold_pct, 1), 0)
        ) AS reserve_array_mismatches
    FROM kamino_lend.src_obligations_last
),
snapshot_semantics AS (
    SELECT
        COUNT(DISTINCT query_id) AS distinct_query_ids_in_last,
        MIN(block_time) AS obligations_min_block_time,
        MAX(block_time) AS obligations_max_block_time
    FROM kamino_lend.src_obligations_last
),
historical_obligations AS (
    SELECT
        to_regclass('kamino_lend.src_obligations') IS NOT NULL AS historical_table_exists
),
observed_window AS (
    SELECT
        MIN(e.meta_block_time) FILTER (WHERE e.activity_category = 'liquidate') AS liq_min_block_time,
        MAX(e.meta_block_time) FILTER (WHERE e.activity_category = 'liquidate') AS liq_max_block_time
    FROM kamino_lend.src_txn_events e
),
window_overlap AS (
    SELECT
        s.obligations_min_block_time,
        s.obligations_max_block_time,
        o.liq_min_block_time,
        o.liq_max_block_time,
        GREATEST(s.obligations_min_block_time, o.liq_min_block_time) AS overlap_start,
        LEAST(s.obligations_max_block_time, o.liq_max_block_time) AS overlap_end
    FROM snapshot_semantics s
    CROSS JOIN observed_window o
)
SELECT
    'helper_presence' AS check_group,
    hp.helper_signature AS check_name,
    hp.is_available::TEXT AS check_value
FROM helper_presence hp

UNION ALL

SELECT
    'array_alignment',
    'obligations_checked',
    aa.obligations_checked::TEXT
FROM array_alignment aa

UNION ALL

SELECT
    'array_alignment',
    'deposit_array_mismatches',
    aa.deposit_array_mismatches::TEXT
FROM array_alignment aa

UNION ALL

SELECT
    'array_alignment',
    'borrow_array_mismatches',
    aa.borrow_array_mismatches::TEXT
FROM array_alignment aa

UNION ALL

SELECT
    'array_alignment',
    'reserve_array_mismatches',
    aa.reserve_array_mismatches::TEXT
FROM array_alignment aa

UNION ALL

SELECT
    'snapshot_semantics',
    'distinct_query_ids_in_last',
    ss.distinct_query_ids_in_last::TEXT
FROM snapshot_semantics ss

UNION ALL

SELECT
    'historical_obligations',
    'historical_table_exists',
    ho.historical_table_exists::TEXT
FROM historical_obligations ho

UNION ALL

SELECT
    'window_overlap',
    'overlap_is_nonempty',
    CASE WHEN wo.overlap_start <= wo.overlap_end THEN 'true' ELSE 'false' END
FROM window_overlap wo

UNION ALL

SELECT
    'window_overlap',
    'overlap_start',
    COALESCE(wo.overlap_start::TEXT, 'NULL')
FROM window_overlap wo

UNION ALL

SELECT
    'window_overlap',
    'overlap_end',
    COALESCE(wo.overlap_end::TEXT, 'NULL')
FROM window_overlap wo
ORDER BY check_group, check_name;
