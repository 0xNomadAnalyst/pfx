-- mat_exp_timeseries_1m: Pre-joined vault + market + yt + sy + tx data at 1-minute grain
-- Eliminates the 5+ LATERAL joins in get_view_exponent_timeseries (biggest query-time win)
-- One row per (vault_address, bucket_time) with all metrics LOCF-applied.

CREATE TABLE IF NOT EXISTS exponent.mat_exp_timeseries_1m (
    bucket_time                 TIMESTAMPTZ NOT NULL,
    vault_address               TEXT        NOT NULL,

    -- Vault identification (from aux_key_relations)
    market_address              TEXT,
    mint_sy                     TEXT,
    mint_pt                     TEXT,
    mint_yt                     TEXT,

    -- Vault metrics: Maturity schedule
    start_ts                    INTEGER,
    duration                    INTEGER,
    maturity_ts                 INTEGER,

    -- Vault metrics: Collateral and supply (LAST, LOCF)
    total_sy_in_escrow          NUMERIC,
    sy_for_pt                   NUMERIC,
    pt_supply                   NUMERIC,
    treasury_sy                 NUMERIC,
    uncollected_sy              NUMERIC,

    -- Vault yield composition (calculated)
    sy_for_pt_pct_sy            NUMERIC,
    sy_yield_pool_pct           NUMERIC,
    sy_yield_utilization_pct    NUMERIC,
    sy_cumulative_yield_pct     NUMERIC,
    sy_collateral_buffer_pct    NUMERIC,

    -- Vault metrics: Exchange rates
    last_seen_sy_exchange_rate  NUMERIC,
    all_time_high_sy_exchange_rate NUMERIC,
    final_sy_exchange_rate      NUMERIC,

    -- Vault metrics: Fees
    interest_bps_fee            SMALLINT,
    min_op_size_strip           NUMERIC,
    min_op_size_merge           NUMERIC,
    status                      SMALLINT,
    max_py_supply               NUMERIC,

    -- Vault calculated metrics
    c_vault_collateralization_ratio  NUMERIC,
    c_vault_uncollected_yield_ratio  NUMERIC,
    c_vault_treasury_ratio           NUMERIC,
    c_vault_available_liquidity      NUMERIC,
    c_vault_yield_index_health       NUMERIC,

    -- Market metrics: Reserves (LAST, LOCF)
    pt_balance                  NUMERIC,
    sy_balance                  NUMERIC,

    -- Market metrics: Pricing
    ln_implied_rate             NUMERIC,
    expiration_ts               BIGINT,

    -- Market metrics: AMM parameters
    ln_fee_rate_root            NUMERIC,
    rate_scalar_root            NUMERIC,
    fee_treasury_sy_bps         SMALLINT,

    -- Market metrics: LP tracking
    lp_escrow_amount            NUMERIC,
    max_lp_supply               NUMERIC,
    status_flags                SMALLINT,

    -- Market calculated metrics
    c_market_implied_apy        NUMERIC,
    c_market_discount_rate      NUMERIC,
    pt_base_price               NUMERIC,

    -- Pool depth in SY units
    pool_depth_in_sy            NUMERIC,
    pt_balance_in_sy            NUMERIC,
    pool_depth_sy_pct           NUMERIC,
    pool_depth_pt_pct           NUMERIC,

    -- YT escrow
    yt_escrow_balance           NUMERIC,

    -- SY exchange rate (LIVE from SY program, LOCF)
    sy_exchange_rate            NUMERIC,

    -- AMM PT Trading Flows (SUM within 1m)
    amm_pt_swap_count           INTEGER     DEFAULT 0,
    amm_pt_in                   NUMERIC     DEFAULT 0,
    amm_pt_out                  NUMERIC     DEFAULT 0,
    amm_pt_volume               NUMERIC     DEFAULT 0,
    amm_pt_net_flow             NUMERIC     DEFAULT 0,

    -- LP Liquidity Flows (SUM within 1m)
    lp_deposit_count            INTEGER     DEFAULT 0,
    lp_withdraw_count           INTEGER     DEFAULT 0,
    lp_pt_in                    NUMERIC     DEFAULT 0,
    lp_pt_out                   NUMERIC     DEFAULT 0,
    lp_sy_in                    NUMERIC     DEFAULT 0,
    lp_sy_out                   NUMERIC     DEFAULT 0,
    lp_tokens_minted            NUMERIC     DEFAULT 0,
    lp_tokens_burned            NUMERIC     DEFAULT 0,

    -- Expiry flag
    is_expired                  BOOLEAN     DEFAULT FALSE,

    -- Metadata
    slot                        BIGINT,
    refreshed_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (vault_address, bucket_time)
);

