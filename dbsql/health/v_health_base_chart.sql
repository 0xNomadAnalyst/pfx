-- =============================================================================
-- health.v_health_base_chart(p_schema, p_lookback, p_interval)
--
-- Returns time-bucketed row counts for base tables, categorised as
-- 'Transaction Events' vs 'Account Updates'.
--
-- Within each bucket, row counts from finer-grained internal 1-hour
-- sub-buckets are AVERAGED to give a normalised "avg rows/hour" metric
-- that is comparable across different interval settings.
--
-- OPTIMISED: only scans the tables belonging to p_schema (IF/ELSIF branches)
-- instead of scanning ALL schemas then filtering.
--
-- Parameters:
--   p_schema   TEXT — domain: 'dexes','exponent','kamino_lend'
--   p_lookback TEXT — history window as interval literal, e.g. '7 days'
--   p_interval TEXT — bucket width as interval literal, e.g. '1 hour', '4 hours'
--
-- Example:
--   SELECT * FROM health.v_health_base_chart('dexes', '7 days', '1 hour');
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

DROP FUNCTION IF EXISTS health.v_health_base_chart(TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION health.v_health_base_chart(
    p_schema   TEXT,
    p_lookback TEXT DEFAULT '7 days',
    p_interval TEXT DEFAULT '1 hour'
)
RETURNS TABLE (
    bucket        TIMESTAMPTZ,
    category      TEXT,
    avg_row_count DOUBLE PRECISION
)
LANGUAGE plpgsql VOLATILE
AS $$
DECLARE
    _cutoff  timestamptz := NOW() - p_lookback::interval;
    _interval interval   := p_interval::interval;
BEGIN
    -- ── Temp tables for per-schema hourly counts ──────────────────────────
    CREATE TEMP TABLE IF NOT EXISTS _bch_events  (hour timestamptz, cnt double precision) ON COMMIT DROP;
    CREATE TEMP TABLE IF NOT EXISTS _bch_accounts (hour timestamptz, cnt double precision) ON COMMIT DROP;
    TRUNCATE _bch_events;
    TRUNCATE _bch_accounts;

    -- ── Only scan the requested schema's tables ──────────────────────────
    IF p_schema = 'dexes' THEN
        -- Transaction Events
        INSERT INTO _bch_events
        SELECT time_bucket('1 hour', time), COUNT(*)::double precision
        FROM dexes.src_tx_events WHERE time > _cutoff GROUP BY 1;

        -- Account Updates
        INSERT INTO _bch_accounts
        SELECT time_bucket('1 hour', time), COUNT(*)::double precision
        FROM dexes.src_acct_pool WHERE time > _cutoff GROUP BY 1;
        INSERT INTO _bch_accounts
        SELECT time_bucket('1 hour', time), COUNT(*)::double precision
        FROM dexes.src_acct_vaults WHERE time > _cutoff GROUP BY 1;
        INSERT INTO _bch_accounts
        SELECT time_bucket('1 hour', time), COUNT(*)::double precision
        FROM dexes.src_acct_tickarray_queries WHERE time > _cutoff GROUP BY 1;
        INSERT INTO _bch_accounts
        SELECT time_bucket('1 hour', time), COUNT(*)::double precision
        FROM dexes.src_acct_position WHERE time > _cutoff GROUP BY 1;

    ELSIF p_schema = 'exponent' THEN
        INSERT INTO _bch_events
        SELECT time_bucket('1 hour', time), COUNT(*)::double precision
        FROM exponent.src_tx_events WHERE time > _cutoff GROUP BY 1;

        INSERT INTO _bch_accounts
        SELECT time_bucket('1 hour', time), COUNT(*)::double precision
        FROM exponent.src_vaults WHERE time > _cutoff GROUP BY 1;
        INSERT INTO _bch_accounts
        SELECT time_bucket('1 hour', time), COUNT(*)::double precision
        FROM exponent.src_market_twos WHERE time > _cutoff GROUP BY 1;
        INSERT INTO _bch_accounts
        SELECT time_bucket('1 hour', time), COUNT(*)::double precision
        FROM exponent.src_sy_meta_account WHERE time > _cutoff GROUP BY 1;
        INSERT INTO _bch_accounts
        SELECT time_bucket('1 hour', time), COUNT(*)::double precision
        FROM exponent.src_sy_token_account WHERE time > _cutoff GROUP BY 1;
        INSERT INTO _bch_accounts
        SELECT time_bucket('1 hour', time), COUNT(*)::double precision
        FROM exponent.src_vault_yield_position WHERE time > _cutoff GROUP BY 1;
        INSERT INTO _bch_accounts
        SELECT time_bucket('1 hour', time), COUNT(*)::double precision
        FROM exponent.src_vault_yt_escrow WHERE time > _cutoff GROUP BY 1;
        INSERT INTO _bch_accounts
        SELECT time_bucket('1 hour', time), COUNT(*)::double precision
        FROM exponent.src_base_token_escrow WHERE time > _cutoff GROUP BY 1;

    ELSIF p_schema = 'kamino_lend' THEN
        INSERT INTO _bch_events
        SELECT time_bucket('1 hour', time), COUNT(*)::double precision
        FROM kamino_lend.src_txn_events WHERE time > _cutoff GROUP BY 1;

        INSERT INTO _bch_accounts
        SELECT time_bucket('1 hour', time), COUNT(*)::double precision
        FROM kamino_lend.src_reserves WHERE time > _cutoff GROUP BY 1;
        INSERT INTO _bch_accounts
        SELECT time_bucket('1 hour', block_time), COUNT(*)::double precision
        FROM kamino_lend.src_obligations WHERE block_time > _cutoff GROUP BY 1;
        INSERT INTO _bch_accounts
        SELECT time_bucket('1 hour', time), COUNT(*)::double precision
        FROM kamino_lend.src_obligations_agg WHERE time > _cutoff GROUP BY 1;
        INSERT INTO _bch_accounts
        SELECT time_bucket('1 hour', time), COUNT(*)::double precision
        FROM kamino_lend.src_lending_market WHERE time > _cutoff GROUP BY 1;

    END IF;

    -- ── Shared aggregation logic ─────────────────────────────────────────
    RETURN QUERY
    WITH hourly_events AS (
        SELECT e.hour, SUM(e.cnt) AS hourly_rows
        FROM _bch_events e GROUP BY 1
    ),
    hourly_accounts AS (
        SELECT a.hour, SUM(a.cnt) AS hourly_rows
        FROM _bch_accounts a GROUP BY 1
    ),
    bucketed AS (
        SELECT
            time_bucket(_interval, he.hour) AS bucket,
            'Transaction Events'::text AS category,
            AVG(he.hourly_rows) AS avg_row_count
        FROM hourly_events he
        GROUP BY 1, 2

        UNION ALL

        SELECT
            time_bucket(_interval, ha.hour),
            'Account Updates'::text,
            AVG(ha.hourly_rows)
        FROM hourly_accounts ha
        GROUP BY 1, 2
    )
    SELECT b.bucket, b.category, b.avg_row_count
    FROM bucketed b
    ORDER BY b.bucket, b.category;
END;
$$;
