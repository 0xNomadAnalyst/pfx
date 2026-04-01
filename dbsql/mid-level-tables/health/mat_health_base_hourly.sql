-- =============================================================================
-- mat_health_base_hourly
-- Pre-computes hourly row counts per base table, categorised as
-- 'Transaction Events' or 'Account Updates'. Supports v_health_base_chart
-- by eliminating multi-table scans at query time.
--
-- Retains 8 days of hourly data (7-day chart lookback + 1-day buffer).
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

CREATE TABLE IF NOT EXISTS health.mat_health_base_hourly (
    schema_name  TEXT        NOT NULL,
    category     TEXT        NOT NULL,  -- 'Transaction Events' or 'Account Updates'
    table_name   TEXT        NOT NULL,
    hour         TIMESTAMPTZ NOT NULL,
    row_count    BIGINT      NOT NULL DEFAULT 0,
    refreshed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

SELECT create_hypertable(
    'health.mat_health_base_hourly', 'hour',
    if_not_exists => TRUE,
    chunk_time_interval => INTERVAL '1 day'
);

CREATE INDEX IF NOT EXISTS idx_mat_health_base_hourly_lookup
    ON health.mat_health_base_hourly (schema_name, category, hour DESC);

-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE health.refresh_mat_health_base_hourly()
LANGUAGE plpgsql AS $$
DECLARE
    _tbl    RECORD;
    _cutoff TIMESTAMPTZ := NOW() - INTERVAL '8 days';
    _from   TIMESTAMPTZ := NOW() - INTERVAL '2 hours';
BEGIN
    SET LOCAL work_mem = '32MB';

    DELETE FROM health.mat_health_base_hourly WHERE hour >= _from;

    -- Retention: drop data older than 8 days
    DELETE FROM health.mat_health_base_hourly WHERE hour < _cutoff;

    FOR _tbl IN
        SELECT * FROM (VALUES
            -- Dexes
            ('dexes', 'Transaction Events', 'src_tx_events',            'time'),
            ('dexes', 'Account Updates',    'src_acct_pool',            'time'),
            ('dexes', 'Account Updates',    'src_acct_vaults',          'time'),
            ('dexes', 'Account Updates',    'src_acct_tickarray_queries','time'),
            ('dexes', 'Account Updates',    'src_acct_position',        'time'),
            -- Exponent
            ('exponent', 'Transaction Events', 'src_tx_events',         'time'),
            ('exponent', 'Account Updates',    'src_vaults',            'time'),
            ('exponent', 'Account Updates',    'src_market_twos',       'time'),
            ('exponent', 'Account Updates',    'src_sy_meta_account',   'time'),
            ('exponent', 'Account Updates',    'src_sy_token_account',  'time'),
            ('exponent', 'Account Updates',    'src_vault_yield_position','time'),
            ('exponent', 'Account Updates',    'src_vault_yt_escrow',   'time'),
            ('exponent', 'Account Updates',    'src_base_token_escrow', 'time'),
            -- Kamino
            ('kamino_lend', 'Transaction Events', 'src_txn_events',     'time'),
            ('kamino_lend', 'Account Updates',    'src_reserves',       'time'),
            ('kamino_lend', 'Account Updates',    'src_obligations',    'block_time'),
            ('kamino_lend', 'Account Updates',    'src_obligations_agg','time'),
            ('kamino_lend', 'Account Updates',    'src_lending_market', 'time')
        ) AS t(s, cat, tbl, tcol)
    LOOP
        BEGIN
            EXECUTE format(
                $q$INSERT INTO health.mat_health_base_hourly
                       (schema_name, category, table_name, hour, row_count, refreshed_at)
                   SELECT %L, %L, %L,
                          time_bucket('1 hour', %I), COUNT(*), NOW()
                   FROM %I.%I
                   WHERE %I >= %L
                   GROUP BY time_bucket('1 hour', %I)$q$,
                _tbl.s, _tbl.cat, _tbl.tbl,
                _tbl.tcol,
                _tbl.s, _tbl.tbl,
                _tbl.tcol, _from,
                _tbl.tcol
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'base_hourly: %.% failed: %', _tbl.s, _tbl.tbl, SQLERRM;
            CONTINUE;
        END;
    END LOOP;
END;
$$;