SELECT create_hypertable(
    'exponent.mat_exp_timeseries_1m', 'bucket_time',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_mat_exp_ts_1m_vault
    ON exponent.mat_exp_timeseries_1m (vault_address, bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_mat_exp_ts_1m_market
    ON exponent.mat_exp_timeseries_1m (market_address, bucket_time DESC);

-- ---------------------------------------------------------------------------
-- Refresh procedure: incremental upsert of last 30 minutes
-- Joins vault, market, yt_escrow, sy_meta, and tx_events CAGGs with LOCF.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE exponent.refresh_mat_exp_timeseries_1m(
    p_lookback INTERVAL DEFAULT INTERVAL '30 minutes'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_refresh_from TIMESTAMPTZ := NOW() - p_lookback;
    v_seed_from    TIMESTAMPTZ := NOW() - p_lookback - INTERVAL '5 minutes';
    v_vault        RECORD;
BEGIN
    DELETE FROM exponent.mat_exp_timeseries_1m
    WHERE bucket_time >= v_refresh_from;

    -- Process each active vault
    FOR v_vault IN
        SELECT DISTINCT
            kr.vault_address,
            kr.market_address,
            kr.mint_sy,
            kr.mint_pt,
            kr.mint_yt,
            COALESCE(kr.env_sy_decimals, kr.meta_sy_decimals, 6) AS decimals
        FROM exponent.aux_key_relations kr
        WHERE kr.vault_address IS NOT NULL
          AND kr.market_address IS NOT NULL
    LOOP
        INSERT INTO exponent.mat_exp_timeseries_1m (
            bucket_time, vault_address, market_address, mint_sy, mint_pt, mint_yt,
            start_ts, duration, maturity_ts,
            total_sy_in_escrow, sy_for_pt, pt_supply, treasury_sy, uncollected_sy,
            sy_for_pt_pct_sy, sy_yield_pool_pct, sy_yield_utilization_pct,
            sy_cumulative_yield_pct, sy_collateral_buffer_pct,
            last_seen_sy_exchange_rate, all_time_high_sy_exchange_rate, final_sy_exchange_rate,
            interest_bps_fee, min_op_size_strip, min_op_size_merge, status, max_py_supply,
            c_vault_collateralization_ratio, c_vault_uncollected_yield_ratio,
            c_vault_treasury_ratio, c_vault_available_liquidity, c_vault_yield_index_health,
            pt_balance, sy_balance,
            ln_implied_rate, expiration_ts,
            ln_fee_rate_root, rate_scalar_root, fee_treasury_sy_bps,
            lp_escrow_amount, max_lp_supply, status_flags,
            c_market_implied_apy, c_market_discount_rate, pt_base_price,
            pool_depth_in_sy, pt_balance_in_sy, pool_depth_sy_pct, pool_depth_pt_pct,
            yt_escrow_balance,
            sy_exchange_rate,
            amm_pt_swap_count, amm_pt_in, amm_pt_out, amm_pt_volume, amm_pt_net_flow,
            lp_deposit_count, lp_withdraw_count,
            lp_pt_in, lp_pt_out, lp_sy_in, lp_sy_out, lp_tokens_minted, lp_tokens_burned,
            is_expired, slot, refreshed_at
        )
        WITH vault_1m AS (
            SELECT
                time_bucket('1 minute', v.bucket) AS bt,
                LAST(v.start_ts, v.bucket)                   AS start_ts,
                LAST(v.duration, v.bucket)                    AS duration,
                LAST(v.maturity_ts, v.bucket)                 AS maturity_ts,
                LAST(v.total_sy_in_escrow / POWER(10, v_vault.decimals), v.bucket)  AS total_sy_in_escrow,
                LAST(v.sy_for_pt / POWER(10, v_vault.decimals), v.bucket)          AS sy_for_pt,
                LAST(v.pt_supply / POWER(10, v_vault.decimals), v.bucket)          AS pt_supply,
                LAST(v.treasury_sy / POWER(10, v_vault.decimals), v.bucket)        AS treasury_sy,
                LAST(v.uncollected_sy / POWER(10, v_vault.decimals), v.bucket)     AS uncollected_sy,
                LAST(v.last_seen_sy_exchange_rate, v.bucket)  AS last_seen_sy_exchange_rate,
                LAST(v.all_time_high_sy_exchange_rate, v.bucket) AS all_time_high_sy_exchange_rate,
                LAST(v.final_sy_exchange_rate, v.bucket)      AS final_sy_exchange_rate,
                LAST(v.interest_bps_fee, v.bucket)            AS interest_bps_fee,
                LAST(v.min_op_size_strip / POWER(10, v_vault.decimals), v.bucket)  AS min_op_size_strip,
                LAST(v.min_op_size_merge / POWER(10, v_vault.decimals), v.bucket)  AS min_op_size_merge,
                LAST(v.status, v.bucket)                      AS status,
                LAST(v.max_py_supply / POWER(10, v_vault.decimals), v.bucket)      AS max_py_supply,
                LAST(v.c_collateralization_ratio, v.bucket)     AS c_vault_coll_ratio,
                LAST(v.c_uncollected_yield_ratio, v.bucket)    AS c_vault_uncoll_yield,
                LAST(v.c_treasury_ratio, v.bucket)             AS c_vault_treasury,
                LAST(v.c_available_liquidity / POWER(10, v_vault.decimals), v.bucket) AS c_vault_avail_liq,
                LAST(v.c_yield_index_health, v.bucket)         AS c_vault_yield_health,
                LAST(v.slot, v.bucket)                        AS slot
            FROM exponent.cagg_vaults_5s v
            WHERE v.vault_address = v_vault.vault_address
              AND v.bucket >= v_seed_from
            GROUP BY time_bucket('1 minute', v.bucket)
        ),
        market_1m AS (
            SELECT
                time_bucket('1 minute', m.bucket) AS bt,
                LAST(m.pt_balance / POWER(10, v_vault.decimals), m.bucket)  AS pt_balance,
                LAST(m.sy_balance / POWER(10, v_vault.decimals), m.bucket)  AS sy_balance,
                LAST(m.ln_implied_rate, m.bucket)             AS ln_implied_rate,
                LAST(m.expiration_ts, m.bucket)               AS expiration_ts,
                LAST(m.ln_fee_rate_root, m.bucket)            AS ln_fee_rate_root,
                LAST(m.rate_scalar_root, m.bucket)            AS rate_scalar_root,
                LAST(m.fee_treasury_sy_bps, m.bucket)         AS fee_treasury_sy_bps,
                LAST(m.lp_escrow_amount / POWER(10, v_vault.decimals), m.bucket) AS lp_escrow_amount,
                LAST(m.max_lp_supply / POWER(10, v_vault.decimals), m.bucket) AS max_lp_supply,
                LAST(m.status_flags, m.bucket)                AS status_flags,
                LAST(m.c_implied_apy, m.bucket)               AS c_market_implied_apy,
                LAST(m.c_discount_rate, m.bucket)             AS c_market_discount_rate,
                LAST(m.c_implied_pt_price, m.bucket)          AS pt_base_price
            FROM exponent.cagg_market_twos_5s m
            WHERE m.market_address = v_vault.market_address
              AND m.bucket >= v_seed_from
            GROUP BY time_bucket('1 minute', m.bucket)
        ),
        yt_1m AS (
            SELECT
                time_bucket('1 minute', y.bucket) AS bt,
                LAST(y.amount / POWER(10, v_vault.decimals), y.bucket) AS yt_escrow_balance
            FROM exponent.cagg_vault_yt_escrow_5s y
            WHERE y.vault = v_vault.vault_address
              AND y.bucket >= v_seed_from
            GROUP BY time_bucket('1 minute', y.bucket)
        ),
        sy_1m AS (
            SELECT
                time_bucket('1 minute', s.bucket) AS bt,
                LAST(s.sy_exchange_rate, s.bucket) AS sy_exchange_rate
            FROM exponent.cagg_sy_meta_account_5s s
            WHERE s.mint_sy = v_vault.mint_sy
              AND s.bucket >= v_seed_from
            GROUP BY time_bucket('1 minute', s.bucket)
        ),
        tx_1m AS (
            SELECT
                time_bucket('1 minute', t.bucket_time) AS bt,
                SUM(t.trade_pt_count)::INTEGER              AS amm_pt_swap_count,
                SUM(t.amount_amm_pt_in)                     AS amm_pt_in,
                SUM(t.amount_amm_pt_out)                    AS amm_pt_out,
                SUM(ABS(t.amount_amm_pt_in) + ABS(t.amount_amm_pt_out)) AS amm_pt_volume,
                SUM(t.amount_amm_pt_in - t.amount_amm_pt_out) AS amm_pt_net_flow,
                SUM(t.lp_deposit_count)::INTEGER            AS lp_deposit_count,
                SUM(t.lp_withdraw_count)::INTEGER           AS lp_withdraw_count,
                SUM(t.amount_lp_pt_in)                      AS lp_pt_in,
                SUM(t.amount_lp_pt_out)                     AS lp_pt_out,
                SUM(t.amount_lp_sy_in)                      AS lp_sy_in,
                SUM(t.amount_lp_sy_out)                     AS lp_sy_out,
                SUM(t.amount_lp_tokens_in)                  AS lp_tokens_minted,
                SUM(t.amount_lp_tokens_out)                 AS lp_tokens_burned
            FROM exponent.cagg_tx_events_5s t
            -- AMM trade + LP flows in cagg_tx_events_5s are partitioned by market_address.
            -- Matching on vault_address drops rows where vault_address is NULL (common for trade_pt),
            -- which zeroes swap/LP metrics in frontend timeseries.
            WHERE t.market_address = v_vault.market_address
              AND t.bucket_time >= v_seed_from
            GROUP BY time_bucket('1 minute', t.bucket_time)
        ),
        all_buckets AS (
            SELECT bt FROM vault_1m
            UNION SELECT bt FROM market_1m
            UNION SELECT bt FROM yt_1m
            UNION SELECT bt FROM sy_1m
            UNION SELECT bt FROM tx_1m
        ),
        combined AS (
            SELECT
                ab.bt,
                vlt.start_ts, vlt.duration, vlt.maturity_ts,
                vlt.total_sy_in_escrow, vlt.sy_for_pt, vlt.pt_supply,
                vlt.treasury_sy, vlt.uncollected_sy,
                -- Yield composition (calculated from vault state)
                CASE WHEN COALESCE(vlt.total_sy_in_escrow, 0) > 0
                     THEN ROUND((vlt.sy_for_pt / vlt.total_sy_in_escrow * 100)::NUMERIC, 4) END AS sy_for_pt_pct_sy,
                CASE WHEN COALESCE(vlt.total_sy_in_escrow, 0) > 0
                     THEN ROUND(((vlt.total_sy_in_escrow - vlt.sy_for_pt) / vlt.total_sy_in_escrow * 100)::NUMERIC, 4) END AS sy_yield_pool_pct,
                CASE WHEN (vlt.total_sy_in_escrow - vlt.sy_for_pt) > 0
                     THEN ROUND((vlt.uncollected_sy / (vlt.total_sy_in_escrow - vlt.sy_for_pt) * 100)::NUMERIC, 4) END AS sy_yield_utilization_pct,
                CASE WHEN vlt.last_seen_sy_exchange_rate IS NOT NULL
                     THEN ROUND(((vlt.last_seen_sy_exchange_rate - 1.0) * 100)::NUMERIC, 6) END AS sy_cumulative_yield_pct,
                CASE WHEN COALESCE(vlt.pt_supply, 0) > 0
                     THEN ROUND(((vlt.sy_for_pt * COALESCE(vlt.last_seen_sy_exchange_rate, 1.0) - vlt.pt_supply) / vlt.pt_supply * 100)::NUMERIC, 4) END AS sy_collateral_buffer_pct,
                vlt.last_seen_sy_exchange_rate, vlt.all_time_high_sy_exchange_rate, vlt.final_sy_exchange_rate,
                vlt.interest_bps_fee, vlt.min_op_size_strip, vlt.min_op_size_merge,
                vlt.status, vlt.max_py_supply,
                vlt.c_vault_coll_ratio, vlt.c_vault_uncoll_yield, vlt.c_vault_treasury,
                vlt.c_vault_avail_liq, vlt.c_vault_yield_health,
                mkt.pt_balance, mkt.sy_balance,
                mkt.ln_implied_rate, mkt.expiration_ts,
                mkt.ln_fee_rate_root, mkt.rate_scalar_root, mkt.fee_treasury_sy_bps,
                mkt.lp_escrow_amount, mkt.max_lp_supply, mkt.status_flags,
                mkt.c_market_implied_apy, mkt.c_market_discount_rate, mkt.pt_base_price,
                -- Pool depth calculations
                CASE WHEN mkt.pt_base_price IS NOT NULL
                     THEN mkt.sy_balance + mkt.pt_balance * mkt.pt_base_price / COALESCE(NULLIF(sy_meta.sy_exchange_rate, 0), 1.0) END AS pool_depth_in_sy,
                CASE WHEN mkt.pt_base_price IS NOT NULL
                     THEN mkt.pt_balance * mkt.pt_base_price / COALESCE(NULLIF(sy_meta.sy_exchange_rate, 0), 1.0) END AS pt_balance_in_sy,
                CASE WHEN mkt.pt_base_price IS NOT NULL AND (mkt.sy_balance + mkt.pt_balance * mkt.pt_base_price / COALESCE(NULLIF(sy_meta.sy_exchange_rate, 0), 1.0)) > 0
                     THEN ROUND((mkt.sy_balance / (mkt.sy_balance + mkt.pt_balance * mkt.pt_base_price / COALESCE(NULLIF(sy_meta.sy_exchange_rate, 0), 1.0)) * 100)::NUMERIC, 2) END AS pool_depth_sy_pct,
                CASE WHEN mkt.pt_base_price IS NOT NULL AND (mkt.sy_balance + mkt.pt_balance * mkt.pt_base_price / COALESCE(NULLIF(sy_meta.sy_exchange_rate, 0), 1.0)) > 0
                     THEN ROUND(((mkt.pt_balance * mkt.pt_base_price / COALESCE(NULLIF(sy_meta.sy_exchange_rate, 0), 1.0)) / (mkt.sy_balance + mkt.pt_balance * mkt.pt_base_price / COALESCE(NULLIF(sy_meta.sy_exchange_rate, 0), 1.0)) * 100)::NUMERIC, 2) END AS pool_depth_pt_pct,
                yt_esc.yt_escrow_balance,
                sy_meta.sy_exchange_rate,
                COALESCE(tx.amm_pt_swap_count, 0) AS amm_pt_swap_count,
                COALESCE(tx.amm_pt_in, 0)         AS amm_pt_in,
                COALESCE(tx.amm_pt_out, 0)         AS amm_pt_out,
                COALESCE(tx.amm_pt_volume, 0)      AS amm_pt_volume,
                COALESCE(tx.amm_pt_net_flow, 0)    AS amm_pt_net_flow,
                COALESCE(tx.lp_deposit_count, 0)   AS lp_deposit_count,
                COALESCE(tx.lp_withdraw_count, 0)  AS lp_withdraw_count,
                COALESCE(tx.lp_pt_in, 0)           AS lp_pt_in,
                COALESCE(tx.lp_pt_out, 0)          AS lp_pt_out,
                COALESCE(tx.lp_sy_in, 0)           AS lp_sy_in,
                COALESCE(tx.lp_sy_out, 0)          AS lp_sy_out,
                COALESCE(tx.lp_tokens_minted, 0)   AS lp_tokens_minted,
                COALESCE(tx.lp_tokens_burned, 0)   AS lp_tokens_burned,
                CASE WHEN vlt.maturity_ts IS NOT NULL
                     THEN ab.bt > to_timestamp(vlt.maturity_ts)
                     ELSE FALSE END AS is_expired,
                vlt.slot
            FROM all_buckets ab
            LEFT JOIN vault_1m vlt  ON vlt.bt = ab.bt
            LEFT JOIN market_1m mkt ON mkt.bt = ab.bt
            LEFT JOIN yt_1m yt_esc  ON yt_esc.bt = ab.bt
            LEFT JOIN sy_1m sy_meta ON sy_meta.bt = ab.bt
            LEFT JOIN tx_1m tx      ON tx.bt = ab.bt
        )
        SELECT
            c.bt,
            v_vault.vault_address,
            v_vault.market_address,
            v_vault.mint_sy,
            v_vault.mint_pt,
            v_vault.mint_yt,
            c.start_ts, c.duration, c.maturity_ts,
            c.total_sy_in_escrow, c.sy_for_pt, c.pt_supply, c.treasury_sy, c.uncollected_sy,
            c.sy_for_pt_pct_sy, c.sy_yield_pool_pct, c.sy_yield_utilization_pct,
            c.sy_cumulative_yield_pct, c.sy_collateral_buffer_pct,
            c.last_seen_sy_exchange_rate, c.all_time_high_sy_exchange_rate, c.final_sy_exchange_rate,
            c.interest_bps_fee, c.min_op_size_strip, c.min_op_size_merge, c.status, c.max_py_supply,
            c.c_vault_coll_ratio, c.c_vault_uncoll_yield, c.c_vault_treasury,
            c.c_vault_avail_liq, c.c_vault_yield_health,
            c.pt_balance, c.sy_balance,
            c.ln_implied_rate, c.expiration_ts,
            c.ln_fee_rate_root, c.rate_scalar_root, c.fee_treasury_sy_bps,
            c.lp_escrow_amount, c.max_lp_supply, c.status_flags,
            c.c_market_implied_apy, c.c_market_discount_rate, c.pt_base_price,
            c.pool_depth_in_sy, c.pt_balance_in_sy, c.pool_depth_sy_pct, c.pool_depth_pt_pct,
            c.yt_escrow_balance,
            c.sy_exchange_rate,
            c.amm_pt_swap_count, c.amm_pt_in, c.amm_pt_out, c.amm_pt_volume, c.amm_pt_net_flow,
            c.lp_deposit_count, c.lp_withdraw_count,
            c.lp_pt_in, c.lp_pt_out, c.lp_sy_in, c.lp_sy_out, c.lp_tokens_minted, c.lp_tokens_burned,
            c.is_expired,
            c.slot,
            NOW()
        FROM combined c
        WHERE c.bt >= v_refresh_from;
    END LOOP;
END;
$$;
