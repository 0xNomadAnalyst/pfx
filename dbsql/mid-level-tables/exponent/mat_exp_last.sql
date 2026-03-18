-- mat_exp_last: Materialized per-market snapshot for get_view_exponent_last (PFX)
--
-- One row per vault/market pair. Populated by refresh_mat_exp_last() which reads
-- src_vaults, src_market_twos, src_vault_yt_escrow, src_sy_meta_account, cagg_tx_events_5s.
-- All numeric amounts are DECIMAL-ADJUSTED (divided by 10^decimals during refresh).
--
-- Consumers: pfx/dbsql/frontend-views/exponent/get_view_exponent_last.sql

CREATE TABLE IF NOT EXISTS exponent.mat_exp_last (
    vault_address                   TEXT,
    market_address                  TEXT,
    mint_sy                         TEXT,
    mint_pt                         TEXT,
    mint_yt                         TEXT,
    meta_pt_name                    TEXT,
    start_ts                        INTEGER,
    duration                        INTEGER,
    maturity_ts                     INTEGER,
    is_expired                      BOOLEAN,
    total_sy_in_escrow              NUMERIC,
    sy_for_pt                       NUMERIC,
    pt_supply                       NUMERIC,
    treasury_sy                     NUMERIC,
    uncollected_sy                  NUMERIC,
    last_seen_sy_exchange_rate      NUMERIC,
    all_time_high_sy_exchange_rate  NUMERIC,
    final_sy_exchange_rate          NUMERIC,
    c_vault_collateralization_ratio NUMERIC,
    c_vault_yield_index_health      NUMERIC,
    c_vault_available_liquidity     NUMERIC,
    pt_balance                      NUMERIC,
    sy_balance                      NUMERIC,
    c_market_implied_apy            NUMERIC,
    c_market_discount_rate          NUMERIC,
    pt_base_price                   NUMERIC,   -- = c_implied_pt_price (in underlying/base terms)
    pool_depth_in_sy                NUMERIC,   -- = (sy_balance + pt_balance * pt_price / sy_rate) / 10^d
    amm_share_sy_pct                NUMERIC,
    yt_escrow_balance               NUMERIC,
    yt_staked_pct                   NUMERIC,   -- NOTE: actually (pt_supply - yt_escrow) / pt_supply * 100
    sy_exchange_rate                NUMERIC,
    sy_trailing_apy_1h              NUMERIC,   -- reserved, currently NULL
    sy_trailing_apy_24h             NUMERIC,   -- reserved, currently NULL
    sy_trailing_apy_7d              NUMERIC,   -- reserved, currently NULL
    sy_trailing_apy_vault_life      NUMERIC,   -- reserved, currently NULL
    amm_pt_vol_24h                  NUMERIC,
    last_updated                    TIMESTAMPTZ,
    slot                            BIGINT,
    refreshed_at                    TIMESTAMPTZ
);

-- ═══════════════════════════════════════════════════════════════════════════
-- REFRESH PROCEDURE
-- Called periodically to rebuild the table from source data.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE PROCEDURE exponent.refresh_mat_exp_last()
LANGUAGE plpgsql
AS $procedure$
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
                WHERE y.vault = v_rec.vault_address
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
                SELECT COALESCE(SUM(ABS(t.amount_amm_pt_in) + ABS(t.amount_amm_pt_out)), 0) AS vol
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
                vlt.total_sy_in_escrow / POWER(10, v_rec.decimals),
                vlt.sy_for_pt / POWER(10, v_rec.decimals),
                vlt.pt_supply / POWER(10, v_rec.decimals),
                vlt.treasury_sy / POWER(10, v_rec.decimals),
                vlt.uncollected_sy / POWER(10, v_rec.decimals),
                vlt.last_seen_sy_exchange_rate,
                vlt.all_time_high_sy_exchange_rate,
                vlt.final_sy_exchange_rate,
                vlt.c_collateralization_ratio,
                vlt.c_yield_index_health,
                vlt.c_available_liquidity / POWER(10, v_rec.decimals),
                mkt.pt_balance / POWER(10, v_rec.decimals),
                mkt.sy_balance / POWER(10, v_rec.decimals),
                mkt.c_implied_apy,
                mkt.c_discount_rate,
                mkt.c_implied_pt_price,
                CASE WHEN mkt.c_implied_pt_price IS NOT NULL AND sy.sy_exchange_rate > 0
                     THEN (mkt.sy_balance / POWER(10, v_rec.decimals)) +
                          (mkt.pt_balance / POWER(10, v_rec.decimals)) * mkt.c_implied_pt_price / sy.sy_exchange_rate
                     ELSE NULL END,
                CASE WHEN vlt.total_sy_in_escrow > 0
                     THEN ROUND(((mkt.sy_balance / POWER(10, v_rec.decimals)) / (vlt.total_sy_in_escrow / POWER(10, v_rec.decimals)) * 100)::NUMERIC, 2)
                     ELSE NULL END,
                yt.amount / POWER(10, v_rec.decimals),
                CASE WHEN (vlt.pt_supply / POWER(10, v_rec.decimals)) > 0
                     THEN ROUND((((vlt.pt_supply / POWER(10, v_rec.decimals)) - (yt.amount / POWER(10, v_rec.decimals))) /
                                (vlt.pt_supply / POWER(10, v_rec.decimals)) * 100)::NUMERIC, 2)
                     ELSE NULL END,
                sy.sy_exchange_rate,
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
$procedure$;
