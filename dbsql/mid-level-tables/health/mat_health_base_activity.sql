-- =============================================================================
-- mat_health_base_activity
-- Pre-computes per-table ingestion health stats (latest time, row counts,
-- frequency-based expected gap). Replaces 21 separate live table scans per
-- request to v_health_base_table with a single table read.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

CREATE TABLE IF NOT EXISTS health.mat_health_base_activity (
    schema_name        TEXT NOT NULL,
    table_name         TEXT NOT NULL,
    latest_time        TIMESTAMPTZ,
    minutes_since_latest DOUBLE PRECISION,
    rows_last_hour     BIGINT,
    rows_last_24h      BIGINT,
    avg_rows_per_hour  DOUBLE PRECISION,
    sample_count       BIGINT,
    expected_gap_mins  DOUBLE PRECISION,
    gap_ratio          DOUBLE PRECISION,
    refreshed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (schema_name, table_name)
);

-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE health.refresh_mat_health_base_activity()
LANGUAGE plpgsql AS $$
DECLARE
    _tbl    RECORD;
    _latest TIMESTAMPTZ;
    _c1h    BIGINT;
    _c24h   BIGINT;
    _c7d    BIGINT;
    _msl    DOUBLE PRECISION;
    _egm    DOUBLE PRECISION;
    _gr     DOUBLE PRECISION;
BEGIN
    FOR _tbl IN
        SELECT * FROM (VALUES
            ('dexes','src_acct_pool','time'),
            ('dexes','src_acct_vaults','time'),
            ('dexes','src_tx_events','time'),
            ('dexes','src_transactions','time'),
            ('dexes','src_acct_tickarray_queries','time'),
            ('dexes','src_acct_position','time'),
            ('kamino_lend','src_reserves','time'),
            ('kamino_lend','src_obligations','block_time'),
            ('kamino_lend','src_obligations_agg','time'),
            ('kamino_lend','src_lending_market','time'),
            ('kamino_lend','src_txn','time'),
            ('kamino_lend','src_txn_events','time'),
            ('exponent','src_vaults','time'),
            ('exponent','src_market_twos','time'),
            ('exponent','src_sy_meta_account','time'),
            ('exponent','src_sy_token_account','time'),
            ('exponent','src_vault_yield_position','time'),
            ('exponent','src_vault_yt_escrow','time'),
            ('exponent','src_base_token_escrow','time'),
            ('exponent','src_tx_events','time'),
            ('exponent','src_txns','time')
        ) AS t(s, tbl, tcol)
    LOOP
        BEGIN
            EXECUTE format(
                $q$SELECT
                    (SELECT MAX(%I) FROM %I.%I),
                    (SELECT COUNT(*) FROM %I.%I WHERE %I > NOW() - INTERVAL '1 hour'),
                    (SELECT COUNT(*) FROM %I.%I WHERE %I > NOW() - INTERVAL '24 hours')$q$,
                _tbl.tcol, _tbl.s, _tbl.tbl,
                _tbl.s, _tbl.tbl, _tbl.tcol,
                _tbl.s, _tbl.tbl, _tbl.tcol
            ) INTO _latest, _c1h, _c24h;

            IF _latest IS NULL THEN CONTINUE; END IF;

            EXECUTE format(
                $q$SELECT COUNT(DISTINCT time_bucket('1 hour', %I))
                   FROM %I.%I WHERE %I > NOW() - INTERVAL '7 days'$q$,
                _tbl.tcol, _tbl.s, _tbl.tbl, _tbl.tcol
            ) INTO _c7d;

            _msl := EXTRACT(EPOCH FROM (NOW() - _latest)) / 60.0;
            _egm := CASE WHEN COALESCE(_c7d, 0) > 0
                         THEN (168.0 * 60.0) / _c7d ELSE NULL END;
            _gr  := CASE WHEN _egm IS NOT NULL AND _egm > 0
                         THEN _msl / _egm ELSE NULL END;

            INSERT INTO health.mat_health_base_activity
                (schema_name, table_name, latest_time, minutes_since_latest,
                 rows_last_hour, rows_last_24h, avg_rows_per_hour,
                 sample_count, expected_gap_mins, gap_ratio, refreshed_at)
            VALUES
                (_tbl.s, _tbl.tbl, _latest, _msl,
                 _c1h, _c24h, _c24h / 24.0,
                 _c7d, _egm, _gr, NOW())
            ON CONFLICT (schema_name, table_name) DO UPDATE SET
                latest_time        = EXCLUDED.latest_time,
                minutes_since_latest = EXCLUDED.minutes_since_latest,
                rows_last_hour     = EXCLUDED.rows_last_hour,
                rows_last_24h      = EXCLUDED.rows_last_24h,
                avg_rows_per_hour  = EXCLUDED.avg_rows_per_hour,
                sample_count       = EXCLUDED.sample_count,
                expected_gap_mins  = EXCLUDED.expected_gap_mins,
                gap_ratio          = EXCLUDED.gap_ratio,
                refreshed_at       = NOW();
        EXCEPTION WHEN undefined_table THEN
            CONTINUE;
        END;
    END LOOP;
END;
$$;
