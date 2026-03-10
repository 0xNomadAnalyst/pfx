-- mat_exp_last: Pre-computed latest state per Exponent vault/market pair
-- Eliminates the expensive ~40 CTE + multi-source joins in get_view_exponent_last
-- One row per vault_address with latest metrics.

CREATE TABLE IF NOT EXISTS exponent.mat_exp_last (
    vault_address                TEXT PRIMARY KEY,
    market_address               TEXT,
    mint_sy                      TEXT,
    mint_pt                      TEXT,
    mint_yt                      TEXT,
    meta_pt_name                 TEXT,

    -- Maturity
    start_ts                     INTEGER,
    duration                     INTEGER,
    maturity_ts                  INTEGER,
    is_expired                   BOOLEAN DEFAULT FALSE,

    -- Vault state
    total_sy_in_escrow           NUMERIC,
    sy_for_pt                    NUMERIC,
    pt_supply                    NUMERIC,
    treasury_sy                  NUMERIC,
    uncollected_sy               NUMERIC,

    -- Exchange rates
    last_seen_sy_exchange_rate   NUMERIC,
    all_time_high_sy_exchange_rate NUMERIC,
    final_sy_exchange_rate       NUMERIC,

    -- Vault calculated
    c_vault_collateralization_ratio NUMERIC,
    c_vault_yield_index_health   NUMERIC,
    c_vault_available_liquidity  NUMERIC,

    -- Market metrics
    pt_balance                   NUMERIC,
    sy_balance                   NUMERIC,
    c_market_implied_apy         NUMERIC,
    c_market_discount_rate       NUMERIC,
    pt_base_price                NUMERIC,

    -- Pool depth
    pool_depth_in_sy             NUMERIC,
    amm_share_sy_pct             NUMERIC,

    -- YT
    yt_escrow_balance            NUMERIC,
    yt_staked_pct                NUMERIC,

    -- SY exchange rate (live)
    sy_exchange_rate             NUMERIC,

    -- Trailing APY
    sy_trailing_apy_1h           NUMERIC,
    sy_trailing_apy_24h          NUMERIC,
    sy_trailing_apy_7d           NUMERIC,
    sy_trailing_apy_vault_life   NUMERIC,

    -- AMM volume 24h
    amm_pt_vol_24h               NUMERIC,

    -- Metadata
    last_updated                 TIMESTAMPTZ,
    slot                         BIGINT,
    refreshed_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- Refresh procedure: full recompute for all active vaults
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE exponent.refresh_mat_exp_last()
LANGUAGE plpgsql AS $$
DECLARE
    v_rec RECORD;
BEGIN
    TRUNCATE exponent.mat_exp_last;

    FOR v_rec IN
        SELECT DISTINCT
            kr.vault_address,
            kr.market_address,
            kr.mint_sy,
            kr.mint_pt,
            kr.mint_yt,
            kr.meta_pt_name,
            COALESCE(kr.env_sy_decimals, kr.meta_sy_decimals, 6) AS decimals
        FROM exponent.aux_key_relations kr
        WHERE kr.vault_address IS NOT NULL
          AND kr.market_address IS NOT NULL
    LOOP
        BEGIN
            INSERT INTO exponent.mat_exp_last (
                vault_address, market_address, mint_sy, mint_pt, mint_yt, meta_pt_name,
                start_ts, duration, maturity_ts, is_expired,
                total_sy_in_escrow, sy_for_pt, pt_supply, treasury_sy, uncollected_sy,
                last_seen_sy_exchange_rate, all_time_high_sy_exchange_rate, final_sy_exchange_rate,
                c_vault_collateralization_ratio, c_vault_yield_index_health, c_vault_available_liquidity,
                pt_balance, sy_balance,
                c_market_implied_apy, c_market_discount_rate, pt_base_price,
                pool_depth_in_sy, amm_share_sy_pct,
                yt_escrow_balance, yt_staked_pct,
                sy_exchange_rate,
                amm_pt_vol_24h,
                last_updated, slot, refreshed_at
            )
            WITH latest_vault AS (
                SELECT *
                FROM exponent.src_vaults v
                WHERE v.vault_address = v_rec.vault_address
                ORDER BY v.block_time DESC
                LIMIT 1
            ),
            latest_market AS (
                SELECT *
                FROM exponent.src_market_twos m
                WHERE m.market_address = v_rec.market_address
                ORDER BY m.block_time DESC
                LIMIT 1
            ),
            latest_yt AS (
                SELECT *
                FROM exponent.src_vault_yt_escrow y
                WHERE y.vault_address = v_rec.vault_address
                ORDER BY y.block_time DESC
                LIMIT 1
            ),
            latest_sy AS (
                SELECT *
                FROM exponent.src_sy_meta_account s
                WHERE s.mint_sy = v_rec.mint_sy
                ORDER BY s.block_time DESC
                LIMIT 1
            ),
            vol_24h AS (
                SELECT COALESCE(SUM(t.amm_pt_volume), 0) AS vol
                FROM exponent.cagg_tx_events_5s t
                WHERE t.vault_address = v_rec.vault_address
                  AND t.bucket_time >= NOW() - INTERVAL '24 hours'
            )
            SELECT
                v_rec.vault_address,
                v_rec.market_address,
                v_rec.mint_sy,
                v_rec.mint_pt,
                v_rec.mint_yt,
                v_rec.meta_pt_name,
                vlt.start_ts,
                vlt.duration,
                vlt.maturity_ts,
                NOW() > to_timestamp(vlt.maturity_ts),
                vlt.total_sy / POWER(10, v_rec.decimals),
                vlt.sy_for_pt / POWER(10, v_rec.decimals),
                vlt.pt_supply / POWER(10, v_rec.decimals),
                vlt.treasury_sy / POWER(10, v_rec.decimals),
                vlt.uncollected_sy / POWER(10, v_rec.decimals),
                vlt.last_seen_sy_exchange_rate,
                vlt.all_time_high_sy_exchange_rate,
                vlt.final_sy_exchange_rate,
                vlt.c_vault_collateralization_ratio,
                vlt.c_vault_yield_index_health,
                vlt.c_vault_available_liquidity / POWER(10, v_rec.decimals),
                mkt.pt_balance / POWER(10, v_rec.decimals),
                mkt.sy_balance / POWER(10, v_rec.decimals),
                mkt.c_market_implied_apy,
                mkt.c_market_discount_rate,
                mkt.c_pt_base_price,
                -- Pool depth in SY
                CASE WHEN mkt.c_pt_base_price IS NOT NULL AND sy.exchange_rate > 0
                     THEN (mkt.sy_balance / POWER(10, v_rec.decimals)) +
                          (mkt.pt_balance / POWER(10, v_rec.decimals)) * mkt.c_pt_base_price / sy.exchange_rate
                     ELSE NULL END,
                -- AMM share of SY claims
                CASE WHEN vlt.total_sy > 0
                     THEN ROUND((mkt.sy_balance / POWER(10, v_rec.decimals)) / (vlt.total_sy / POWER(10, v_rec.decimals)) * 100, 2)
                     ELSE NULL END,
                yt.yt_balance / POWER(10, v_rec.decimals),
                -- YT staked %
                CASE WHEN (vlt.pt_supply / POWER(10, v_rec.decimals)) > 0
                     THEN ROUND(((vlt.pt_supply / POWER(10, v_rec.decimals)) - (yt.yt_balance / POWER(10, v_rec.decimals))) /
                                (vlt.pt_supply / POWER(10, v_rec.decimals)) * 100, 2)
                     ELSE NULL END,
                sy.exchange_rate,
                vol.vol / POWER(10, v_rec.decimals),
                GREATEST(vlt.block_time, mkt.block_time),
                GREATEST(vlt.slot, mkt.slot),
                NOW()
            FROM latest_vault vlt
            LEFT JOIN latest_market mkt ON TRUE
            LEFT JOIN latest_yt yt ON TRUE
            LEFT JOIN latest_sy sy ON TRUE
            CROSS JOIN vol_24h vol;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'refresh_mat_exp_last: failed for vault % — %', v_rec.vault_address, SQLERRM;
        END;
    END LOOP;
END;
$$;
