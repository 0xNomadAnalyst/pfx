-- mat_dex_last: Pre-computed latest snapshot per pool
-- Eliminates the expensive per-request DISTINCT ON + lookback scan in get_view_dex_last

CREATE TABLE IF NOT EXISTS dexes.mat_dex_last (
    pool_address                    TEXT PRIMARY KEY,
    protocol                        TEXT,
    token_pair                      TEXT,
    symbols_t0_t1                   TEXT[],

    -- Liquidity depth query metadata
    liq_query_id                    BIGINT,
    price_t1_per_t0                 NUMERIC,

    -- Price impact for standard trade sizes (selling token0)
    impact_t0_quantities            DOUBLE PRECISION[],
    impact_from_t0_sell1_bps        NUMERIC,
    impact_from_t0_sell2_bps        NUMERIC,
    impact_from_t0_sell3_bps        NUMERIC,

    -- Reserve metrics
    t0_reserve                      BIGINT,
    t1_reserve                      BIGINT,
    tvl_in_t1_units                 BIGINT,
    reserve_t0_t1_millions          NUMERIC[],
    reserve_t0_t1_balance_pct       NUMERIC[],

    -- Event counts (lookback window)
    swap_count_period               BIGINT,
    lp_in_count_period              BIGINT,
    lp_out_count_period             BIGINT,

    -- Swap volume (lookback window)
    swap_vol_in_t1_units            BIGINT,
    swap_vol_in_t0_units            BIGINT,
    swap_vol_in_t1_units_pct_reserve NUMERIC,
    swap_vol_in_t0_units_pct_reserve NUMERIC,
    swap_vol_out_t1_units           BIGINT,
    swap_vol_out_t0_units           BIGINT,
    swap_vol_out_t1_units_pct_reserve NUMERIC,
    swap_vol_out_t0_units_pct_reserve NUMERIC,

    -- Directional swap volumes
    swap_vol_period_t0_in           BIGINT,
    swap_vol_period_t0_out          BIGINT,
    swap_vol_period_t1_in           BIGINT,
    swap_vol_period_t1_out          BIGINT,

    -- LP activity
    lp_token0_in_period_sum         BIGINT,
    lp_token0_out_period_sum        BIGINT,
    lp_token1_in_period_sum         BIGINT,
    lp_token1_out_period_sum        BIGINT,

    -- LP activity as % of reserves
    lp_token0_in_period_sum_pct_reserve  NUMERIC,
    lp_token0_out_period_sum_pct_reserve NUMERIC,
    lp_token1_in_period_sum_pct_reserve  NUMERIC,
    lp_token1_out_period_sum_pct_reserve NUMERIC,

    -- Max swap flows with complements
    swap_token1_in_max              BIGINT,
    swap_token1_in_max_t0_complement BIGINT,
    swap_token1_out_max             BIGINT,
    swap_token1_out_max_t0_complement BIGINT,
    swap_token0_in_max              BIGINT,
    swap_token0_out_max             BIGINT,

    -- Average swap flows
    swap_token0_in_avg              NUMERIC,
    swap_token0_out_avg             NUMERIC,
    swap_token1_in_avg              NUMERIC,
    swap_token1_out_avg             NUMERIC,

    -- Max swap as % of reserves
    swap_token1_in_max_pct_reserve  NUMERIC,
    swap_token1_out_max_pct_reserve NUMERIC,

    -- Price impact for max swaps
    swap_token1_in_max_impact_bps   NUMERIC,
    swap_token1_out_max_impact_bps  NUMERIC,
    swap_token0_in_max_impact_bps   NUMERIC,
    swap_token0_out_max_impact_bps  NUMERIC,

    -- Price impact for average swaps
    swap_token0_in_avg_impact_bps   NUMERIC,
    swap_token0_out_avg_impact_bps  NUMERIC,
    swap_token1_in_avg_impact_bps   NUMERIC,
    swap_token1_out_avg_impact_bps  NUMERIC,

    -- VWAP and spread metrics
    vwap_buy_t0_avg                 NUMERIC,
    vwap_sell_t0_avg                NUMERIC,
    price_t1_per_t0_avg             NUMERIC,
    spread_vwap_avg_bps             NUMERIC,

    -- Price statistics
    price_t1_per_t0_max             NUMERIC,
    price_t1_per_t0_min             NUMERIC,
    price_t1_per_t0_std             NUMERIC,

    -- 24-hour fixed window metrics
    swap_vol_t1_total_24h           BIGINT,
    swap_vol_t1_total_24h_pct_tvl_in_t1 NUMERIC,
    max_1h_t0_sell_pressure_pct_reserve NUMERIC,
    max_1h_t0_sell_pressure_start   TIMESTAMPTZ,

    -- Metadata
    refreshed_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_mat_dex_last_pair
    ON dexes.mat_dex_last (protocol, token_pair);

-- ---------------------------------------------------------------------------
-- Refresh procedure: full recompute (one row per pool)
-- Calls get_view_dex_last for each active pool and stores the result.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE dexes.refresh_mat_dex_last()
LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
BEGIN
    TRUNCATE dexes.mat_dex_last;

    -- Insert latest snapshot for each active pool
    FOR r IN
        SELECT DISTINCT protocol, token_pair
        FROM dexes.pool_tokens_reference
    LOOP
        BEGIN
            INSERT INTO dexes.mat_dex_last
            SELECT
                dl.*,
                NOW() AS refreshed_at
            FROM dexes.get_view_dex_last(r.protocol, r.token_pair, INTERVAL '1 hour') dl;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'refresh_mat_dex_last: failed for %/% — %', r.protocol, r.token_pair, SQLERRM;
        END;
    END LOOP;
END;
$$;
