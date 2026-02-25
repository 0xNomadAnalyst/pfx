-- =============================================================================
-- health.v_health_trigger_table
-- Trigger function health — checks if PostgreSQL triggers are firing correctly
-- Mirrors the Trigger Function Health table in the dashboard
--
-- OPTIMISED: replaced 8 separate subqueries on dexes.src_tx_events with
-- a single scan using FILTER aggregation (8x fewer table passes).
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

DROP VIEW IF EXISTS health.v_health_trigger_table CASCADE;
CREATE OR REPLACE VIEW health.v_health_trigger_table AS

-- Single scan of swap events with conditional aggregation
WITH swap_stats AS (
    SELECT
        -- ── 7-day window: MAX timestamps ────────────────────────────
        MAX(time) FILTER (
            WHERE protocol = 'raydium'
        ) AS raydium_swap_latest_7d,

        MAX(time) FILTER (
            WHERE protocol = 'raydium'
              AND evt_swap_pre_sqrt_price IS NOT NULL
        ) AS raydium_pre_price_latest_7d,

        MAX(time) AS all_swap_latest_7d,

        MAX(time) FILTER (
            WHERE c_swap_est_impact_bps IS NOT NULL
        ) AS impact_latest_7d,

        -- ── 1-hour window: row counts ───────────────────────────────
        COUNT(*) FILTER (
            WHERE time > NOW() - INTERVAL '1 hour'
              AND protocol = 'raydium'
        ) AS raydium_swap_1h,

        COUNT(*) FILTER (
            WHERE time > NOW() - INTERVAL '1 hour'
              AND protocol = 'raydium'
              AND evt_swap_pre_sqrt_price IS NOT NULL
        ) AS raydium_pre_price_1h,

        COUNT(*) FILTER (
            WHERE time > NOW() - INTERVAL '1 hour'
        ) AS all_swap_1h,

        COUNT(*) FILTER (
            WHERE time > NOW() - INTERVAL '1 hour'
              AND c_swap_est_impact_bps IS NOT NULL
        ) AS impact_1h

    FROM dexes.src_tx_events
    WHERE time > NOW() - INTERVAL '7 days'
      AND event_type = 'swap'
),

-- Unpivot into the trigger_checks shape
trigger_checks AS (
    -- trg_fill_raydium_pre_price (BEFORE INSERT on dexes.src_tx_events)
    -- Carries forward pre-swap sqrt price for Raydium CLMM swaps
    SELECT
        'dexes'::text AS domain,
        'trg_fill_raydium_pre_price'::text AS trigger_name,
        'Raydium swaps: evt_swap_pre_sqrt_price carry-forward'::text AS description,
        s.raydium_swap_latest_7d      AS source_latest,
        s.raydium_pre_price_latest_7d AS derived_latest,
        s.raydium_swap_1h             AS source_rows_1h,
        s.raydium_pre_price_1h        AS derived_rows_1h
    FROM swap_stats s

    UNION ALL

    -- trg_calculate_swap_impact (BEFORE INSERT on dexes.src_tx_events)
    -- Calculates estimated swap impact in bps from liquidity depth data
    SELECT
        'dexes',
        'trg_calculate_swap_impact',
        'All swaps: c_swap_est_impact_bps from liquidity depth',
        s.all_swap_latest_7d,
        s.impact_latest_7d,
        s.all_swap_1h,
        s.impact_1h
    FROM swap_stats s
)

SELECT
    domain,
    trigger_name,
    description,
    source_latest,
    derived_latest,
    source_rows_1h,
    derived_rows_1h,
    -- Lag in minutes
    EXTRACT(EPOCH FROM (source_latest - derived_latest)) / 60.0 AS lag_mins,
    -- Coverage ratio (derived / source in last hour)
    CASE WHEN source_rows_1h > 0
         THEN derived_rows_1h::float / source_rows_1h
         ELSE NULL
    END AS coverage_ratio,
    -- Status severity (0=healthy, 1=lagging, 2=low_coverage, 3=not_firing)
    CASE
        WHEN source_latest IS NULL              THEN -1  -- no source data (not actionable)
        WHEN derived_latest IS NULL             THEN 3   -- trigger not firing
        WHEN EXTRACT(EPOCH FROM (source_latest - derived_latest)) / 60.0 > 10 THEN 1  -- lagging
        WHEN source_rows_1h > 0
             AND derived_rows_1h < source_rows_1h * 0.5 THEN 2  -- low coverage
        ELSE 0  -- healthy
    END AS severity,
    -- Text status
    CASE
        WHEN source_latest IS NULL              THEN 'No source data'
        WHEN derived_latest IS NULL             THEN 'Trigger not firing'
        WHEN EXTRACT(EPOCH FROM (source_latest - derived_latest)) / 60.0 > 10 THEN 'Lagging'
        WHEN source_rows_1h > 0
             AND derived_rows_1h < source_rows_1h * 0.5 THEN 'Low coverage'
        ELSE 'Healthy'
    END AS status,
    -- Binary flag for master table (true = red; only "trigger not firing" is red)
    (source_latest IS NOT NULL AND derived_latest IS NULL) AS is_red
FROM trigger_checks
ORDER BY domain, trigger_name;
