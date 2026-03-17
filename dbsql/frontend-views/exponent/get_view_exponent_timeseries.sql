-- get_view_exponent_timeseries: Re-bucketed read from mat_exp_timeseries_1m
-- Same signature and output schema as the original (exponent/dbsql/views/get_view_exponent_timeseries.sql)
-- Reads from pre-joined 1-minute materialized table instead of 5+ LATERAL joins at query time.

CREATE OR REPLACE FUNCTION exponent.get_view_exponent_timeseries(
    market_selection TEXT DEFAULT 'mkt2',
    bucket_interval TEXT DEFAULT '1 minute',
    from_ts TIMESTAMPTZ DEFAULT NOW() - INTERVAL '1 hour',
    to_ts TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
    bucket_time TIMESTAMPTZ,
    market_id TEXT,
    vault_address TEXT,
    market_address TEXT,
    mint_sy TEXT,
    mint_pt TEXT,
    mint_yt TEXT,
    start_ts INTEGER,
    start_datetime TIMESTAMPTZ,
    duration INTEGER,
    maturity_ts INTEGER,
    maturity_datetime TIMESTAMPTZ,
    total_sy_in_escrow NUMERIC,
    sy_for_pt NUMERIC,
    pt_supply NUMERIC,
    treasury_sy NUMERIC,
    uncollected_sy NUMERIC,
    sy_claims_sy_for_pt_pct NUMERIC,
    sy_claims_treasury_pct NUMERIC,
    sy_claims_uncollected_pct NUMERIC,
    sy_for_pt_pct_sy NUMERIC,
    sy_yield_pool_pct NUMERIC,
    sy_yield_utilization_pct NUMERIC,
    sy_cumulative_yield_pct NUMERIC,
    sy_collateral_buffer_pct NUMERIC,
    last_seen_sy_exchange_rate NUMERIC,
    all_time_high_sy_exchange_rate NUMERIC,
    final_sy_exchange_rate NUMERIC,
    interest_bps_fee SMALLINT,
    min_op_size_strip NUMERIC,
    min_op_size_merge NUMERIC,
    status SMALLINT,
    max_py_supply NUMERIC,
    c_vault_collateralization_ratio NUMERIC,
    c_vault_uncollected_yield_ratio NUMERIC,
    c_vault_treasury_ratio NUMERIC,
    c_vault_available_liquidity NUMERIC,
    c_vault_yield_index_health NUMERIC,
    pt_balance NUMERIC,
    sy_balance NUMERIC,
    ln_implied_rate NUMERIC,
    expiration_ts BIGINT,
    ln_fee_rate_root NUMERIC,
    rate_scalar_root NUMERIC,
    fee_treasury_sy_bps SMALLINT,
    lp_escrow_amount NUMERIC,
    max_lp_supply NUMERIC,
    status_flags SMALLINT,
    c_market_implied_apy NUMERIC,
    c_market_discount_rate NUMERIC,
    pt_base_price NUMERIC,
    pt_sy_price NUMERIC,
    pool_depth_in_sy NUMERIC,
    pool_depth_in_sy_delta NUMERIC,
    pt_balance_in_sy NUMERIC,
    pool_depth_sy_pct NUMERIC,
    pool_depth_pt_pct NUMERIC,
    pt_supply_ui_delta_pos NUMERIC,
    pt_supply_ui_delta_neg NUMERIC,
    yt_escrow_balance NUMERIC,
    yt_share_unstaked_pct NUMERIC,
    yt_share_staked_pct NUMERIC,
    sy_exchange_rate NUMERIC,
    sy_trailing_apy_1h NUMERIC,
    sy_trailing_apy_24h NUMERIC,
    sy_trailing_apy_7d NUMERIC,
    sy_trailing_apy_vault_life NUMERIC,
    sy_trailing_apy_all_time NUMERIC,
    yield_divergence_wrt_24h_rate_pct NUMERIC,
    yield_divergence_wrt_7d_rate_pct NUMERIC,
    apy_market_ath NUMERIC,
    apy_market_atl NUMERIC,
    amm_pt_swap_count INTEGER,
    amm_pt_in NUMERIC,
    amm_pt_out NUMERIC,
    amm_pt_volume NUMERIC,
    amm_pt_net_flow NUMERIC,
    lp_deposit_count INTEGER,
    lp_withdraw_count INTEGER,
    lp_pt_in NUMERIC,
    lp_pt_out NUMERIC,
    lp_sy_in NUMERIC,
    lp_sy_out NUMERIC,
    lp_tokens_minted NUMERIC,
    lp_tokens_burned NUMERIC,
    lp_net_pt_flow NUMERIC,
    lp_net_sy_flow NUMERIC,
    is_expired BOOLEAN,
    last_updated TIMESTAMPTZ,
    slot BIGINT
) AS $$
DECLARE
    v_interval INTERVAL;
    v_vault_address TEXT;
    v_market_id TEXT;
    v_rate_earliest NUMERIC;
    v_ts_earliest TIMESTAMPTZ;
    v_start_ts_vault INTEGER;
