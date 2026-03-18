-- =============================================
-- DEX OHLCV View Function (with p_invert support)
-- =============================================
-- Returns interval-bucketed OHLC + volume data suitable for
-- candlestick and volume chart rendering.
--
-- When p_invert = TRUE, prices become t0-per-t1 (reciprocal) and
-- volume_t0 / volume_t1 are swapped so the chart shows the
-- inverted token perspective.
--
-- Source table:
--   dexes.cagg_events_5s
-- =============================================

DROP FUNCTION IF EXISTS dexes.get_view_dex_ohlcv(TEXT, TEXT, TEXT, INTEGER);
DROP FUNCTION IF EXISTS dexes.get_view_dex_ohlcv(TEXT, TEXT, TEXT, INTEGER, BOOLEAN);
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
        RAISE NOTICE 'Invalid interval provided: %. Defaulting to 15 minutes.', p_interval;
    END;

    IF p_rows IS NULL OR p_rows < 1 THEN
        p_rows := 120;
    END IF;

    v_lookback_time := NOW() - (v_interval * p_rows);

    RETURN QUERY
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
        WHERE e.protocol = p_protocol
            AND e.token_pair = p_token_pair
            AND e.activity_category = 'swap'
            AND e.bucket_time >= v_lookback_time
    ),
    aggregated AS (
        SELECT
            time_bucket(v_interval, s.bucket_time) AS time,
            s.pool_address,
            s.protocol,
            s.token_pair,
            FIRST(s.price_t1_per_t0, s.bucket_time) FILTER (WHERE s.price_t1_per_t0 IS NOT NULL) AS open_price,
            MAX(s.price_t1_per_t0) AS high_price,
            MIN(s.price_t1_per_t0) AS low_price,
            LAST(s.price_t1_per_t0, s.bucket_time) FILTER (WHERE s.price_t1_per_t0 IS NOT NULL) AS close_price,
            FLOOR(SUM(s.amount0_in + s.amount0_out))::BIGINT AS volume_t0,
            FLOOR(SUM(s.amount1_in + s.amount1_out))::BIGINT AS volume_t1,
            SUM(s.event_count)::BIGINT AS swap_count
        FROM source_rows s
        GROUP BY
            time_bucket(v_interval, s.bucket_time),
            s.pool_address,
            s.protocol,
            s.token_pair
    ),
    limited AS (
        SELECT
            a.*
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
        CASE WHEN p_invert
             THEN ROUND(1.0 / NULLIF(l.open_price, 0), 8)
             ELSE ROUND(l.open_price, 8) END AS open_price,
        CASE WHEN p_invert
             THEN ROUND(1.0 / NULLIF(l.low_price, 0), 8)
             ELSE ROUND(l.high_price, 8) END AS high_price,
        CASE WHEN p_invert
             THEN ROUND(1.0 / NULLIF(l.high_price, 0), 8)
             ELSE ROUND(l.low_price, 8) END AS low_price,
        CASE WHEN p_invert
             THEN ROUND(1.0 / NULLIF(l.close_price, 0), 8)
             ELSE ROUND(l.close_price, 8) END AS close_price,
        CASE WHEN p_invert THEN l.volume_t1 ELSE l.volume_t0 END,
        CASE WHEN p_invert THEN l.volume_t0 ELSE l.volume_t1 END,
        l.swap_count
    FROM limited l
    ORDER BY l.time;
END;
$$;
