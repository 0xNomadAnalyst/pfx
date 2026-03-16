-- mat_dex_timeseries_1m: Pre-joined 4-CAGG timeseries at 1-minute grain with LOCF
-- Eliminates the expensive per-request multi-CAGG join + window functions in get_view_dex_timeseries
-- Frontend views re-bucket from this table using simple time_bucket() aggregation

CREATE TABLE IF NOT EXISTS dexes.mat_dex_timeseries_1m (
    bucket_time                 TIMESTAMPTZ NOT NULL,
    pool_address                TEXT        NOT NULL,
    protocol                    TEXT,
    token_pair                  TEXT,
    symbols_t0_t1               TEXT[],

    -- Swap event metrics (SUM aggregation within 1m bucket)
    swap_count                  BIGINT      DEFAULT 0,
    swap_t0_in                  NUMERIC     DEFAULT 0,
    swap_t0_out                 NUMERIC     DEFAULT 0,
    swap_t0_net                 NUMERIC     DEFAULT 0,
    swap_t1_in                  NUMERIC     DEFAULT 0,
    swap_t1_out                 NUMERIC     DEFAULT 0,
    swap_t1_net                 NUMERIC     DEFAULT 0,

    -- LP event metrics (SUM aggregation within 1m bucket)
    lp_count                    BIGINT      DEFAULT 0,
    lp_t0_in                    NUMERIC     DEFAULT 0,
    lp_t0_out                   NUMERIC     DEFAULT 0,
    lp_t0_net                   NUMERIC     DEFAULT 0,
    lp_t1_in                    NUMERIC     DEFAULT 0,
    lp_t1_out                   NUMERIC     DEFAULT 0,
    lp_t1_net                   NUMERIC     DEFAULT 0,

    -- VWAP metrics (LAST within 1m bucket, LOCF across buckets)
    vwap_buy_t0                 NUMERIC(20,8),
    vwap_sell_t0                NUMERIC(20,8),

    -- Price impact statistics from events (AVG within 1m bucket)
    avg_est_swap_impact_bps     NUMERIC(20,6),
    min_est_swap_impact_bps_t0_sell NUMERIC(20,4),
    avg_est_swap_impact_bps_all NUMERIC(20,4),
    max_est_swap_impact_bps_t1_sell NUMERIC(20,4),

    -- Pool state from cagg_tickarrays_5s (LAST within 1m, LOCF across)
    current_tick                INTEGER,
    current_tick_float          NUMERIC(20,4),
    sqrt_price_x64              NUMERIC(40,0),
    price_t1_per_t0             NUMERIC(20,8),

    -- Impact metrics from tickarrays - selling token0 (LAST within 1m, LOCF across)
    impact_from_t0_sell1_avg    NUMERIC(10,2),
    impact_from_t0_sell2_avg    NUMERIC(10,2),
    impact_from_t0_sell3_avg    NUMERIC(10,2),
    sell_t0_for_impact1_avg     NUMERIC,
    sell_t0_for_impact2_avg     NUMERIC,
    sell_t0_for_impact3_avg     NUMERIC,

    -- Impact metrics from tickarrays - selling token1 (LAST within 1m, LOCF across)
    impact_from_t1_sell1_avg    NUMERIC(10,2),
    impact_from_t1_sell2_avg    NUMERIC(10,2),
    impact_from_t1_sell3_avg    NUMERIC(10,2),
    sell_t1_for_impact1_avg     NUMERIC,
    sell_t1_for_impact2_avg     NUMERIC,
    sell_t1_for_impact3_avg     NUMERIC,

    -- Concentration metrics (AVG within 1m, LOCF across)
    concentration_peg_pct_1     NUMERIC(10,4),
    concentration_peg_pct_2     NUMERIC(10,4),
    concentration_peg_pct_3     NUMERIC(10,4),
    concentration_peg_halfspread_bps_array INTEGER[],
    concentration_active_pct_1  NUMERIC(10,4),
    concentration_active_pct_2  NUMERIC(10,4),
    concentration_active_pct_3  NUMERIC(10,4),
    concentration_active_halfspread_bps_array INTEGER[],

    -- Vault reserve metrics from cagg_vaults_5s (LAST within 1m, LOCF across)
    t0_reserve                  NUMERIC,
    t1_reserve                  NUMERIC,

    -- Tick crossing metrics from cagg_poolstate_5s (SUM within 1m)
    tick_cross_count            BIGINT      DEFAULT 0,
    poolstate_current_liquidity_t1_units   DOUBLE PRECISION,
    poolstate_first_liquidity_t1_units     DOUBLE PRECISION,

    refreshed_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (pool_address, bucket_time)
);

