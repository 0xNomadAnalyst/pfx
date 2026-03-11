-- mat_xp_ts_1m: Cross-protocol ONyc ecosystem timeseries at 1-minute grain
-- Pre-computes TVL distribution, activity flows, and yield metrics across
-- DEXes, Kamino, and Exponent so that the cross-protocol frontend views
-- become simple re-bucketing / aggregation queries.
--
-- Reads from domain-specific mat tables (which are already at 1-min grain
-- with LOCF and decimal-adjusted values) plus the base_token_escrow CAGG
-- for Exponent TVL.

CREATE SCHEMA IF NOT EXISTS cross_protocol;

CREATE TABLE IF NOT EXISTS cross_protocol.mat_xp_ts_1m (
    bucket_time                 TIMESTAMPTZ NOT NULL PRIMARY KEY,

    -- ONyc TVL by protocol (decimal-adjusted)
    onyc_in_dexes               NUMERIC     DEFAULT 0,
    onyc_in_kamino              NUMERIC     DEFAULT 0,
    onyc_in_exponent            NUMERIC     DEFAULT 0,
    onyc_tracked_total          NUMERIC     DEFAULT 0,

    -- TVL percentages
    onyc_in_dexes_pct           NUMERIC     DEFAULT 0,
    onyc_in_kamino_pct          NUMERIC     DEFAULT 0,
    onyc_in_exponent_pct        NUMERIC     DEFAULT 0,

    -- DEX activity (ONyc-side volumes, decimal-adjusted)
    dex_swap_volume             NUMERIC     DEFAULT 0,
    dex_lp_volume               NUMERIC     DEFAULT 0,
    dex_total_volume            NUMERIC     DEFAULT 0,

    -- Kamino activity (decimal-adjusted, all reserve symbols for ONyc)
    kam_deposit_volume          NUMERIC     DEFAULT 0,
    kam_withdraw_volume         NUMERIC     DEFAULT 0,
    kam_borrow_volume           NUMERIC     DEFAULT 0,
    kam_repay_volume            NUMERIC     DEFAULT 0,
    kam_liquidate_volume        NUMERIC     DEFAULT 0,
    kam_total_volume            NUMERIC     DEFAULT 0,

    -- Exponent activity (from mat_exp_timeseries_1m, aggregated across vaults)
    exp_pt_trade_volume         NUMERIC     DEFAULT 0,
    exp_lp_volume               NUMERIC     DEFAULT 0,
    exp_total_volume            NUMERIC     DEFAULT 0,

    -- Cross-protocol totals
    all_protocol_volume         NUMERIC     DEFAULT 0,
    dex_volume_pct              NUMERIC     DEFAULT 0,
    kam_volume_pct              NUMERIC     DEFAULT 0,
    exp_volume_pct              NUMERIC     DEFAULT 0,

    -- Yields
    kam_onyc_supply_apy         NUMERIC,
    exp_weighted_implied_apy    NUMERIC,

    refreshed_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

SELECT create_hypertable(
    'cross_protocol.mat_xp_ts_1m', 'bucket_time',
    if_not_exists => TRUE
);

-- ---------------------------------------------------------------------------
-- Refresh procedure: incremental upsert of last 30 minutes
-- Joins domain mat tables (dependency: must run AFTER domain mat refreshes)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE cross_protocol.refresh_mat_xp_ts_1m(
    p_lookback INTERVAL DEFAULT INTERVAL '30 minutes'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_refresh_from TIMESTAMPTZ := NOW() - p_lookback;
    v_onyc_mint    TEXT := '5Y8NV33Vv7WbnLfq3zBcKSdYPrk7g2KoiQoe7M2tcxp5';
BEGIN
    DELETE FROM cross_protocol.mat_xp_ts_1m
    WHERE bucket_time >= v_refresh_from;

    INSERT INTO cross_protocol.mat_xp_ts_1m (
        bucket_time,
        onyc_in_dexes, onyc_in_kamino, onyc_in_exponent, onyc_tracked_total,
        onyc_in_dexes_pct, onyc_in_kamino_pct, onyc_in_exponent_pct,
        dex_swap_volume, dex_lp_volume, dex_total_volume,
        kam_deposit_volume, kam_withdraw_volume, kam_borrow_volume,
        kam_repay_volume, kam_liquidate_volume, kam_total_volume,
        exp_pt_trade_volume, exp_lp_volume, exp_total_volume,
        all_protocol_volume, dex_volume_pct, kam_volume_pct, exp_volume_pct,
        kam_onyc_supply_apy, exp_weighted_implied_apy,
        refreshed_at
    )
    WITH
    -- ── DEX: ONyc reserves + activity per 1-min bucket ──
    dex_agg AS (
        SELECT
            d.bucket_time,
            SUM(
                CASE
                    WHEN ptr.token0_address = v_onyc_mint THEN COALESCE(d.t0_reserve, 0)
                    WHEN ptr.token1_address = v_onyc_mint THEN COALESCE(d.t1_reserve, 0)
                    ELSE 0
                END
            ) AS onyc_in_dexes,
            SUM(
                CASE
                    WHEN ptr.token0_address = v_onyc_mint
                        THEN ABS(COALESCE(d.swap_t0_in, 0)) + ABS(COALESCE(d.swap_t0_out, 0))
                    WHEN ptr.token1_address = v_onyc_mint
                        THEN ABS(COALESCE(d.swap_t1_in, 0)) + ABS(COALESCE(d.swap_t1_out, 0))
                    ELSE 0
                END
            ) AS swap_vol,
            SUM(
                CASE
                    WHEN ptr.token0_address = v_onyc_mint
                        THEN ABS(COALESCE(d.lp_t0_in, 0)) + ABS(COALESCE(d.lp_t0_out, 0))
                    WHEN ptr.token1_address = v_onyc_mint
                        THEN ABS(COALESCE(d.lp_t1_in, 0)) + ABS(COALESCE(d.lp_t1_out, 0))
                    ELSE 0
                END
            ) AS lp_vol
        FROM dexes.mat_dex_timeseries_1m d
        JOIN dexes.pool_tokens_reference ptr ON d.pool_address = ptr.pool_address
        WHERE d.bucket_time >= v_refresh_from
          AND (ptr.token0_address = v_onyc_mint OR ptr.token1_address = v_onyc_mint)
        GROUP BY d.bucket_time
    ),

    -- ── KAMINO: ONyc reserve TVL + yield per 1-min bucket ──
    kamino_tvl AS (
        SELECT
            r.bucket_time,
            SUM(COALESCE(r.collateral_total_supply, 0)) AS onyc_in_kamino,
            MAX(r.supply_apy) AS kam_supply_apy
        FROM kamino_lend.mat_klend_reserve_ts_1m r
        JOIN kamino_lend.aux_market_reserve_tokens art
            ON r.reserve_address = art.reserve_address
        WHERE art.token_mint = v_onyc_mint
          AND r.bucket_time >= v_refresh_from
        GROUP BY r.bucket_time
    ),

    -- ── KAMINO: ONyc activity per 1-min bucket ──
    -- Join via aux to identify ONyc reserves by mint, then sum activity
    kamino_act AS (
        SELECT
            a.bucket_time,
            SUM(COALESCE(a.deposit_vault_sum, 0))     AS deposit_vol,
            SUM(COALESCE(a.withdraw_vault_sum, 0))     AS withdraw_vol,
            SUM(COALESCE(a.borrowing_sum, 0))          AS borrow_vol,
            SUM(COALESCE(a.repay_borrowing_sum, 0))    AS repay_vol,
            SUM(COALESCE(a.liquidate_borrowing_sum, 0)) AS liquidate_vol
        FROM kamino_lend.mat_klend_activity_ts_1m a
        JOIN kamino_lend.aux_market_reserve_tokens art
            ON a.reserve_address = art.reserve_address
        WHERE art.token_mint = v_onyc_mint
          AND a.bucket_time >= v_refresh_from
        GROUP BY a.bucket_time
    ),

    -- ── EXPONENT: ONyc TVL via base_token_escrow CAGG (5s → 1min) ──
    exp_tvl AS (
        SELECT
            time_bucket('1 minute', e.bucket) AS bucket_time,
            SUM(COALESCE(e.c_balance_readable_last, 0)) AS onyc_in_exponent
        FROM exponent.cagg_base_token_escrow_5s e
        WHERE e.mint = v_onyc_mint
          AND e.bucket >= v_refresh_from
        GROUP BY time_bucket('1 minute', e.bucket)
    ),

    -- ── EXPONENT: activity + yield per 1-min bucket (across all vaults) ──
    exp_act AS (
        SELECT
            m.bucket_time,
            SUM(COALESCE(m.amm_pt_volume, 0)) AS pt_trade_vol,
            SUM(
                COALESCE(m.lp_pt_in, 0) + COALESCE(m.lp_pt_out, 0)
                + COALESCE(m.lp_sy_in, 0) + COALESCE(m.lp_sy_out, 0)
            ) AS lp_vol,
            -- Depth-weighted average implied APY (only active, non-expired markets)
            CASE
                WHEN SUM(COALESCE(m.pool_depth_in_sy, 0))
                        FILTER (WHERE NOT COALESCE(m.is_expired, FALSE)
                                  AND m.c_market_implied_apy IS NOT NULL) > 0
                THEN SUM(m.c_market_implied_apy * COALESCE(m.pool_depth_in_sy, 0))
                        FILTER (WHERE NOT COALESCE(m.is_expired, FALSE)
                                  AND m.c_market_implied_apy IS NOT NULL)
                     / SUM(COALESCE(m.pool_depth_in_sy, 0))
                        FILTER (WHERE NOT COALESCE(m.is_expired, FALSE)
                                  AND m.c_market_implied_apy IS NOT NULL)
                ELSE NULL
            END AS weighted_implied_apy
        FROM exponent.mat_exp_timeseries_1m m
        WHERE m.bucket_time >= v_refresh_from
        GROUP BY m.bucket_time
    ),

    -- ── Generate a continuous 1-minute series as the spine ──
    spine AS (
        SELECT generate_series(
            time_bucket('1 minute', v_refresh_from),
            time_bucket('1 minute', NOW()),
            '1 minute'::INTERVAL
        ) AS bucket_time
    ),

    -- ── Combine all domains ──
    combined AS (
        SELECT
            s.bucket_time,
            COALESCE(dx.onyc_in_dexes, 0)    AS onyc_in_dexes,
            COALESCE(kt.onyc_in_kamino, 0)    AS onyc_in_kamino,
            COALESCE(et.onyc_in_exponent, 0)  AS onyc_in_exponent,
            COALESCE(dx.swap_vol, 0)          AS dex_swap_volume,
            COALESCE(dx.lp_vol, 0)            AS dex_lp_volume,
            COALESCE(ka.deposit_vol, 0)       AS kam_deposit_volume,
            COALESCE(ka.withdraw_vol, 0)      AS kam_withdraw_volume,
            COALESCE(ka.borrow_vol, 0)        AS kam_borrow_volume,
            COALESCE(ka.repay_vol, 0)         AS kam_repay_volume,
            COALESCE(ka.liquidate_vol, 0)     AS kam_liquidate_volume,
            COALESCE(ea.pt_trade_vol, 0)      AS exp_pt_trade_volume,
            COALESCE(ea.lp_vol, 0)            AS exp_lp_volume,
            kt.kam_supply_apy,
            ea.weighted_implied_apy
        FROM spine s
        LEFT JOIN dex_agg     dx ON s.bucket_time = dx.bucket_time
        LEFT JOIN kamino_tvl  kt ON s.bucket_time = kt.bucket_time
        LEFT JOIN kamino_act  ka ON s.bucket_time = ka.bucket_time
        LEFT JOIN exp_tvl     et ON s.bucket_time = et.bucket_time
        LEFT JOIN exp_act     ea ON s.bucket_time = ea.bucket_time
    )
    SELECT
        c.bucket_time,
        -- TVL
        c.onyc_in_dexes,
        c.onyc_in_kamino,
        c.onyc_in_exponent,
        c.onyc_in_dexes + c.onyc_in_kamino + c.onyc_in_exponent AS onyc_tracked_total,
        -- TVL percentages
        ROUND(COALESCE(
            c.onyc_in_dexes / NULLIF(c.onyc_in_dexes + c.onyc_in_kamino + c.onyc_in_exponent, 0) * 100,
            0)::NUMERIC, 1),
        ROUND(COALESCE(
            c.onyc_in_kamino / NULLIF(c.onyc_in_dexes + c.onyc_in_kamino + c.onyc_in_exponent, 0) * 100,
            0)::NUMERIC, 1),
        ROUND(COALESCE(
            c.onyc_in_exponent / NULLIF(c.onyc_in_dexes + c.onyc_in_kamino + c.onyc_in_exponent, 0) * 100,
            0)::NUMERIC, 1),
        -- DEX activity
        c.dex_swap_volume,
        c.dex_lp_volume,
        c.dex_swap_volume + c.dex_lp_volume AS dex_total_volume,
        -- Kamino activity
        c.kam_deposit_volume,
        c.kam_withdraw_volume,
        c.kam_borrow_volume,
        c.kam_repay_volume,
        c.kam_liquidate_volume,
        c.kam_deposit_volume + c.kam_withdraw_volume + c.kam_borrow_volume
            + c.kam_repay_volume + c.kam_liquidate_volume AS kam_total_volume,
        -- Exponent activity
        c.exp_pt_trade_volume,
        c.exp_lp_volume,
        c.exp_pt_trade_volume + c.exp_lp_volume AS exp_total_volume,
        -- Cross-protocol totals
        (c.dex_swap_volume + c.dex_lp_volume)
        + (c.kam_deposit_volume + c.kam_withdraw_volume + c.kam_borrow_volume
            + c.kam_repay_volume + c.kam_liquidate_volume)
        + (c.exp_pt_trade_volume + c.exp_lp_volume) AS all_protocol_volume,
        -- Activity percentages
        ROUND(COALESCE(
            (c.dex_swap_volume + c.dex_lp_volume)
            / NULLIF(
                (c.dex_swap_volume + c.dex_lp_volume)
                + (c.kam_deposit_volume + c.kam_withdraw_volume + c.kam_borrow_volume
                    + c.kam_repay_volume + c.kam_liquidate_volume)
                + (c.exp_pt_trade_volume + c.exp_lp_volume), 0) * 100,
            0)::NUMERIC, 1),
        ROUND(COALESCE(
            (c.kam_deposit_volume + c.kam_withdraw_volume + c.kam_borrow_volume
                + c.kam_repay_volume + c.kam_liquidate_volume)
            / NULLIF(
                (c.dex_swap_volume + c.dex_lp_volume)
                + (c.kam_deposit_volume + c.kam_withdraw_volume + c.kam_borrow_volume
                    + c.kam_repay_volume + c.kam_liquidate_volume)
                + (c.exp_pt_trade_volume + c.exp_lp_volume), 0) * 100,
            0)::NUMERIC, 1),
        ROUND(COALESCE(
            (c.exp_pt_trade_volume + c.exp_lp_volume)
            / NULLIF(
                (c.dex_swap_volume + c.dex_lp_volume)
                + (c.kam_deposit_volume + c.kam_withdraw_volume + c.kam_borrow_volume
                    + c.kam_repay_volume + c.kam_liquidate_volume)
                + (c.exp_pt_trade_volume + c.exp_lp_volume), 0) * 100,
            0)::NUMERIC, 1),
        -- Yields
        c.kam_supply_apy,
        c.weighted_implied_apy,
        NOW()
    FROM combined c
    ON CONFLICT (bucket_time) DO UPDATE SET
        onyc_in_dexes      = EXCLUDED.onyc_in_dexes,
        onyc_in_kamino     = EXCLUDED.onyc_in_kamino,
        onyc_in_exponent   = EXCLUDED.onyc_in_exponent,
        onyc_tracked_total = EXCLUDED.onyc_tracked_total,
        onyc_in_dexes_pct  = EXCLUDED.onyc_in_dexes_pct,
        onyc_in_kamino_pct = EXCLUDED.onyc_in_kamino_pct,
        onyc_in_exponent_pct = EXCLUDED.onyc_in_exponent_pct,
        dex_swap_volume    = EXCLUDED.dex_swap_volume,
        dex_lp_volume      = EXCLUDED.dex_lp_volume,
        dex_total_volume   = EXCLUDED.dex_total_volume,
        kam_deposit_volume = EXCLUDED.kam_deposit_volume,
        kam_withdraw_volume = EXCLUDED.kam_withdraw_volume,
        kam_borrow_volume  = EXCLUDED.kam_borrow_volume,
        kam_repay_volume   = EXCLUDED.kam_repay_volume,
        kam_liquidate_volume = EXCLUDED.kam_liquidate_volume,
        kam_total_volume   = EXCLUDED.kam_total_volume,
        exp_pt_trade_volume = EXCLUDED.exp_pt_trade_volume,
        exp_lp_volume      = EXCLUDED.exp_lp_volume,
        exp_total_volume   = EXCLUDED.exp_total_volume,
        all_protocol_volume = EXCLUDED.all_protocol_volume,
        dex_volume_pct     = EXCLUDED.dex_volume_pct,
        kam_volume_pct     = EXCLUDED.kam_volume_pct,
        exp_volume_pct     = EXCLUDED.exp_volume_pct,
        kam_onyc_supply_apy = EXCLUDED.kam_onyc_supply_apy,
        exp_weighted_implied_apy = EXCLUDED.exp_weighted_implied_apy,
        refreshed_at       = EXCLUDED.refreshed_at;
END;
$$;
