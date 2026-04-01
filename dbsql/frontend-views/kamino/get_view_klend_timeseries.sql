-- get_view_klend_timeseries: Re-bucketed read from mat_klend_*_ts_1m tables
-- Same signature pattern as the original (kamino/dbsql/views/get_view_klend_timeseries.sql)
-- Reads from pre-joined 1-minute materialized tables instead of LATERAL joins on src tables.
-- Uses dynamic reserve pivoting based on aux_market_reserve_tokens (no hardcoded addresses).

DROP FUNCTION IF EXISTS kamino_lend.get_view_klend_timeseries(TEXT, TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
CREATE OR REPLACE FUNCTION kamino_lend.get_view_klend_timeseries(
    bucket_interval TEXT DEFAULT '1 minute',
    from_ts TIMESTAMPTZ DEFAULT NOW() - INTERVAL '1 hour',
    to_ts TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
    bucket_time TIMESTAMPTZ,
    -- Borrow reserve 1 metrics (first borrow reserve by symbol order)
    reserve_brw1_symbol TEXT,
    reserve_brw1_supply_total NUMERIC,
    reserve_brw1_utilization_pct NUMERIC,
    reserve_brw1_supply_apy NUMERIC,
    reserve_brw1_borrow_apy NUMERIC,
    reserve_brw1_available NUMERIC,
    reserve_brw1_borrowed NUMERIC,
    reserve_brw1_borrowed_mktvalue NUMERIC,
    reserve_brw1_available_mktvalue NUMERIC,
    -- Borrow reserve 2 metrics (second borrow reserve)
    reserve_brw2_symbol TEXT,
    reserve_brw2_supply_total NUMERIC,
    reserve_brw2_utilization_pct NUMERIC,
    reserve_brw2_supply_apy NUMERIC,
    reserve_brw2_borrow_apy NUMERIC,
    reserve_brw2_available NUMERIC,
    reserve_brw2_borrowed NUMERIC,
    reserve_brw2_borrowed_mktvalue NUMERIC,
    reserve_brw2_available_mktvalue NUMERIC,
    -- Aggregate borrow reserves
    reserve_brw_all_supply_total NUMERIC,
    reserve_brw_all_available NUMERIC,
    reserve_brw_all_borrowed NUMERIC,
    reserve_brw_all_supply_total_mktvalue NUMERIC,
    reserve_brw_all_borrowed_mktvalue NUMERIC,
    reserve_brw_all_available_mktvalue NUMERIC,
    reserve_brw_all_utilization_pct NUMERIC,
    reserve_brw_all_agg_uf NUMERIC,
    -- Collateral reserve
    reserve_coll1_symbol TEXT,
    reserve_coll1_collateral NUMERIC,
    reserve_coll_all_collateral NUMERIC,
    -- Activity metrics (borrow reserve 1)
    reserve_brw1_deposit_sum NUMERIC,
    reserve_brw1_deposit_count BIGINT,
    reserve_brw1_withdraw_sum NUMERIC,
    reserve_brw1_withdraw_count BIGINT,
    reserve_brw1_borrow_sum NUMERIC,
    reserve_brw1_borrow_count BIGINT,
    reserve_brw1_repay_sum NUMERIC,
    reserve_brw1_repay_count BIGINT,
    reserve_brw1_liquidate_sum NUMERIC,
    reserve_brw1_liquidate_count BIGINT,
    reserve_brw1_net_flow NUMERIC,
    -- Activity metrics (borrow reserve 2)
    reserve_brw2_deposit_sum NUMERIC,
    reserve_brw2_deposit_count BIGINT,
    reserve_brw2_withdraw_sum NUMERIC,
    reserve_brw2_withdraw_count BIGINT,
    reserve_brw2_borrow_sum NUMERIC,
    reserve_brw2_borrow_count BIGINT,
    reserve_brw2_repay_sum NUMERIC,
    reserve_brw2_repay_count BIGINT,
    reserve_brw2_liquidate_sum NUMERIC,
    reserve_brw2_liquidate_count BIGINT,
    reserve_brw2_net_flow NUMERIC,
    -- Aggregate activities (market value)
    reserve_brw_all_deposit_sum NUMERIC,
    reserve_brw_all_withdraw_sum NUMERIC,
    reserve_brw_all_borrow_sum NUMERIC,
    reserve_brw_all_repay_sum NUMERIC,
    reserve_brw_all_liquidate_sum NUMERIC,
    reserve_brw_all_net_flow NUMERIC,
    -- Obligation metrics
    obl_query_id BIGINT,
    obl_market_ltv_pct NUMERIC,
    obl_loan_ltv_wtd_avg_pct NUMERIC,
    obl_loan_ltv_median_pct NUMERIC,
    obl_loan_hf_wtd_avg NUMERIC,
    obl_debt_total_unhealthy NUMERIC,
    obl_debt_total_bad NUMERIC,
    obl_debt_total_at_risk NUMERIC,
    reserve_brw_all_liquidate_sum_pct_at_risk NUMERIC,
    -- Metadata
    last_updated TIMESTAMPTZ,
    market_address TEXT
) AS $$
DECLARE
    v_interval INTERVAL;
    v_brw1_symbol TEXT;
    v_brw2_symbol TEXT;
    v_coll1_symbol TEXT;
BEGIN
    BEGIN
        v_interval := bucket_interval::INTERVAL;
    EXCEPTION WHEN OTHERS THEN
        v_interval := INTERVAL '1 minute';
    END;

    -- Dynamically determine borrow and collateral reserve symbols
    SELECT token_symbol INTO v_brw1_symbol
    FROM kamino_lend.aux_market_reserve_tokens
    WHERE reserve_type = 'borrow'
    ORDER BY token_symbol
    LIMIT 1;

    SELECT token_symbol INTO v_brw2_symbol
    FROM kamino_lend.aux_market_reserve_tokens
    WHERE reserve_type = 'borrow' AND token_symbol != v_brw1_symbol
    ORDER BY token_symbol
    LIMIT 1;

    SELECT token_symbol INTO v_coll1_symbol
    FROM kamino_lend.aux_market_reserve_tokens
    WHERE reserve_type = 'collateral'
    ORDER BY token_symbol
    LIMIT 1;

    RETURN QUERY
    WITH reserve_rebucketed AS (
        SELECT
            time_bucket(v_interval, r.bucket_time) AS bt,
            r.reserve_address,
            r.symbol,
            r.reserve_type,
            LAST(r.supply_total, r.bucket_time)     AS supply_total,
            LAST(r.supply_available, r.bucket_time)  AS supply_available,
            LAST(r.supply_borrowed, r.bucket_time)   AS supply_borrowed,
            LAST(r.collateral_total_supply, r.bucket_time) AS collateral_total_supply,
            LAST(r.utilization_ratio, r.bucket_time) AS utilization_ratio,
            LAST(r.supply_apy, r.bucket_time)        AS supply_apy,
            LAST(r.borrow_apy, r.bucket_time)        AS borrow_apy,
            LAST(r.market_price, r.bucket_time)      AS market_price,
            LAST(r.market_address, r.bucket_time)    AS market_address,
            LAST(r.vault_liquidity_marketvalue, r.bucket_time) AS vault_liquidity_marketvalue
        FROM kamino_lend.mat_klend_reserve_ts_1m r
        WHERE r.bucket_time >= from_ts AND r.bucket_time <= to_ts
        GROUP BY time_bucket(v_interval, r.bucket_time), r.reserve_address, r.symbol, r.reserve_type
    ),
    pivoted AS (
        SELECT
            rr.bt,
            MAX(rr.market_address) AS mkt_address,
            -- Borrow reserve 1
            MAX(supply_total)   FILTER (WHERE symbol = v_brw1_symbol) AS brw1_supply_total,
            MAX(utilization_ratio) FILTER (WHERE symbol = v_brw1_symbol) AS brw1_utilization,
            MAX(supply_apy) FILTER (WHERE symbol = v_brw1_symbol) AS brw1_supply_apy,
            MAX(borrow_apy) FILTER (WHERE symbol = v_brw1_symbol) AS brw1_borrow_apy,
            MAX(supply_available) FILTER (WHERE symbol = v_brw1_symbol) AS brw1_available,
            MAX(supply_borrowed) FILTER (WHERE symbol = v_brw1_symbol) AS brw1_borrowed,
            MAX(market_price) FILTER (WHERE symbol = v_brw1_symbol) AS brw1_price,
            -- Borrow reserve 2
            MAX(supply_total) FILTER (WHERE symbol = v_brw2_symbol) AS brw2_supply_total,
            MAX(utilization_ratio) FILTER (WHERE symbol = v_brw2_symbol) AS brw2_utilization,
            MAX(supply_apy) FILTER (WHERE symbol = v_brw2_symbol) AS brw2_supply_apy,
            MAX(borrow_apy) FILTER (WHERE symbol = v_brw2_symbol) AS brw2_borrow_apy,
            MAX(supply_available) FILTER (WHERE symbol = v_brw2_symbol) AS brw2_available,
            MAX(supply_borrowed) FILTER (WHERE symbol = v_brw2_symbol) AS brw2_borrowed,
            MAX(market_price) FILTER (WHERE symbol = v_brw2_symbol) AS brw2_price,
            -- Aggregate borrow
            SUM(supply_total) FILTER (WHERE reserve_type = 'borrow') AS brw_all_supply_total,
            SUM(vault_liquidity_marketvalue) FILTER (WHERE reserve_type = 'borrow') AS brw_all_available_mktval,
            SUM(supply_borrowed * market_price) FILTER (WHERE reserve_type = 'borrow') AS brw_all_borrowed_mktval,
            SUM(supply_total * market_price) FILTER (WHERE reserve_type = 'borrow') AS brw_all_supply_total_mktval,
            -- Collateral
            MAX(collateral_total_supply) FILTER (WHERE symbol = v_coll1_symbol) AS coll1_collateral,
            SUM(collateral_total_supply) FILTER (WHERE reserve_type = 'collateral') AS coll_all_collateral
        FROM reserve_rebucketed rr
        GROUP BY rr.bt
    ),
    obligation_rebucketed AS (
        SELECT
            time_bucket(v_interval, o.bucket_time) AS bt,
            LAST(o.obligation_query_id, o.bucket_time) AS obligation_query_id,
            LAST(o.market_capacity_utilization_pct, o.bucket_time) AS market_cap_util,
            LAST(o.weighted_avg_loan_to_value_sig, o.bucket_time) AS wtd_avg_ltv,
            LAST(o.median_loan_to_value_sig, o.bucket_time) AS median_ltv,
            LAST(o.weighted_avg_health_factor_sig, o.bucket_time) AS wtd_avg_hf,
            LAST(o.total_unhealthy_debt, o.bucket_time) AS unhealthy_debt,
            LAST(o.total_bad_debt, o.bucket_time) AS bad_debt
        FROM kamino_lend.mat_klend_obligation_ts_1m o
        WHERE o.bucket_time >= from_ts AND o.bucket_time <= to_ts
        GROUP BY time_bucket(v_interval, o.bucket_time)
    ),
    activity_rebucketed AS (
        SELECT
            time_bucket(v_interval, a.bucket_time) AS bt,
            a.symbol,
            SUM(a.deposit_vault_sum) AS deposit_sum,
            SUM(a.deposit_vault_count) AS deposit_count,
            SUM(a.withdraw_vault_sum) AS withdraw_sum,
            SUM(a.withdraw_vault_count) AS withdraw_count,
            SUM(a.borrowing_sum) AS borrow_sum,
            SUM(a.borrowing_count) AS borrow_count,
            SUM(a.repay_borrowing_sum) AS repay_sum,
            SUM(a.repay_borrowing_count) AS repay_count,
            SUM(a.liquidate_borrowing_sum) AS liquidate_sum,
            SUM(a.liquidate_borrowing_count) AS liquidate_count
        FROM kamino_lend.mat_klend_activity_ts_1m a
        WHERE a.bucket_time >= from_ts AND a.bucket_time <= to_ts
        GROUP BY time_bucket(v_interval, a.bucket_time), a.symbol
    ),
    act_pivoted AS (
        SELECT
            bt,
            MAX(deposit_sum)     FILTER (WHERE symbol = v_brw1_symbol) AS brw1_deposit_sum,
            MAX(deposit_count)   FILTER (WHERE symbol = v_brw1_symbol) AS brw1_deposit_count,
            MAX(withdraw_sum)    FILTER (WHERE symbol = v_brw1_symbol) AS brw1_withdraw_sum,
            MAX(withdraw_count)  FILTER (WHERE symbol = v_brw1_symbol) AS brw1_withdraw_count,
            MAX(borrow_sum)      FILTER (WHERE symbol = v_brw1_symbol) AS brw1_borrow_sum,
            MAX(borrow_count)    FILTER (WHERE symbol = v_brw1_symbol) AS brw1_borrow_count,
            MAX(repay_sum)       FILTER (WHERE symbol = v_brw1_symbol) AS brw1_repay_sum,
            MAX(repay_count)     FILTER (WHERE symbol = v_brw1_symbol) AS brw1_repay_count,
            MAX(liquidate_sum)   FILTER (WHERE symbol = v_brw1_symbol) AS brw1_liquidate_sum,
            MAX(liquidate_count) FILTER (WHERE symbol = v_brw1_symbol) AS brw1_liquidate_count,
            MAX(deposit_sum)     FILTER (WHERE symbol = v_brw2_symbol) AS brw2_deposit_sum,
            MAX(deposit_count)   FILTER (WHERE symbol = v_brw2_symbol) AS brw2_deposit_count,
            MAX(withdraw_sum)    FILTER (WHERE symbol = v_brw2_symbol) AS brw2_withdraw_sum,
            MAX(withdraw_count)  FILTER (WHERE symbol = v_brw2_symbol) AS brw2_withdraw_count,
            MAX(borrow_sum)      FILTER (WHERE symbol = v_brw2_symbol) AS brw2_borrow_sum,
            MAX(borrow_count)    FILTER (WHERE symbol = v_brw2_symbol) AS brw2_borrow_count,
            MAX(repay_sum)       FILTER (WHERE symbol = v_brw2_symbol) AS brw2_repay_sum,
            MAX(repay_count)     FILTER (WHERE symbol = v_brw2_symbol) AS brw2_repay_count,
            MAX(liquidate_sum)   FILTER (WHERE symbol = v_brw2_symbol) AS brw2_liquidate_sum,
            MAX(liquidate_count) FILTER (WHERE symbol = v_brw2_symbol) AS brw2_liquidate_count
        FROM activity_rebucketed
        GROUP BY bt
    )
    SELECT
        p.bt,
        v_brw1_symbol,
        ROUND(p.brw1_supply_total::NUMERIC, 0),
        ROUND(p.brw1_utilization * 100, 1),
        ROUND(p.brw1_supply_apy * 100, 1),
        ROUND(p.brw1_borrow_apy * 100, 1),
        ROUND(p.brw1_available::NUMERIC, 0),
        ROUND(p.brw1_borrowed::NUMERIC, 0),
        ROUND((p.brw1_borrowed * p.brw1_price)::NUMERIC, 0),
        ROUND((p.brw1_available * p.brw1_price)::NUMERIC, 0),
        v_brw2_symbol,
        ROUND(p.brw2_supply_total::NUMERIC, 0),
        ROUND(p.brw2_utilization * 100, 1),
        ROUND(p.brw2_supply_apy * 100, 1),
        ROUND(p.brw2_borrow_apy * 100, 1),
        ROUND(p.brw2_available::NUMERIC, 0),
        ROUND(p.brw2_borrowed::NUMERIC, 0),
        ROUND((p.brw2_borrowed * p.brw2_price)::NUMERIC, 0),
        ROUND((p.brw2_available * p.brw2_price)::NUMERIC, 0),
        ROUND(p.brw_all_supply_total::NUMERIC, 0),
        ROUND(p.brw_all_available_mktval::NUMERIC, 0),
        ROUND(p.brw_all_borrowed_mktval::NUMERIC, 0),
        ROUND(p.brw_all_supply_total_mktval::NUMERIC, 0),
        ROUND(p.brw_all_borrowed_mktval::NUMERIC, 0),
        ROUND(p.brw_all_available_mktval::NUMERIC, 0),
        ROUND((p.brw_all_borrowed_mktval / NULLIF(p.brw_all_supply_total_mktval, 0) * 100)::NUMERIC, 1),
        ROUND((p.brw_all_borrowed_mktval / NULLIF(p.brw_all_supply_total_mktval, 0) * 100)::NUMERIC, 1),
        v_coll1_symbol,
        ROUND(p.coll1_collateral::NUMERIC, 0),
        ROUND(p.coll_all_collateral::NUMERIC, 0),
        -- Brw1 activities (from pre-pivoted CTE)
        ROUND(COALESCE(ap.brw1_deposit_sum, 0)::NUMERIC, 0),
        COALESCE(ap.brw1_deposit_count, 0)::BIGINT,
        ROUND(COALESCE(ap.brw1_withdraw_sum, 0)::NUMERIC, 0),
        COALESCE(ap.brw1_withdraw_count, 0)::BIGINT,
        ROUND(COALESCE(ap.brw1_borrow_sum, 0)::NUMERIC, 0),
        COALESCE(ap.brw1_borrow_count, 0)::BIGINT,
        ROUND(COALESCE(ap.brw1_repay_sum, 0)::NUMERIC, 0),
        COALESCE(ap.brw1_repay_count, 0)::BIGINT,
        ROUND(COALESCE(ap.brw1_liquidate_sum, 0)::NUMERIC, 0),
        COALESCE(ap.brw1_liquidate_count, 0)::BIGINT,
        ROUND((COALESCE(ap.brw1_deposit_sum, 0) + COALESCE(ap.brw1_repay_sum, 0) + COALESCE(ap.brw1_liquidate_sum, 0)
             - COALESCE(ap.brw1_withdraw_sum, 0) - COALESCE(ap.brw1_borrow_sum, 0))::NUMERIC, 0),
        -- Brw2 activities (from pre-pivoted CTE)
        ROUND(COALESCE(ap.brw2_deposit_sum, 0)::NUMERIC, 0),
        COALESCE(ap.brw2_deposit_count, 0)::BIGINT,
        ROUND(COALESCE(ap.brw2_withdraw_sum, 0)::NUMERIC, 0),
        COALESCE(ap.brw2_withdraw_count, 0)::BIGINT,
        ROUND(COALESCE(ap.brw2_borrow_sum, 0)::NUMERIC, 0),
        COALESCE(ap.brw2_borrow_count, 0)::BIGINT,
        ROUND(COALESCE(ap.brw2_repay_sum, 0)::NUMERIC, 0),
        COALESCE(ap.brw2_repay_count, 0)::BIGINT,
        ROUND(COALESCE(ap.brw2_liquidate_sum, 0)::NUMERIC, 0),
        COALESCE(ap.brw2_liquidate_count, 0)::BIGINT,
        ROUND((COALESCE(ap.brw2_deposit_sum, 0) + COALESCE(ap.brw2_repay_sum, 0) + COALESCE(ap.brw2_liquidate_sum, 0)
             - COALESCE(ap.brw2_withdraw_sum, 0) - COALESCE(ap.brw2_borrow_sum, 0))::NUMERIC, 0),
        -- Aggregate activities (market value — price-weighted from brw1 + brw2)
        ROUND((COALESCE(ap.brw1_deposit_sum * p.brw1_price, 0) + COALESCE(ap.brw2_deposit_sum * p.brw2_price, 0))::NUMERIC, 0),
        ROUND((COALESCE(ap.brw1_withdraw_sum * p.brw1_price, 0) + COALESCE(ap.brw2_withdraw_sum * p.brw2_price, 0))::NUMERIC, 0),
        ROUND((COALESCE(ap.brw1_borrow_sum * p.brw1_price, 0) + COALESCE(ap.brw2_borrow_sum * p.brw2_price, 0))::NUMERIC, 0),
        ROUND((COALESCE(ap.brw1_repay_sum * p.brw1_price, 0) + COALESCE(ap.brw2_repay_sum * p.brw2_price, 0))::NUMERIC, 0),
        ROUND((COALESCE(ap.brw1_liquidate_sum * p.brw1_price, 0) + COALESCE(ap.brw2_liquidate_sum * p.brw2_price, 0))::NUMERIC, 0),
        ROUND((COALESCE((COALESCE(ap.brw1_deposit_sum, 0) + COALESCE(ap.brw1_repay_sum, 0) + COALESCE(ap.brw1_liquidate_sum, 0)
             - COALESCE(ap.brw1_withdraw_sum, 0) - COALESCE(ap.brw1_borrow_sum, 0)) * p.brw1_price, 0)
             + COALESCE((COALESCE(ap.brw2_deposit_sum, 0) + COALESCE(ap.brw2_repay_sum, 0) + COALESCE(ap.brw2_liquidate_sum, 0)
             - COALESCE(ap.brw2_withdraw_sum, 0) - COALESCE(ap.brw2_borrow_sum, 0)) * p.brw2_price, 0))::NUMERIC, 0),
        -- Obligations
        o.obligation_query_id,
        ROUND(o.market_cap_util, 1),
        ROUND(o.wtd_avg_ltv, 1),
        ROUND(o.median_ltv, 1),
        ROUND(o.wtd_avg_hf, 2),
        ROUND(o.unhealthy_debt::NUMERIC, 0),
        ROUND(o.bad_debt::NUMERIC, 0),
        ROUND((COALESCE(o.unhealthy_debt, 0) + COALESCE(o.bad_debt, 0))::NUMERIC, 0),
        ROUND(CASE
            WHEN (COALESCE(o.unhealthy_debt, 0) + COALESCE(o.bad_debt, 0)) > 0
            THEN (COALESCE(ap.brw1_liquidate_sum * p.brw1_price, 0) + COALESCE(ap.brw2_liquidate_sum * p.brw2_price, 0))
                 / (COALESCE(o.unhealthy_debt, 0) + COALESCE(o.bad_debt, 0)) * 100
            ELSE NULL
        END::NUMERIC, 2),
        -- Metadata
        p.bt,
        p.mkt_address
    FROM pivoted p
    LEFT JOIN obligation_rebucketed o ON o.bt = p.bt
    LEFT JOIN act_pivoted ap ON ap.bt = p.bt
    ORDER BY p.bt;
END;
$$ LANGUAGE plpgsql STABLE;