SELECT create_hypertable(
    'dexes.mat_dex_timeseries_1m', 'bucket_time',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_mat_dex_ts_1m_pool
    ON dexes.mat_dex_timeseries_1m (pool_address, bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_mat_dex_ts_1m_pair
    ON dexes.mat_dex_timeseries_1m (token_pair, bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_mat_dex_ts_1m_proto_pair
    ON dexes.mat_dex_timeseries_1m (protocol, token_pair, bucket_time DESC);

-- ---------------------------------------------------------------------------
-- Refresh procedure: incremental upsert of last 30 minutes
-- Joins the 4 CAGGs at 1-minute grain and applies LOCF for state columns.
-- Uses a 5-minute overlap window for LOCF seeding.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE dexes.refresh_mat_dex_timeseries_1m(
    p_lookback INTERVAL DEFAULT INTERVAL '30 minutes'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_refresh_from TIMESTAMPTZ := NOW() - p_lookback;
    v_seed_from    TIMESTAMPTZ := NOW() - p_lookback - INTERVAL '5 minutes';
BEGIN
    DELETE FROM dexes.mat_dex_timeseries_1m
    WHERE bucket_time >= v_refresh_from;

    INSERT INTO dexes.mat_dex_timeseries_1m (
        bucket_time, pool_address, protocol, token_pair, symbols_t0_t1,
        swap_count, swap_t0_in, swap_t0_out, swap_t0_net,
        swap_t1_in, swap_t1_out, swap_t1_net,
        lp_count, lp_t0_in, lp_t0_out, lp_t0_net,
        lp_t1_in, lp_t1_out, lp_t1_net,
        vwap_buy_t0, vwap_sell_t0,
        avg_est_swap_impact_bps, min_est_swap_impact_bps_t0_sell, avg_est_swap_impact_bps_all,
        max_est_swap_impact_bps_t1_sell,
        current_tick, current_tick_float, sqrt_price_x64, price_t1_per_t0,
        impact_from_t0_sell1_avg, impact_from_t0_sell2_avg, impact_from_t0_sell3_avg,
        sell_t0_for_impact1_avg, sell_t0_for_impact2_avg, sell_t0_for_impact3_avg,
        impact_from_t1_sell1_avg, impact_from_t1_sell2_avg, impact_from_t1_sell3_avg,
        sell_t1_for_impact1_avg, sell_t1_for_impact2_avg, sell_t1_for_impact3_avg,
        concentration_peg_pct_1, concentration_peg_pct_2, concentration_peg_pct_3,
        concentration_peg_halfspread_bps_array,
        concentration_active_pct_1, concentration_active_pct_2, concentration_active_pct_3,
        concentration_active_halfspread_bps_array,
        t0_reserve, t1_reserve,
        tick_cross_count, poolstate_current_liquidity_t1_units, poolstate_first_liquidity_t1_units,
        refreshed_at
    )
    WITH pools AS (
        SELECT pool_address, token0_symbol, token1_symbol, protocol, token_pair
        FROM dexes.pool_tokens_reference
    ),
    -- 1-minute buckets from cagg_events_5s (single-pass for swap + lp)
    events_1m AS (
        SELECT
            time_bucket('1 minute', e.bucket_time) AS bt,
            e.pool_address,
            MAX(e.protocol)       AS protocol,
            MAX(e.token_pair)     AS token_pair,
            SUM(e.event_count) FILTER (WHERE e.activity_category = 'swap')::BIGINT AS swap_count,
            SUM(e.amount0_in) FILTER (WHERE e.activity_category = 'swap')    AS swap_t0_in,
            SUM(e.amount0_out) FILTER (WHERE e.activity_category = 'swap')   AS swap_t0_out,
            SUM(e.amount0_net) FILTER (WHERE e.activity_category = 'swap')   AS swap_t0_net,
            SUM(e.amount1_in) FILTER (WHERE e.activity_category = 'swap')    AS swap_t1_in,
            SUM(e.amount1_out) FILTER (WHERE e.activity_category = 'swap')   AS swap_t1_out,
            SUM(e.amount1_net) FILTER (WHERE e.activity_category = 'swap')   AS swap_t1_net,
            SUM(e.event_count) FILTER (WHERE e.activity_category = 'lp')::BIGINT AS lp_count,
            SUM(e.amount0_in) FILTER (WHERE e.activity_category = 'lp')      AS lp_t0_in,
            SUM(e.amount0_out) FILTER (WHERE e.activity_category = 'lp')     AS lp_t0_out,
            SUM(e.amount0_net) FILTER (WHERE e.activity_category = 'lp')     AS lp_t0_net,
            SUM(e.amount1_in) FILTER (WHERE e.activity_category = 'lp')      AS lp_t1_in,
            SUM(e.amount1_out) FILTER (WHERE e.activity_category = 'lp')     AS lp_t1_out,
            SUM(e.amount1_net) FILTER (WHERE e.activity_category = 'lp')     AS lp_t1_net,
            -- Volume-weighted VWAP within the 1m bucket
            CASE WHEN SUM(e.amount0_out) FILTER (WHERE e.activity_category = 'swap' AND e.vwap_buy_t0 IS NOT NULL AND e.vwap_buy_t0 <> 0) > 0
                 THEN SUM(e.vwap_buy_t0 * e.amount0_out) FILTER (WHERE e.activity_category = 'swap' AND e.vwap_buy_t0 IS NOT NULL AND e.vwap_buy_t0 <> 0)
                      / SUM(e.amount0_out) FILTER (WHERE e.activity_category = 'swap' AND e.vwap_buy_t0 IS NOT NULL AND e.vwap_buy_t0 <> 0)
                 ELSE NULL END AS vwap_buy_t0,
            CASE WHEN SUM(e.amount0_in) FILTER (WHERE e.activity_category = 'swap' AND e.vwap_sell_t0 IS NOT NULL AND e.vwap_sell_t0 <> 0) > 0
                 THEN SUM(e.vwap_sell_t0 * e.amount0_in) FILTER (WHERE e.activity_category = 'swap' AND e.vwap_sell_t0 IS NOT NULL AND e.vwap_sell_t0 <> 0)
                      / SUM(e.amount0_in) FILTER (WHERE e.activity_category = 'swap' AND e.vwap_sell_t0 IS NOT NULL AND e.vwap_sell_t0 <> 0)
                 ELSE NULL END AS vwap_sell_t0,
            AVG(e.c_swap_est_impact_bps_avg) FILTER (WHERE e.activity_category = 'swap' AND e.c_swap_est_impact_bps_avg IS NOT NULL) AS avg_est_swap_impact_bps,
            MIN(e.c_swap_est_impact_bps_min_t0_sell) FILTER (WHERE e.activity_category = 'swap' AND e.c_swap_est_impact_bps_min_t0_sell IS NOT NULL) AS min_est_swap_impact_bps_t0_sell,
            AVG(e.c_swap_est_impact_bps_avg) FILTER (WHERE e.activity_category = 'swap' AND e.c_swap_est_impact_bps_avg IS NOT NULL) AS avg_est_swap_impact_bps_all,
            MAX(e.c_swap_est_impact_bps_max_t1_sell) FILTER (WHERE e.activity_category = 'swap' AND e.c_swap_est_impact_bps_max_t1_sell IS NOT NULL) AS max_est_swap_impact_bps_t1_sell
        FROM dexes.cagg_events_5s e
        WHERE e.activity_category IN ('swap', 'lp')
          AND e.bucket_time >= v_seed_from
        GROUP BY time_bucket('1 minute', e.bucket_time), e.pool_address
    ),
    tick_1m AS (
        SELECT
            time_bucket('1 minute', t.bucket) AS bt,
            t.pool_address,
            LAST(t.current_tick, t.bucket)       AS current_tick,
            LAST(t.current_tick_float, t.bucket) AS current_tick_float,
            LAST(t.sqrt_price_x64, t.bucket)     AS sqrt_price_x64,
            LAST(t.price_t1_per_t0, t.bucket)    AS price_t1_per_t0,
            AVG(t.impact_from_t0_sell1_avg)       AS impact_from_t0_sell1_avg,
            AVG(t.impact_from_t0_sell2_avg)       AS impact_from_t0_sell2_avg,
            AVG(t.impact_from_t0_sell3_avg)       AS impact_from_t0_sell3_avg,
            AVG(t.sell_t0_for_impact1_avg)        AS sell_t0_for_impact1_avg,
            AVG(t.sell_t0_for_impact2_avg)        AS sell_t0_for_impact2_avg,
            AVG(t.sell_t0_for_impact3_avg)        AS sell_t0_for_impact3_avg,
            AVG(t.impact_from_t1_sell1_avg)       AS impact_from_t1_sell1_avg,
            AVG(t.impact_from_t1_sell2_avg)       AS impact_from_t1_sell2_avg,
            AVG(t.impact_from_t1_sell3_avg)       AS impact_from_t1_sell3_avg,
            AVG(t.sell_t1_for_impact1_avg)        AS sell_t1_for_impact1_avg,
            AVG(t.sell_t1_for_impact2_avg)        AS sell_t1_for_impact2_avg,
            AVG(t.sell_t1_for_impact3_avg)        AS sell_t1_for_impact3_avg,
            AVG(t.liq_pct_within_xticks_of_peg_1) AS concentration_peg_pct_1,
            AVG(t.liq_pct_within_xticks_of_peg_2) AS concentration_peg_pct_2,
            AVG(t.liq_pct_within_xticks_of_peg_3) AS concentration_peg_pct_3,
            (SELECT ARRAY_AGG(x::NUMERIC::INTEGER) FROM jsonb_array_elements_text(LAST(t.liq_pct_within_xticks_of_peg_levels, t.bucket)) AS x) AS concentration_peg_halfspread_bps_array,
            AVG(t.liq_pct_within_xticks_of_active_1) AS concentration_active_pct_1,
            AVG(t.liq_pct_within_xticks_of_active_2) AS concentration_active_pct_2,
            AVG(t.liq_pct_within_xticks_of_active_3) AS concentration_active_pct_3,
            (SELECT ARRAY_AGG(x::NUMERIC::INTEGER) FROM jsonb_array_elements_text(LAST(t.liq_pct_within_xticks_of_active_levels, t.bucket)) AS x) AS concentration_active_halfspread_bps_array
        FROM dexes.cagg_tickarrays_5s t
        WHERE t.bucket >= v_seed_from
        GROUP BY time_bucket('1 minute', t.bucket), t.pool_address
    ),
    vault_1m AS (
        SELECT
            time_bucket('1 minute', v.bucket_time) AS bt,
            v.pool_address,
            LAST(v.token_0_value, v.bucket_time)::NUMERIC AS t0_reserve,
            LAST(v.token_1_value, v.bucket_time)::NUMERIC AS t1_reserve
        FROM dexes.cagg_vaults_5s v
        WHERE v.bucket_time >= v_seed_from
        GROUP BY time_bucket('1 minute', v.bucket_time), v.pool_address
    ),
    poolstate_1m AS (
        SELECT
            time_bucket('1 minute', p.bucket_time) AS bt,
            p.pool_address,
            SUM(p.tick_cross_count)::BIGINT AS tick_cross_count,
            LAST(p.current_liquidity_t1_units, p.bucket_time) AS current_liquidity_t1_units,
            FIRST(p.first_liquidity_t1_units, p.bucket_time) AS first_liquidity_t1_units
        FROM dexes.cagg_poolstate_5s p
        WHERE p.bucket_time >= v_seed_from
        GROUP BY time_bucket('1 minute', p.bucket_time), p.pool_address
    ),
    -- Union all bucket times per pool to get a complete time grid
    all_buckets AS (
        SELECT DISTINCT bt, pool_address FROM events_1m
        UNION SELECT DISTINCT bt, pool_address FROM tick_1m
        UNION SELECT DISTINCT bt, pool_address FROM vault_1m
        UNION SELECT DISTINCT bt, pool_address FROM poolstate_1m
    ),
    -- Join all sources
    combined AS (
        SELECT
            ab.bt,
            ab.pool_address,
            COALESCE(ev.protocol, p.protocol) AS protocol,
            COALESCE(ev.token_pair, p.token_pair) AS token_pair,
            ARRAY[p.token0_symbol, p.token1_symbol] AS symbols_t0_t1,
            COALESCE(ev.swap_count, 0)     AS swap_count,
            COALESCE(ev.swap_t0_in, 0)     AS swap_t0_in,
            COALESCE(ev.swap_t0_out, 0)    AS swap_t0_out,
            COALESCE(ev.swap_t0_net, 0)    AS swap_t0_net,
            COALESCE(ev.swap_t1_in, 0)     AS swap_t1_in,
            COALESCE(ev.swap_t1_out, 0)    AS swap_t1_out,
            COALESCE(ev.swap_t1_net, 0)    AS swap_t1_net,
            COALESCE(ev.lp_count, 0)       AS lp_count,
            COALESCE(ev.lp_t0_in, 0)       AS lp_t0_in,
            COALESCE(ev.lp_t0_out, 0)      AS lp_t0_out,
            COALESCE(ev.lp_t0_net, 0)      AS lp_t0_net,
            COALESCE(ev.lp_t1_in, 0)       AS lp_t1_in,
            COALESCE(ev.lp_t1_out, 0)      AS lp_t1_out,
            COALESCE(ev.lp_t1_net, 0)      AS lp_t1_net,
            ev.vwap_buy_t0,
            ev.vwap_sell_t0,
            ev.avg_est_swap_impact_bps,
            ev.min_est_swap_impact_bps_t0_sell,
            ev.avg_est_swap_impact_bps_all,
            ev.max_est_swap_impact_bps_t1_sell,
            tk.current_tick,
            tk.current_tick_float,
            tk.sqrt_price_x64,
            tk.price_t1_per_t0,
            tk.impact_from_t0_sell1_avg,
            tk.impact_from_t0_sell2_avg,
            tk.impact_from_t0_sell3_avg,
            tk.sell_t0_for_impact1_avg,
            tk.sell_t0_for_impact2_avg,
            tk.sell_t0_for_impact3_avg,
            tk.impact_from_t1_sell1_avg,
            tk.impact_from_t1_sell2_avg,
            tk.impact_from_t1_sell3_avg,
            tk.sell_t1_for_impact1_avg,
            tk.sell_t1_for_impact2_avg,
            tk.sell_t1_for_impact3_avg,
            tk.concentration_peg_pct_1,
            tk.concentration_peg_pct_2,
            tk.concentration_peg_pct_3,
            tk.concentration_peg_halfspread_bps_array,
            tk.concentration_active_pct_1,
            tk.concentration_active_pct_2,
            tk.concentration_active_pct_3,
            tk.concentration_active_halfspread_bps_array,
            vt.t0_reserve,
            vt.t1_reserve,
            COALESCE(ps.tick_cross_count, 0) AS tick_cross_count,
            ps.current_liquidity_t1_units,
            ps.first_liquidity_t1_units
        FROM all_buckets ab
        LEFT JOIN pools p ON ab.pool_address = p.pool_address
        LEFT JOIN events_1m ev ON ev.bt = ab.bt AND ev.pool_address = ab.pool_address
        LEFT JOIN tick_1m tk ON tk.bt = ab.bt AND tk.pool_address = ab.pool_address
        LEFT JOIN vault_1m vt ON vt.bt = ab.bt AND vt.pool_address = ab.pool_address
        LEFT JOIN poolstate_1m ps ON ps.bt = ab.bt AND ps.pool_address = ab.pool_address
    ),
    -- Apply LOCF for state columns (tick, price, reserves, VWAP, concentration, impact)
    locf_groups AS (
        SELECT
            c.*,
            COUNT(c.price_t1_per_t0) OVER w_pool     AS grp_price,
            COUNT(c.t0_reserve) OVER w_pool           AS grp_reserve,
            COUNT(c.vwap_buy_t0) OVER w_pool          AS grp_vwap_buy,
            COUNT(c.vwap_sell_t0) OVER w_pool         AS grp_vwap_sell,
            COUNT(c.concentration_peg_pct_1) OVER w_pool AS grp_conc_peg,
            COUNT(c.concentration_active_pct_1) OVER w_pool AS grp_conc_active,
            COUNT(c.impact_from_t0_sell1_avg) OVER w_pool AS grp_impact,
            COUNT(c.impact_from_t1_sell1_avg) OVER w_pool AS grp_impact_t1
        FROM combined c
        WINDOW w_pool AS (PARTITION BY c.pool_address ORDER BY c.bt ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
    ),
    locf_applied AS (
        SELECT
            lg.bt,
            lg.pool_address,
            lg.protocol,
            lg.token_pair,
            lg.symbols_t0_t1,
            lg.swap_count, lg.swap_t0_in, lg.swap_t0_out, lg.swap_t0_net,
            lg.swap_t1_in, lg.swap_t1_out, lg.swap_t1_net,
            lg.lp_count, lg.lp_t0_in, lg.lp_t0_out, lg.lp_t0_net,
            lg.lp_t1_in, lg.lp_t1_out, lg.lp_t1_net,
            FIRST_VALUE(lg.vwap_buy_t0) OVER (PARTITION BY lg.pool_address, lg.grp_vwap_buy ORDER BY lg.bt) AS vwap_buy_t0,
            FIRST_VALUE(lg.vwap_sell_t0) OVER (PARTITION BY lg.pool_address, lg.grp_vwap_sell ORDER BY lg.bt) AS vwap_sell_t0,
            lg.avg_est_swap_impact_bps,
            lg.min_est_swap_impact_bps_t0_sell,
            lg.avg_est_swap_impact_bps_all,
            lg.max_est_swap_impact_bps_t1_sell,
            FIRST_VALUE(lg.current_tick) OVER (PARTITION BY lg.pool_address, lg.grp_price ORDER BY lg.bt) AS current_tick,
            FIRST_VALUE(lg.current_tick_float) OVER (PARTITION BY lg.pool_address, lg.grp_price ORDER BY lg.bt) AS current_tick_float,
            FIRST_VALUE(lg.sqrt_price_x64) OVER (PARTITION BY lg.pool_address, lg.grp_price ORDER BY lg.bt) AS sqrt_price_x64,
            FIRST_VALUE(lg.price_t1_per_t0) OVER (PARTITION BY lg.pool_address, lg.grp_price ORDER BY lg.bt) AS price_t1_per_t0,
            FIRST_VALUE(lg.impact_from_t0_sell1_avg) OVER (PARTITION BY lg.pool_address, lg.grp_impact ORDER BY lg.bt) AS impact_from_t0_sell1_avg,
            FIRST_VALUE(lg.impact_from_t0_sell2_avg) OVER (PARTITION BY lg.pool_address, lg.grp_impact ORDER BY lg.bt) AS impact_from_t0_sell2_avg,
            FIRST_VALUE(lg.impact_from_t0_sell3_avg) OVER (PARTITION BY lg.pool_address, lg.grp_impact ORDER BY lg.bt) AS impact_from_t0_sell3_avg,
            FIRST_VALUE(lg.sell_t0_for_impact1_avg) OVER (PARTITION BY lg.pool_address, lg.grp_impact ORDER BY lg.bt) AS sell_t0_for_impact1_avg,
            FIRST_VALUE(lg.sell_t0_for_impact2_avg) OVER (PARTITION BY lg.pool_address, lg.grp_impact ORDER BY lg.bt) AS sell_t0_for_impact2_avg,
            FIRST_VALUE(lg.sell_t0_for_impact3_avg) OVER (PARTITION BY lg.pool_address, lg.grp_impact ORDER BY lg.bt) AS sell_t0_for_impact3_avg,
            FIRST_VALUE(lg.impact_from_t1_sell1_avg) OVER (PARTITION BY lg.pool_address, lg.grp_impact_t1 ORDER BY lg.bt) AS impact_from_t1_sell1_avg,
            FIRST_VALUE(lg.impact_from_t1_sell2_avg) OVER (PARTITION BY lg.pool_address, lg.grp_impact_t1 ORDER BY lg.bt) AS impact_from_t1_sell2_avg,
            FIRST_VALUE(lg.impact_from_t1_sell3_avg) OVER (PARTITION BY lg.pool_address, lg.grp_impact_t1 ORDER BY lg.bt) AS impact_from_t1_sell3_avg,
            FIRST_VALUE(lg.sell_t1_for_impact1_avg) OVER (PARTITION BY lg.pool_address, lg.grp_impact_t1 ORDER BY lg.bt) AS sell_t1_for_impact1_avg,
            FIRST_VALUE(lg.sell_t1_for_impact2_avg) OVER (PARTITION BY lg.pool_address, lg.grp_impact_t1 ORDER BY lg.bt) AS sell_t1_for_impact2_avg,
            FIRST_VALUE(lg.sell_t1_for_impact3_avg) OVER (PARTITION BY lg.pool_address, lg.grp_impact_t1 ORDER BY lg.bt) AS sell_t1_for_impact3_avg,
            FIRST_VALUE(lg.concentration_peg_pct_1) OVER (PARTITION BY lg.pool_address, lg.grp_conc_peg ORDER BY lg.bt) AS concentration_peg_pct_1,
            FIRST_VALUE(lg.concentration_peg_pct_2) OVER (PARTITION BY lg.pool_address, lg.grp_conc_peg ORDER BY lg.bt) AS concentration_peg_pct_2,
            FIRST_VALUE(lg.concentration_peg_pct_3) OVER (PARTITION BY lg.pool_address, lg.grp_conc_peg ORDER BY lg.bt) AS concentration_peg_pct_3,
            FIRST_VALUE(lg.concentration_peg_halfspread_bps_array) OVER (PARTITION BY lg.pool_address, lg.grp_conc_peg ORDER BY lg.bt) AS concentration_peg_halfspread_bps_array,
            FIRST_VALUE(lg.concentration_active_pct_1) OVER (PARTITION BY lg.pool_address, lg.grp_conc_active ORDER BY lg.bt) AS concentration_active_pct_1,
            FIRST_VALUE(lg.concentration_active_pct_2) OVER (PARTITION BY lg.pool_address, lg.grp_conc_active ORDER BY lg.bt) AS concentration_active_pct_2,
            FIRST_VALUE(lg.concentration_active_pct_3) OVER (PARTITION BY lg.pool_address, lg.grp_conc_active ORDER BY lg.bt) AS concentration_active_pct_3,
            FIRST_VALUE(lg.concentration_active_halfspread_bps_array) OVER (PARTITION BY lg.pool_address, lg.grp_conc_active ORDER BY lg.bt) AS concentration_active_halfspread_bps_array,
            FIRST_VALUE(lg.t0_reserve) OVER (PARTITION BY lg.pool_address, lg.grp_reserve ORDER BY lg.bt) AS t0_reserve,
            FIRST_VALUE(lg.t1_reserve) OVER (PARTITION BY lg.pool_address, lg.grp_reserve ORDER BY lg.bt) AS t1_reserve,
            lg.tick_cross_count,
            lg.current_liquidity_t1_units,
            lg.first_liquidity_t1_units
        FROM locf_groups lg
    )
    SELECT
        la.bt,
        la.pool_address,
        la.protocol,
        la.token_pair,
        la.symbols_t0_t1,
        la.swap_count, la.swap_t0_in, la.swap_t0_out, la.swap_t0_net,
        la.swap_t1_in, la.swap_t1_out, la.swap_t1_net,
        la.lp_count, la.lp_t0_in, la.lp_t0_out, la.lp_t0_net,
        la.lp_t1_in, la.lp_t1_out, la.lp_t1_net,
        la.vwap_buy_t0, la.vwap_sell_t0,
        la.avg_est_swap_impact_bps, la.min_est_swap_impact_bps_t0_sell, la.avg_est_swap_impact_bps_all,
        la.max_est_swap_impact_bps_t1_sell,
        la.current_tick, la.current_tick_float, la.sqrt_price_x64, la.price_t1_per_t0,
        la.impact_from_t0_sell1_avg, la.impact_from_t0_sell2_avg, la.impact_from_t0_sell3_avg,
        la.sell_t0_for_impact1_avg, la.sell_t0_for_impact2_avg, la.sell_t0_for_impact3_avg,
        la.impact_from_t1_sell1_avg, la.impact_from_t1_sell2_avg, la.impact_from_t1_sell3_avg,
        la.sell_t1_for_impact1_avg, la.sell_t1_for_impact2_avg, la.sell_t1_for_impact3_avg,
        la.concentration_peg_pct_1, la.concentration_peg_pct_2, la.concentration_peg_pct_3,
        la.concentration_peg_halfspread_bps_array,
        la.concentration_active_pct_1, la.concentration_active_pct_2, la.concentration_active_pct_3,
        la.concentration_active_halfspread_bps_array,
        la.t0_reserve, la.t1_reserve,
        la.tick_cross_count,
        la.current_liquidity_t1_units,
        la.first_liquidity_t1_units,
        NOW() AS refreshed_at
    FROM locf_applied la
    WHERE la.bt >= v_refresh_from;
END;
$$;
