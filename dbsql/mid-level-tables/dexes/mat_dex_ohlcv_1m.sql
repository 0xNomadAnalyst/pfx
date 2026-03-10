-- mat_dex_ohlcv_1m: Pre-computed 1-minute OHLCV from cagg_events_5s
-- Allows the OHLCV view to re-bucket from 1m instead of 5s

CREATE TABLE IF NOT EXISTS dexes.mat_dex_ohlcv_1m (
    bucket_time   TIMESTAMPTZ NOT NULL,
    pool_address  TEXT        NOT NULL,
    protocol      TEXT,
    token_pair    TEXT,
    open_price    NUMERIC(20,8),
    high_price    NUMERIC(20,8),
    low_price     NUMERIC(20,8),
    close_price   NUMERIC(20,8),
    volume_t0     BIGINT,
    volume_t1     BIGINT,
    swap_count    BIGINT,
    refreshed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (pool_address, bucket_time)
);

SELECT create_hypertable(
    'dexes.mat_dex_ohlcv_1m', 'bucket_time',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_mat_dex_ohlcv_1m_pool
    ON dexes.mat_dex_ohlcv_1m (pool_address, bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_mat_dex_ohlcv_1m_pair
    ON dexes.mat_dex_ohlcv_1m (token_pair, bucket_time DESC);

-- ---------------------------------------------------------------------------
-- Refresh procedure: incremental upsert of last 30 minutes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE dexes.refresh_mat_dex_ohlcv_1m()
LANGUAGE plpgsql AS $$
DECLARE
    v_refresh_from TIMESTAMPTZ := NOW() - INTERVAL '30 minutes';
BEGIN
    DELETE FROM dexes.mat_dex_ohlcv_1m
    WHERE bucket_time >= v_refresh_from;

    INSERT INTO dexes.mat_dex_ohlcv_1m (
        bucket_time, pool_address, protocol, token_pair,
        open_price, high_price, low_price, close_price,
        volume_t0, volume_t1, swap_count, refreshed_at
    )
    WITH source_rows AS (
        SELECT
            e.bucket_time,
            e.pool_address,
            e.protocol,
            e.token_pair,
            e.event_count,
            COALESCE(e.amount0_in, 0) AS amount0_in,
            COALESCE(e.amount0_out, 0) AS amount0_out,
            COALESCE(e.amount1_in, 0) AS amount1_in,
            COALESCE(e.amount1_out, 0) AS amount1_out,
            COALESCE(
                NULLIF(e.vwap_buy_t0, 0),
                NULLIF(e.vwap_sell_t0, 0),
                CASE
                    WHEN COALESCE(e.amount0_in, 0) > 0 AND COALESCE(e.amount1_out, 0) > 0
                        THEN e.amount1_out / NULLIF(e.amount0_in, 0)
                    WHEN COALESCE(e.amount0_out, 0) > 0 AND COALESCE(e.amount1_in, 0) > 0
                        THEN e.amount1_in / NULLIF(e.amount0_out, 0)
                    ELSE NULL
                END
            )::NUMERIC AS price_t1_per_t0
        FROM dexes.cagg_events_5s e
        WHERE e.activity_category = 'swap'
          AND e.bucket_time >= v_refresh_from
    )
    SELECT
        time_bucket('1 minute', s.bucket_time)       AS bucket_time,
        s.pool_address,
        s.protocol,
        s.token_pair,
        ROUND(FIRST(s.price_t1_per_t0, s.bucket_time) FILTER (WHERE s.price_t1_per_t0 IS NOT NULL), 8) AS open_price,
        ROUND(MAX(s.price_t1_per_t0), 8)             AS high_price,
        ROUND(MIN(s.price_t1_per_t0), 8)             AS low_price,
        ROUND(LAST(s.price_t1_per_t0, s.bucket_time) FILTER (WHERE s.price_t1_per_t0 IS NOT NULL), 8) AS close_price,
        FLOOR(SUM(s.amount0_in + s.amount0_out))::BIGINT AS volume_t0,
        FLOOR(SUM(s.amount1_in + s.amount1_out))::BIGINT AS volume_t1,
        SUM(s.event_count)::BIGINT                   AS swap_count,
        NOW()                                         AS refreshed_at
    FROM source_rows s
    WHERE s.price_t1_per_t0 IS NOT NULL
    GROUP BY
        time_bucket('1 minute', s.bucket_time),
        s.pool_address, s.protocol, s.token_pair
    HAVING FIRST(s.price_t1_per_t0, s.bucket_time) FILTER (WHERE s.price_t1_per_t0 IS NOT NULL) IS NOT NULL;
END;
$$;
