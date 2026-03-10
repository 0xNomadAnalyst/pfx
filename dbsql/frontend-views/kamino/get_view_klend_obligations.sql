-- NAME: get_view_klend_obligations (OPTIMIZED - UPDATED 2025-12-06)
-- DESCRIPTION: Returns obligation details from src_obligations_last table (latest state only)
--
-- MIGRATION NOTE (2025-12-06):
--   - Now queries src_obligations_last directly instead of historical src_obligations
--   - Removed query_id lookup step - src_obligations_last already contains latest state
--   - Much faster performance - queries ~2,600 rows instead of 233M historical rows
--   - Date parameter now filters block_time directly in src_obligations_last
--
-- OPTIMIZATION IMPROVEMENTS:
-- 1. Added MATERIALIZED hint to CTE (PostgreSQL 12+)
-- 2. Simplified window function usage - calculate once at end
-- 3. Pre-filter data before window functions to reduce computation
-- 4. Direct query to src_obligations_last (latest state table)
-- 5. Removed query_id lookup - significant performance improvement
--
-- PARAMETERS:
--   date: TIMESTAMPTZ - Filter obligations with block_time <= this date
--   rank_field: TEXT - Column name to order by (must match final alias names)
--                      Special value 'risk_priority' applies custom multi-level sorting:
--                        1) Bad/Unhealthy obligations first, sorted by HF ASC then debt DESC
--                        2) Near-liquidation obligations, sorted by HF ASC then debt DESC
--                        3) Healthy obligations, sorted by debt DESC only
--   order_direction: TEXT - 'asc' or 'desc' for ordering (ignored for 'risk_priority')
--   rows: INTEGER - Number of rows to return (LIMIT), optional (defaults to no limit)
--   include_zero_borrows: BOOLEAN - If TRUE, includes obligations with borrow < $1 (defaults to FALSE)

CREATE OR REPLACE FUNCTION kamino_lend.get_view_klend_obligations(
    date TIMESTAMPTZ,
    rank_field TEXT,
    order_direction TEXT,
    rows INTEGER DEFAULT NULL,
    include_zero_borrows BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    query_id BIGINT,
    block_time TIMESTAMPTZ,
    obligation_address TEXT,
    loan_value_total NUMERIC,
    loan_value_total_pct_debt NUMERIC,
    collateral_value_total NUMERIC,
    collateral_value_total_pct_collateral NUMERIC,
    liquidatable_value NUMERIC,
    ltv_pct NUMERIC,
    health_factor NUMERIC,
    liquidation_buffer_pct NUMERIC,
    is_healthy_below_1pt1 BOOLEAN,
    is_unhealthy BOOLEAN,
    is_bad BOOLEAN,
    status TEXT
) AS $$
DECLARE
    order_clause TEXT;
BEGIN
    -- Validate rank_field parameter
    IF rank_field NOT IN (
        'query_id', 'block_time', 'obligation_address', 'loan_value_total',
        'loan_value_total_pct_debt', 'collateral_value_total', 'collateral_value_total_pct_collateral',
        'liquidatable_value', 'ltv_pct', 'health_factor', 'liquidation_buffer_pct',
        'is_healthy_below_1pt1', 'is_unhealthy', 'is_bad', 'status', 'risk_priority'
    ) THEN
        RAISE EXCEPTION 'Invalid rank_field: %. Must be one of: query_id, block_time, obligation_address, loan_value_total, loan_value_total_pct_debt, collateral_value_total, collateral_value_total_pct_collateral, liquidatable_value, ltv_pct, health_factor, liquidation_buffer_pct, is_healthy_below_1pt1, is_unhealthy, is_bad, status, risk_priority', rank_field;
    END IF;

    -- Validate order_direction parameter (not used for risk_priority but still validate)
    IF LOWER(order_direction) NOT IN ('asc', 'desc') THEN
        RAISE EXCEPTION 'Invalid order_direction: %. Must be ''asc'' or ''desc''', order_direction;
    END IF;

    -- Build dynamic ORDER BY clause
    IF rank_field = 'risk_priority' THEN
        -- Custom multi-level risk-based sorting:
        -- 1) Bad/Unhealthy first, sorted by HF ASC, then debt DESC
        -- 2) Near-liquidation (healthy_below_1_1), sorted by HF ASC, then debt DESC
        -- 3) Healthy last, sorted by debt DESC only
        order_clause := 'ORDER BY
            CASE
                WHEN f.c_is_bad_debt OR f.c_is_unhealthy THEN 1
                WHEN f.c_is_healthy_below_1_1 THEN 2
                ELSE 3
            END ASC,
            CASE
                WHEN f.c_is_bad_debt OR f.c_is_unhealthy OR f.c_is_healthy_below_1_1 THEN f.c_health_factor
                ELSE NULL
            END ASC NULLS LAST,
            f.c_user_total_borrow DESC';
    ELSE
        order_clause := format('ORDER BY %I %s', rank_field, UPPER(order_direction));
    END IF;

    -- Build LIMIT clause if rows is provided
    IF rows IS NOT NULL THEN
        order_clause := order_clause || format(' LIMIT %s', rows);
    END IF;

    -- Return the query results directly from src_obligations_last
    -- OPTIMIZATION: Query src_obligations_last table directly (contains only most recent state of each obligation)
    -- No need to lookup query_id - this table is already filtered to latest state
    RETURN QUERY EXECUTE format('
        WITH filtered_obligations AS MATERIALIZED (
            SELECT
                o.query_id,
                o.block_time,
                o.obligation_address,
                o.c_user_total_borrow,
                o.c_user_total_deposit,
                o.c_liquidatable_value,
                o.c_loan_to_value_pct,
                o.c_health_factor,
                o.c_liquidation_buffer_pct,
                o.c_is_healthy_below_1_1,
                o.c_is_unhealthy,
                o.c_is_bad_debt
            FROM kamino_lend.src_obligations_last o
            WHERE o.block_time <= $1
                AND ($2 OR o.c_user_total_borrow >= 1)
        )
        SELECT
            f.query_id,
            f.block_time,
            f.obligation_address,
            ROUND(f.c_user_total_borrow::NUMERIC, 0) AS loan_value_total,
            ROUND((f.c_user_total_borrow / NULLIF(SUM(f.c_user_total_borrow) OVER (), 0)) * 100, 2) AS loan_value_total_pct_debt,
            ROUND(f.c_user_total_deposit::NUMERIC, 0) AS collateral_value_total,
            ROUND((f.c_user_total_deposit / NULLIF(SUM(f.c_user_total_deposit) OVER (), 0)) * 100, 2) AS collateral_value_total_pct_collateral,
            ROUND(f.c_liquidatable_value::NUMERIC, 0) AS liquidatable_value,
            ROUND(f.c_loan_to_value_pct, 1) AS ltv_pct,
            ROUND(f.c_health_factor, 2) AS health_factor,
            ROUND(f.c_liquidation_buffer_pct, 1) AS liquidation_buffer_pct,
            f.c_is_healthy_below_1_1 AS is_healthy_below_1pt1,
            f.c_is_unhealthy AS is_unhealthy,
            f.c_is_bad_debt AS is_bad,
            CASE
                WHEN f.c_is_bad_debt THEN %L
                WHEN f.c_is_unhealthy THEN %L
                WHEN f.c_is_healthy_below_1_1 THEN %L
                ELSE %L
            END AS status
        FROM filtered_obligations f
        %s',
        'Bad', 'Unhealthy', 'Near Liquidation', 'Healthy', order_clause
    ) USING date, include_zero_borrows;
