-- =============================================================================
-- v_brief_e5_cross_venue_yield_spread — cross-venue yield spread (Ecosystem / E5)
-- =============================================================================
-- Fires when the spread between the highest and lowest ONyc-earning venue
-- widens or compresses by more than E5.bps_threshold vs its 7d baseline.
--
-- Venues considered (from mat_xp_last):
--   • Kamino supply APY (kam_onyc_supply_apy)   — ONyc as supplied collateral
--   • Exponent weighted implied fixed APY       — ONyc via PT tokenisation
--
-- For simplicity v1 omits DEX LP yield (not pre-computed in mat_xp_last).
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_e5_cross_venue_yield_spread AS
WITH cur AS (
    SELECT
        kam_onyc_supply_apy,
        exp_weighted_implied_apy,
        GREATEST(kam_onyc_supply_apy, exp_weighted_implied_apy)
          - LEAST(kam_onyc_supply_apy, exp_weighted_implied_apy) AS spread_now
    FROM cross_protocol.mat_xp_last
    WHERE id = 1
      AND kam_onyc_supply_apy IS NOT NULL
      AND exp_weighted_implied_apy IS NOT NULL
),
baseline AS (
    SELECT avg(
        GREATEST(kam_onyc_supply_apy, exp_weighted_implied_apy)
      - LEAST(kam_onyc_supply_apy, exp_weighted_implied_apy)
    ) AS spread_7d
    FROM cross_protocol.mat_xp_ts_1m
    WHERE bucket_time >= now() - (hackathon.cfg_num('_global', 'baseline_days', 7) || ' days')::interval
      AND bucket_time <  now() - interval '24 hours'
      AND kam_onyc_supply_apy IS NOT NULL
      AND exp_weighted_implied_apy IS NOT NULL
),
calc AS (
    SELECT
        c.kam_onyc_supply_apy,
        c.exp_weighted_implied_apy,
        c.spread_now,
        b.spread_7d,
        (c.spread_now - b.spread_7d) * 10000.0 AS spread_delta_bps
    FROM cur c, baseline b
    WHERE b.spread_7d IS NOT NULL
)
SELECT
    'E5'::text                               AS item_id,
    'ecosystem'::text                        AS section,
    true                                     AS fired,
    now()                                    AS as_of,
    format(
        'Kamino vs Exponent yield spread %s by %s bps vs 7d (now %s bps, baseline %s bps)',
        CASE WHEN c.spread_delta_bps >= 0 THEN 'widened' ELSE 'compressed' END,
        to_char(round(abs(c.spread_delta_bps), 0), 'FM990'),
        to_char(round(c.spread_now * 10000), 'FM999,999'),
        to_char(round(c.spread_7d  * 10000), 'FM999,999')
    )                                        AS headline,
    CASE WHEN c.spread_delta_bps >= 0 THEN 'up' ELSE 'down' END AS direction,
    round(c.spread_now * 10000, 0)           AS value_primary,
    'bps'::text                              AS value_unit,
    round(c.spread_delta_bps, 0)             AS value_delta,
    'kam_vs_exp'::text                       AS ref,
    jsonb_build_object(
        'kam_onyc_supply_apy',      c.kam_onyc_supply_apy,
        'exp_weighted_implied_apy', c.exp_weighted_implied_apy,
        'spread_now',               c.spread_now,
        'spread_7d',                c.spread_7d,
        'spread_delta_bps',         c.spread_delta_bps
    )                                        AS supporting
FROM calc c
WHERE abs(c.spread_delta_bps) > hackathon.cfg_num('E5', 'bps_threshold', 50);

COMMENT ON VIEW hackathon.v_brief_e5_cross_venue_yield_spread IS
  'E5 — Cross-venue yield spread. Fires when the |Kamino supply APY − Exponent implied APY| spread moved more than E5.bps_threshold vs 7d baseline.';