BEGIN
    BEGIN
        v_interval := bucket_interval::INTERVAL;
    EXCEPTION WHEN OTHERS THEN
        v_interval := INTERVAL '1 minute';
    END;

    -- Market selection: mkt1/mkt2 by maturity recency, or explicit meta_pt_name
    IF market_selection NOT IN ('mkt1', 'mkt2') THEN
        SELECT kr.vault_address INTO v_vault_address
        FROM exponent.aux_key_relations kr
        WHERE kr.meta_pt_name = market_selection
        LIMIT 1;
        v_market_id := market_selection;
    ELSIF market_selection = 'mkt2' THEN
        SELECT v.vault_address INTO v_vault_address
        FROM exponent.src_vaults v
        ORDER BY v.maturity_ts DESC, v.block_time DESC
        LIMIT 1;
        v_market_id := 'mkt2';
    ELSE
        SELECT v.vault_address INTO v_vault_address
        FROM exponent.src_vaults v
        ORDER BY v.maturity_ts DESC, v.block_time DESC
        LIMIT 1 OFFSET 1;
        v_market_id := 'mkt1';
    END IF;

    IF v_vault_address IS NULL THEN
        RETURN;
    END IF;

    -- Earliest exchange rate for vault-life / all-time APY baselines
    SELECT m.bucket_time, m.sy_exchange_rate
    INTO v_ts_earliest, v_rate_earliest
    FROM exponent.mat_exp_timeseries_1m m
    WHERE m.vault_address = v_vault_address
      AND m.sy_exchange_rate IS NOT NULL
    ORDER BY m.bucket_time ASC
    LIMIT 1;

    SELECT m.start_ts INTO v_start_ts_vault
    FROM exponent.mat_exp_timeseries_1m m
    WHERE m.vault_address = v_vault_address
      AND m.start_ts IS NOT NULL
    ORDER BY m.bucket_time DESC
    LIMIT 1;

    RETURN QUERY
    WITH
    rate_sparse AS (
        SELECT m.bucket_time AS rt, m.sy_exchange_rate AS rate
        FROM exponent.mat_exp_timeseries_1m m
        WHERE m.vault_address = v_vault_address
          AND m.sy_exchange_rate IS NOT NULL
          AND m.bucket_time <= to_ts
    ),
    rebucketed AS (
        SELECT
            time_bucket(v_interval, m.bucket_time) AS bt,
            -- State: LAST within rebucket
            LAST(m.market_address, m.bucket_time) AS market_address,
            LAST(m.mint_sy, m.bucket_time)     AS mint_sy,
            LAST(m.mint_pt, m.bucket_time)     AS mint_pt,
            LAST(m.mint_yt, m.bucket_time)     AS mint_yt,
            LAST(m.start_ts, m.bucket_time)    AS start_ts,
            LAST(m.duration, m.bucket_time)    AS duration,
            LAST(m.maturity_ts, m.bucket_time) AS maturity_ts,
            LAST(m.total_sy_in_escrow, m.bucket_time) AS total_sy_in_escrow,
            LAST(m.sy_for_pt, m.bucket_time)   AS sy_for_pt,
            LAST(m.pt_supply, m.bucket_time)   AS pt_supply,
            LAST(m.treasury_sy, m.bucket_time) AS treasury_sy,
            LAST(m.uncollected_sy, m.bucket_time) AS uncollected_sy,
            LAST(m.sy_for_pt_pct_sy, m.bucket_time) AS sy_for_pt_pct_sy,
            LAST(m.sy_yield_pool_pct, m.bucket_time) AS sy_yield_pool_pct,
            LAST(m.sy_yield_utilization_pct, m.bucket_time) AS sy_yield_utilization_pct,
            LAST(m.sy_cumulative_yield_pct, m.bucket_time) AS sy_cumulative_yield_pct,
            LAST(m.sy_collateral_buffer_pct, m.bucket_time) AS sy_collateral_buffer_pct,
            LAST(m.last_seen_sy_exchange_rate, m.bucket_time) AS last_seen_sy_exchange_rate,
            LAST(m.all_time_high_sy_exchange_rate, m.bucket_time) AS ath_sy_exchange_rate,
            LAST(m.final_sy_exchange_rate, m.bucket_time) AS final_sy_exchange_rate,
            LAST(m.interest_bps_fee, m.bucket_time) AS interest_bps_fee,
            LAST(m.min_op_size_strip, m.bucket_time) AS min_op_size_strip,
            LAST(m.min_op_size_merge, m.bucket_time) AS min_op_size_merge,
            LAST(m.status, m.bucket_time) AS status,
            LAST(m.max_py_supply, m.bucket_time) AS max_py_supply,
            LAST(m.c_vault_collateralization_ratio, m.bucket_time) AS c_vault_coll_ratio,
            LAST(m.c_vault_uncollected_yield_ratio, m.bucket_time) AS c_vault_uncoll_yield,
            LAST(m.c_vault_treasury_ratio, m.bucket_time) AS c_vault_treasury,
            LAST(m.c_vault_available_liquidity, m.bucket_time) AS c_vault_avail_liq,
            LAST(m.c_vault_yield_index_health, m.bucket_time) AS c_vault_yield_health,
            LAST(m.pt_balance, m.bucket_time) AS pt_balance,
            LAST(m.sy_balance, m.bucket_time) AS sy_balance,
            LAST(m.ln_implied_rate, m.bucket_time) AS ln_implied_rate,
            LAST(m.expiration_ts, m.bucket_time) AS expiration_ts,
            LAST(m.ln_fee_rate_root, m.bucket_time) AS ln_fee_rate_root,
            LAST(m.rate_scalar_root, m.bucket_time) AS rate_scalar_root,
            LAST(m.fee_treasury_sy_bps, m.bucket_time) AS fee_treasury_sy_bps,
            LAST(m.lp_escrow_amount, m.bucket_time) AS lp_escrow_amount,
            LAST(m.max_lp_supply, m.bucket_time) AS max_lp_supply,
            LAST(m.status_flags, m.bucket_time) AS status_flags,
            LAST(m.c_market_implied_apy, m.bucket_time) AS c_market_implied_apy,
            LAST(m.c_market_discount_rate, m.bucket_time) AS c_market_discount_rate,
            LAST(m.pt_base_price, m.bucket_time) AS pt_base_price,
            LAST(m.pool_depth_in_sy, m.bucket_time) AS pool_depth_in_sy,
            LAST(m.pt_balance_in_sy, m.bucket_time) AS pt_balance_in_sy,
            LAST(m.pool_depth_sy_pct, m.bucket_time) AS pool_depth_sy_pct,
            LAST(m.pool_depth_pt_pct, m.bucket_time) AS pool_depth_pt_pct,
            LAST(m.yt_escrow_balance, m.bucket_time) AS yt_escrow_balance,
            LAST(m.sy_exchange_rate, m.bucket_time) AS sy_exchange_rate,
            LAST(m.is_expired, m.bucket_time) AS is_expired,
            LAST(m.slot, m.bucket_time) AS slot,
            -- Events: SUM within rebucket
            SUM(m.amm_pt_swap_count)::INTEGER AS amm_pt_swap_count,
            SUM(m.amm_pt_in) AS amm_pt_in,
            SUM(m.amm_pt_out) AS amm_pt_out,
            SUM(m.amm_pt_volume) AS amm_pt_volume,
            SUM(m.amm_pt_net_flow) AS amm_pt_net_flow,
            SUM(m.lp_deposit_count)::INTEGER AS lp_deposit_count,
            SUM(m.lp_withdraw_count)::INTEGER AS lp_withdraw_count,
            SUM(m.lp_pt_in) AS lp_pt_in,
            SUM(m.lp_pt_out) AS lp_pt_out,
            SUM(m.lp_sy_in) AS lp_sy_in,
            SUM(m.lp_sy_out) AS lp_sy_out,
            SUM(m.lp_tokens_minted) AS lp_tokens_minted,
            SUM(m.lp_tokens_burned) AS lp_tokens_burned
        FROM exponent.mat_exp_timeseries_1m m
        WHERE m.vault_address = v_vault_address
          AND m.bucket_time >= from_ts
          AND m.bucket_time <= to_ts
        GROUP BY time_bucket(v_interval, m.bucket_time)
    ),
    with_deltas AS (
        SELECT
            r.*,
            -- Pool depth delta
            r.pool_depth_in_sy - LAG(r.pool_depth_in_sy) OVER (ORDER BY r.bt) AS pool_depth_delta,
            -- PT supply UI deltas
            GREATEST(r.pt_supply - LAG(r.pt_supply) OVER (ORDER BY r.bt), 0) AS pt_supply_delta_pos,
            LEAST(r.pt_supply - LAG(r.pt_supply) OVER (ORDER BY r.bt), 0) AS pt_supply_delta_neg,
            -- YT metrics: escrow = staked (deposit_yt puts YT into escrow for yield)
            -- Clamped to [0,100]; ratio can exceed 100% when PT redeemed but YT remains in escrow
            CASE WHEN r.pt_supply > 0
                 THEN GREATEST(0, LEAST(100, ROUND((r.pt_supply - r.yt_escrow_balance) / r.pt_supply * 100, 2))) END AS yt_unstaked_pct,
            CASE WHEN r.pt_supply > 0
                 THEN GREATEST(0, LEAST(100, ROUND(r.yt_escrow_balance / r.pt_supply * 100, 2))) END AS yt_staked_pct,
            -- SY claims composition (legacy)
            CASE WHEN r.total_sy_in_escrow > 0
                 THEN ROUND(r.sy_for_pt / r.total_sy_in_escrow * 100, 4) END AS sy_claims_pt_pct,
            CASE WHEN r.total_sy_in_escrow > 0
                 THEN ROUND(r.treasury_sy / r.total_sy_in_escrow * 100, 4) END AS sy_claims_treasury_pct,
            CASE WHEN r.total_sy_in_escrow > 0
                 THEN ROUND(r.uncollected_sy / r.total_sy_in_escrow * 100, 4) END AS sy_claims_uncollected_pct,
            -- APY extremes
            MAX(r.c_market_implied_apy) OVER () AS apy_ath,
            MIN(r.c_market_implied_apy) OVER () AS apy_atl
        FROM rebucketed r
    ),
    with_rates AS (
        SELECT
            d.*,
            COALESCE(d.sy_exchange_rate,
                (SELECT rate FROM rate_sparse WHERE rt <= d.bt ORDER BY rt DESC LIMIT 1)
            ) AS sy_rate_locf,
            (SELECT rate FROM rate_sparse
             WHERE rt <= date_trunc('day', d.bt - INTERVAL '2 hours') + INTERVAL '2 hours'
             ORDER BY rt DESC LIMIT 1) AS rate_day_snap,
            (SELECT rate FROM rate_sparse
             WHERE rt <= d.bt - INTERVAL '1 hour' ORDER BY rt DESC LIMIT 1) AS rate_1h_ago,
            (SELECT rate FROM rate_sparse
             WHERE rt <= d.bt - INTERVAL '24 hours' ORDER BY rt DESC LIMIT 1) AS rate_24h_ago,
            (SELECT rate FROM rate_sparse
             WHERE rt <= d.bt - INTERVAL '7 days' ORDER BY rt DESC LIMIT 1) AS rate_7d_ago,
            (SELECT rate FROM rate_sparse
             WHERE rt <= date_trunc('day', d.bt - INTERVAL '24 hours' - INTERVAL '2 hours') + INTERVAL '2 hours'
             ORDER BY rt DESC LIMIT 1) AS rate_day_snap_24h_ago,
            (SELECT rate FROM rate_sparse
             WHERE rt <= date_trunc('day', d.bt - INTERVAL '7 days' - INTERVAL '2 hours') + INTERVAL '2 hours'
             ORDER BY rt DESC LIMIT 1) AS rate_day_snap_7d_ago
        FROM with_deltas d
    )
    SELECT
        d.bt,
        v_market_id,
        v_vault_address,
        d.market_address,
        d.mint_sy, d.mint_pt, d.mint_yt,
        d.start_ts,
        CASE WHEN d.start_ts IS NOT NULL THEN to_timestamp(d.start_ts) ELSE NULL END,
        d.duration,
        d.maturity_ts,
        CASE WHEN d.maturity_ts IS NOT NULL THEN to_timestamp(d.maturity_ts) ELSE NULL END,
        ROUND(d.total_sy_in_escrow, 4),
        ROUND(d.sy_for_pt, 4),
        ROUND(d.pt_supply, 4),
        ROUND(d.treasury_sy, 6),
        ROUND(d.uncollected_sy, 6),
        d.sy_claims_pt_pct,
        d.sy_claims_treasury_pct,
        d.sy_claims_uncollected_pct,
        d.sy_for_pt_pct_sy,
        d.sy_yield_pool_pct,
        d.sy_yield_utilization_pct,
        d.sy_cumulative_yield_pct,
        d.sy_collateral_buffer_pct,
        ROUND(d.last_seen_sy_exchange_rate, 10),
        ROUND(d.ath_sy_exchange_rate, 10),
        ROUND(d.final_sy_exchange_rate, 10),
        d.interest_bps_fee,
        d.min_op_size_strip,
        d.min_op_size_merge,
        d.status,
        d.max_py_supply,
        ROUND(d.c_vault_coll_ratio, 6),
        ROUND(d.c_vault_uncoll_yield, 6),
        ROUND(d.c_vault_treasury, 6),
        ROUND(d.c_vault_avail_liq, 4),
        ROUND(d.c_vault_yield_health, 8),
        ROUND(d.pt_balance, 4),
        ROUND(d.sy_balance, 4),
        d.ln_implied_rate,
        d.expiration_ts,
        d.ln_fee_rate_root,
        d.rate_scalar_root,
        d.fee_treasury_sy_bps,
        ROUND(d.lp_escrow_amount, 4),
        ROUND(d.max_lp_supply, 4),
        d.status_flags,
        ROUND(d.c_market_implied_apy * 100, 2),
        ROUND(d.c_market_discount_rate * 100, 4),
        ROUND(d.pt_base_price, 6),
        ROUND(d.pt_base_price, 6),  -- pt_sy_price (deprecated, same as pt_base_price)
        ROUND(d.pool_depth_in_sy, 4),
        ROUND(d.pool_depth_delta, 4),
        ROUND(d.pt_balance_in_sy, 4),
        d.pool_depth_sy_pct,
        d.pool_depth_pt_pct,
        ROUND(d.pt_supply_delta_pos, 4),
        ROUND(d.pt_supply_delta_neg, 4),
        ROUND(d.yt_escrow_balance, 4),
        d.yt_unstaked_pct,
        d.yt_staked_pct,
        ROUND(d.sy_exchange_rate, 10),
        -- Trailing APYs: annualised simple yield from exchange-rate lookback
        CASE WHEN d.sy_rate_locf IS NOT NULL AND d.rate_1h_ago IS NOT NULL AND d.rate_1h_ago > 0
             THEN ROUND(((d.sy_rate_locf / d.rate_1h_ago - 1.0) * 8766.0) * 100, 2) END,
        CASE WHEN d.rate_day_snap IS NOT NULL AND d.rate_day_snap_24h_ago IS NOT NULL AND d.rate_day_snap_24h_ago > 0
             THEN ROUND(((d.rate_day_snap / d.rate_day_snap_24h_ago - 1.0) * 365.25) * 100, 2) END,
        CASE WHEN d.rate_day_snap IS NOT NULL AND d.rate_day_snap_7d_ago IS NOT NULL AND d.rate_day_snap_7d_ago > 0
             THEN ROUND(((d.rate_day_snap / d.rate_day_snap_7d_ago - 1.0) * 365.25 / 7.0) * 100, 2) END,
        CASE WHEN d.rate_day_snap IS NOT NULL AND v_rate_earliest IS NOT NULL AND v_rate_earliest > 0
                  AND v_start_ts_vault IS NOT NULL
                  AND EXTRACT(EPOCH FROM d.bt - GREATEST(to_timestamp(v_start_ts_vault), v_ts_earliest)) > 86400
             THEN ROUND(((d.rate_day_snap / v_rate_earliest - 1.0) * 365.25
                   / GREATEST(FLOOR((EXTRACT(EPOCH FROM d.bt - GREATEST(to_timestamp(v_start_ts_vault), v_ts_earliest)) - 7200) / 86400.0), 1)) * 100, 2) END,
        CASE WHEN d.rate_day_snap IS NOT NULL AND v_rate_earliest IS NOT NULL AND v_rate_earliest > 0
                  AND v_ts_earliest IS NOT NULL
                  AND EXTRACT(EPOCH FROM d.bt - v_ts_earliest) > 86400
             THEN ROUND(((d.rate_day_snap / v_rate_earliest - 1.0) * 365.25
                   / GREATEST(FLOOR((EXTRACT(EPOCH FROM d.bt - v_ts_earliest) - 7200) / 86400.0), 1)) * 100, 2) END,
        -- Yield divergence: fixed rate minus trailing variable rate
        CASE WHEN d.c_market_implied_apy IS NOT NULL AND d.rate_day_snap IS NOT NULL
                  AND d.rate_day_snap_24h_ago IS NOT NULL AND d.rate_day_snap_24h_ago > 0
             THEN ROUND(d.c_market_implied_apy * 100
                  - ((d.rate_day_snap / d.rate_day_snap_24h_ago - 1.0) * 365.25) * 100, 2) END,
        CASE WHEN d.c_market_implied_apy IS NOT NULL AND d.rate_day_snap IS NOT NULL
                  AND d.rate_day_snap_7d_ago IS NOT NULL AND d.rate_day_snap_7d_ago > 0
             THEN ROUND(d.c_market_implied_apy * 100
                  - ((d.rate_day_snap / d.rate_day_snap_7d_ago - 1.0) * 365.25 / 7.0) * 100, 2) END,
        ROUND(d.apy_ath * 100, 2),
        ROUND(d.apy_atl * 100, 2),
        d.amm_pt_swap_count,
        ROUND(d.amm_pt_in, 4),
        ROUND(d.amm_pt_out, 4),
        ROUND(d.amm_pt_volume, 4),
        ROUND(d.amm_pt_net_flow, 4),
        d.lp_deposit_count,
        d.lp_withdraw_count,
        ROUND(d.lp_pt_in, 4),
        ROUND(d.lp_pt_out, 4),
        ROUND(d.lp_sy_in, 4),
        ROUND(d.lp_sy_out, 4),
        ROUND(d.lp_tokens_minted, 4),
        ROUND(d.lp_tokens_burned, 4),
        ROUND(d.lp_pt_in - d.lp_pt_out, 4),
        ROUND(d.lp_sy_in - d.lp_sy_out, 4),
        d.is_expired,
        d.bt,
        d.slot
    FROM with_rates d
    ORDER BY d.bt;
END;
$$ LANGUAGE plpgsql STABLE;