END;
$$ LANGUAGE plpgsql STABLE;

-- Add function comment
COMMENT ON FUNCTION kamino_lend.get_view_klend_obligations(TIMESTAMPTZ, TEXT, TEXT, INTEGER, BOOLEAN) IS
'OPTIMIZED (UPDATED 2025-12-06): Returns obligation details from src_obligations_last table (latest state only).
MIGRATION: Now queries src_obligations_last directly - much faster than historical src_obligations table.
Key optimizations: Direct query to latest-state table (~2.6K rows vs 233M historical), MATERIALIZED CTE, pre-filtering.
Parameters:
- date: Filter obligations with block_time <= this date (from src_obligations_last)
- rank_field: Column name to order by (must match final alias names)
              Special value ''risk_priority'' applies custom multi-level sorting:
                1) Bad/Unhealthy obligations first, sorted by HF ASC then debt DESC
                2) Near-liquidation obligations, sorted by HF ASC then debt DESC
                3) Healthy obligations, sorted by debt DESC only
- order_direction: ''asc'' or ''desc'' for ordering (ignored for ''risk_priority'')
- rows: Number of rows to return (LIMIT), optional (defaults to no limit)
- include_zero_borrows: If TRUE, includes obligations with borrow < $1 (defaults to FALSE)
Returns obligation data with calculated percentages and precision formatting.
By default, only returns obligations with borrow >= $1 (c_user_total_borrow >= 1).';

-- ========================================================================
-- INDEXES
-- ========================================================================
-- src_obligations_last already has appropriate indexes (see src_obligations_last.sql):
-- - PK on obligation_address
-- - idx_obligations_last_block_time (for date filtering)
-- - idx_obligations_last_active_debt (for has_debt filtering)
-- No additional indexes needed for this function

-- ========================================================================
-- USAGE EXAMPLES
-- ========================================================================

-- Example 1: Get top 10 obligations by health factor (ascending - riskiest first)
-- SELECT * FROM kamino_lend.get_view_klend_obligations(NOW(), 'health_factor', 'asc', 10, FALSE);

-- Example 2: Get all obligations ordered by loan value (descending - largest first)
-- SELECT * FROM kamino_lend.get_view_klend_obligations(NOW(), 'loan_value_total', 'desc', NULL, FALSE);

-- Example 3: Get obligations from specific date, including zero borrows
-- SELECT * FROM kamino_lend.get_view_klend_obligations('2024-11-01'::TIMESTAMPTZ, 'ltv_pct', 'desc', 50, TRUE);

-- Example 4: Get bad debt obligations
-- SELECT * FROM kamino_lend.get_view_klend_obligations(NOW(), 'loan_value_total', 'desc', NULL, FALSE)
-- WHERE is_bad = TRUE;

-- Example 5: Get obligations sorted by risk priority (custom multi-level sort)
-- Bad/Unhealthy first (by HF asc, debt desc), then Near Liquidation (by HF asc, debt desc), then Healthy (by debt desc)
-- SELECT * FROM kamino_lend.get_view_klend_obligations(NOW(), 'risk_priority', 'asc', NULL, FALSE);

