-- =============================================================================
-- mat_health_trigger_stats
-- Pre-computes trigger function health metrics from dexes.src_tx_events.
-- Eliminates a full 7-day scan of src_tx_events (potentially millions of
-- swap rows) on every request to v_health_trigger_table.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

CREATE TABLE IF NOT EXISTS health.mat_health_trigger_stats (
    trigger_key                  TEXT PRIMARY KEY,
    domain                       TEXT NOT NULL,
    trigger_name                 TEXT NOT NULL,
    description                  TEXT,
    source_latest                TIMESTAMPTZ,
    derived_latest               TIMESTAMPTZ,
    source_rows_1h               BIGINT,
    derived_rows_1h              BIGINT,
    refreshed_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE health.refresh_mat_health_trigger_stats()
LANGUAGE plpgsql AS $$
DECLARE
    _raydium_swap_latest_7d TIMESTAMPTZ;
    _raydium_pre_price_latest_7d TIMESTAMPTZ;
    _all_swap_latest_7d TIMESTAMPTZ;
    _impact_latest_7d TIMESTAMPTZ;
    _raydium_swap_1h BIGINT;
    _raydium_pre_price_1h BIGINT;
    _all_swap_1h BIGINT;
    _impact_1h BIGINT;
BEGIN
    SELECT
        MAX(time) FILTER (WHERE protocol = 'raydium'),
        MAX(time) FILTER (WHERE protocol = 'raydium' AND evt_swap_pre_sqrt_price IS NOT NULL),
        MAX(time),
        MAX(time) FILTER (WHERE c_swap_est_impact_bps IS NOT NULL),
        COUNT(*) FILTER (WHERE time > NOW() - INTERVAL '1 hour' AND protocol = 'raydium'),
        COUNT(*) FILTER (WHERE time > NOW() - INTERVAL '1 hour' AND protocol = 'raydium' AND evt_swap_pre_sqrt_price IS NOT NULL),
        COUNT(*) FILTER (WHERE time > NOW() - INTERVAL '1 hour'),
        COUNT(*) FILTER (WHERE time > NOW() - INTERVAL '1 hour' AND c_swap_est_impact_bps IS NOT NULL)
    INTO
        _raydium_swap_latest_7d, _raydium_pre_price_latest_7d,
        _all_swap_latest_7d, _impact_latest_7d,
        _raydium_swap_1h, _raydium_pre_price_1h,
        _all_swap_1h, _impact_1h
    FROM dexes.src_tx_events
    WHERE time > NOW() - INTERVAL '7 days'
      AND event_type = 'swap';

    INSERT INTO health.mat_health_trigger_stats
        (trigger_key, domain, trigger_name, description,
         source_latest, derived_latest, source_rows_1h, derived_rows_1h, refreshed_at)
    VALUES
        ('dexes.trg_fill_raydium_pre_price',
         'dexes', 'trg_fill_raydium_pre_price',
         'Raydium swaps: evt_swap_pre_sqrt_price carry-forward',
         _raydium_swap_latest_7d, _raydium_pre_price_latest_7d,
         _raydium_swap_1h, _raydium_pre_price_1h, NOW()),
        ('dexes.trg_calculate_swap_impact',
         'dexes', 'trg_calculate_swap_impact',
         'All swaps: c_swap_est_impact_bps from liquidity depth',
         _all_swap_latest_7d, _impact_latest_7d,
         _all_swap_1h, _impact_1h, NOW())
    ON CONFLICT (trigger_key) DO UPDATE SET
        source_latest   = EXCLUDED.source_latest,
        derived_latest  = EXCLUDED.derived_latest,
        source_rows_1h  = EXCLUDED.source_rows_1h,
        derived_rows_1h = EXCLUDED.derived_rows_1h,
        refreshed_at    = NOW();
END;
$$;
