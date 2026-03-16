-- get_view_dex_ohlcv: Re-bucketed read from mat_dex_ohlcv_1m
-- Same signature and output schema as the original (dexes/dbsql/views/get_view_dex_ohlcv.sql)
-- Re-buckets from 1-minute pre-computed OHLCV instead of from 5-second CAGG.

DROP FUNCTION IF EXISTS dexes.get_view_dex_ohlcv(TEXT, TEXT, TEXT, INTEGER);
CREATE OR REPLACE FUNCTION dexes.get_view_dex_ohlcv(
    p_protocol TEXT,
    p_token_pair TEXT,
    p_interval TEXT DEFAULT '15 minutes',
    p_rows INTEGER DEFAULT 120,
    p_invert BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    "time" TIMESTAMPTZ,
    pool_address TEXT,
    protocol TEXT,
    token_pair TEXT,
    open_price NUMERIC(20,8),
    high_price NUMERIC(20,8),
    low_price NUMERIC(20,8),
    close_price NUMERIC(20,8),
    volume_t0 BIGINT,
    volume_t1 BIGINT,
    swap_count BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_interval INTERVAL;
    v_lookback_time TIMESTAMPTZ;
BEGIN
    BEGIN
        v_interval := p_interval::INTERVAL;
    EXCEPTION WHEN OTHERS THEN
        v_interval := INTERVAL '15 minutes';
    END;

    IF p_rows IS NULL OR p_rows < 1 THEN
        p_rows := 120;
    END IF;

    v_lookback_time := NOW() - (v_interval * p_rows);

    RETURN QUERY
    WITH aggregated AS (
        SELECT
            time_bucket(v_interval, m.bucket_time) AS time,
            m.pool_address,
            m.protocol,
            m.token_pair,
            FIRST(m.open_price, m.bucket_time) FILTER (WHERE m.open_price IS NOT NULL)  AS open_price,
            MAX(m.high_price)                                                             AS high_price,
            MIN(m.low_price)                                                              AS low_price,
            LAST(m.close_price, m.bucket_time) FILTER (WHERE m.close_price IS NOT NULL)  AS close_price,
            SUM(m.volume_t0)::BIGINT                                                      AS volume_t0,
            SUM(m.volume_t1)::BIGINT                                                      AS volume_t1,
            SUM(m.swap_count)::BIGINT                                                     AS swap_count
        FROM dexes.mat_dex_ohlcv_1m m
        WHERE m.protocol = p_protocol
          AND m.token_pair = p_token_pair
          AND m.bucket_time >= v_lookback_time
        GROUP BY
            time_bucket(v_interval, m.bucket_time),
            m.pool_address, m.protocol, m.token_pair
    ),
    limited AS (
        SELECT a.*
        FROM aggregated a
        WHERE a.open_price IS NOT NULL
          AND a.close_price IS NOT NULL
        ORDER BY a.time DESC
        LIMIT p_rows
    )
    SELECT
        l.time,
        l.pool_address,
        l.protocol,
        l.token_pair,
        CASE WHEN p_invert THEN ROUND(1.0 / NULLIF(l.open_price, 0), 8)
             ELSE ROUND(l.open_price, 8) END,
        -- When inverted, 1/low becomes the new high and 1/high becomes the new low
        CASE WHEN p_invert THEN ROUND(1.0 / NULLIF(l.low_price, 0), 8)
             ELSE ROUND(l.high_price, 8) END,
        CASE WHEN p_invert THEN ROUND(1.0 / NULLIF(l.high_price, 0), 8)
             ELSE ROUND(l.low_price, 8) END,
        CASE WHEN p_invert THEN ROUND(1.0 / NULLIF(l.close_price, 0), 8)
             ELSE ROUND(l.close_price, 8) END,
        CASE WHEN p_invert THEN l.volume_t1 ELSE l.volume_t0 END,
        CASE WHEN p_invert THEN l.volume_t0 ELSE l.volume_t1 END,
        l.swap_count
    FROM limited l
    ORDER BY l.time;
END;
$$;
