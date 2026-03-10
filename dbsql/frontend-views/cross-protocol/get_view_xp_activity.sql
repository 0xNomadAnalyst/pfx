-- get_view_xp_activity: Cross-protocol activity aggregation for a given interval.
-- Sums activity flows across DEXes, Kamino, and Exponent for the most recent
-- interval_literal period, returning a single row with absolute volumes and
-- percentage shares. Serves the activity pie-chart widgets.
--
-- Parameters:
--   interval_literal  TEXT  e.g. '1 hour', '24 hours', '7 days'

CREATE OR REPLACE FUNCTION cross_protocol.get_view_xp_activity(
    interval_literal TEXT DEFAULT '24 hours'
)
RETURNS TABLE (
    -- DEX flows
    dex_swap_volume          NUMERIC,
    dex_lp_volume            NUMERIC,
    dex_total_volume         NUMERIC,
    -- Kamino flows
    kam_deposit_volume       NUMERIC,
    kam_withdraw_volume      NUMERIC,
    kam_borrow_volume        NUMERIC,
    kam_repay_volume         NUMERIC,
    kam_liquidate_volume     NUMERIC,
    kam_total_volume         NUMERIC,
    -- Exponent flows
    exp_pt_trade_volume      NUMERIC,
    exp_lp_volume            NUMERIC,
    exp_total_volume         NUMERIC,
    -- Cross-protocol totals
    all_protocol_volume      NUMERIC,
    -- Activity percentage of total
    dex_volume_pct           NUMERIC,
    kam_volume_pct           NUMERIC,
    exp_volume_pct           NUMERIC
) AS $$
DECLARE
    v_interval   INTERVAL;
    v_start_time TIMESTAMPTZ;
BEGIN
    BEGIN
        v_interval := interval_literal::INTERVAL;
    EXCEPTION WHEN OTHERS THEN
        v_interval := INTERVAL '24 hours';
    END;

    v_start_time := NOW() - v_interval;

    RETURN QUERY
    WITH agg AS (
        SELECT
            SUM(m.dex_swap_volume)      AS dex_swap,
            SUM(m.dex_lp_volume)        AS dex_lp,
            SUM(m.dex_total_volume)     AS dex_total,
            SUM(m.kam_deposit_volume)   AS kam_dep,
            SUM(m.kam_withdraw_volume)  AS kam_wdr,
            SUM(m.kam_borrow_volume)    AS kam_brw,
            SUM(m.kam_repay_volume)     AS kam_rpy,
            SUM(m.kam_liquidate_volume) AS kam_liq,
            SUM(m.kam_total_volume)     AS kam_total,
            SUM(m.exp_pt_trade_volume)  AS exp_pt,
            SUM(m.exp_lp_volume)        AS exp_lp,
            SUM(m.exp_total_volume)     AS exp_total,
            SUM(m.all_protocol_volume)  AS all_total
        FROM cross_protocol.mat_xp_ts_1m m
        WHERE m.bucket_time >= v_start_time
          AND m.bucket_time <  NOW()
    )
    SELECT
        ROUND(COALESCE(a.dex_swap,  0)::NUMERIC, 0),
        ROUND(COALESCE(a.dex_lp,    0)::NUMERIC, 0),
        ROUND(COALESCE(a.dex_total, 0)::NUMERIC, 0),
        ROUND(COALESCE(a.kam_dep,   0)::NUMERIC, 0),
        ROUND(COALESCE(a.kam_wdr,   0)::NUMERIC, 0),
        ROUND(COALESCE(a.kam_brw,   0)::NUMERIC, 0),
        ROUND(COALESCE(a.kam_rpy,   0)::NUMERIC, 0),
        ROUND(COALESCE(a.kam_liq,   0)::NUMERIC, 0),
        ROUND(COALESCE(a.kam_total, 0)::NUMERIC, 0),
        ROUND(COALESCE(a.exp_pt,    0)::NUMERIC, 0),
        ROUND(COALESCE(a.exp_lp,    0)::NUMERIC, 0),
        ROUND(COALESCE(a.exp_total, 0)::NUMERIC, 0),
        ROUND(COALESCE(a.all_total, 0)::NUMERIC, 0),
        -- Percentages
        ROUND(COALESCE(a.dex_total / NULLIF(a.all_total, 0) * 100, 0)::NUMERIC, 1),
        ROUND(COALESCE(a.kam_total / NULLIF(a.all_total, 0) * 100, 0)::NUMERIC, 1),
        ROUND(COALESCE(a.exp_total / NULLIF(a.all_total, 0) * 100, 0)::NUMERIC, 1)
    FROM agg a;
END;
$$ LANGUAGE plpgsql STABLE;
