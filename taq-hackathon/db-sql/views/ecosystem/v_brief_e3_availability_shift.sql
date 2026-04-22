-- =============================================================================
-- v_brief_e3_availability_shift — availability bucket shift (Ecosystem / E3)
-- =============================================================================
-- Partitions ONyc supply into three availability buckets:
--   liquid DeFi:     ONyc on DEXes (withdrawable at cost via swap)
--   illiquid DeFi:   ONyc in Kamino (collateral, may be locked) + Exponent
--   free/undeployed: everything else (inferred; not pre-computed)
--
-- The cross_protocol substrate doesn't carry a "free/undeployed" column; we
-- derive it only if the total ONyc supply is known (it is not in
-- mat_xp_last — onyc_tracked_total is just sum of venues). So E3 in v1
-- compares the liquid-vs-illiquid split between DEX (liquid) and
-- Kamino+Exponent (illiquid) and fires on material movement.
--
-- Fires when the liquid-share (of tracked ONyc) moved > E3.pp_threshold vs 7d.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_e3_availability_shift AS
WITH cur AS (
    SELECT
        onyc_in_dexes, onyc_in_kamino, onyc_in_exponent, onyc_tracked_total,
        CASE WHEN onyc_tracked_total > 0
             THEN (onyc_in_dexes / onyc_tracked_total) * 100.0
             ELSE NULL END AS liquid_pct_now
    FROM cross_protocol.mat_xp_last
    WHERE id = 1
),
baseline AS (
    SELECT
        avg(CASE WHEN onyc_tracked_total > 0
                 THEN (onyc_in_dexes / onyc_tracked_total) * 100.0
                 ELSE NULL END) AS liquid_pct_7d
    FROM cross_protocol.mat_xp_ts_1m
    WHERE bucket_time >= now() - (hackathon.cfg_num('_global', 'baseline_days', 7) || ' days')::interval
      AND bucket_time <  now() - interval '24 hours'
),
calc AS (
    SELECT
        c.liquid_pct_now,
        b.liquid_pct_7d,
        c.liquid_pct_now - b.liquid_pct_7d AS pp_change
    FROM cur c, baseline b
    WHERE c.liquid_pct_now IS NOT NULL AND b.liquid_pct_7d IS NOT NULL
)
SELECT
    'E3'::text                               AS item_id,
    'ecosystem'::text                        AS section,
    true                                     AS fired,
    now()                                    AS as_of,
    format(
        'Liquid share (DEX) of tracked ONyc shifted %s pp vs 7d baseline (%s%% → %s%%)',
        to_char(round(c.pp_change, 2), 'FMS990.00'),
        to_char(c.liquid_pct_7d,  'FM990.00'),
        to_char(c.liquid_pct_now, 'FM990.00')
    )                                        AS headline,
    CASE WHEN c.pp_change >= 0 THEN 'up' ELSE 'down' END AS direction,
    round(c.liquid_pct_now, 2)               AS value_primary,
    'pp'::text                               AS value_unit,
    round(c.pp_change, 2)                    AS value_delta,
    'liquid'::text                           AS ref,
    jsonb_build_object(
        'liquid_pct_now',  c.liquid_pct_now,
        'liquid_pct_7d',   c.liquid_pct_7d,
        'pp_change',       c.pp_change
    )                                        AS supporting
FROM calc c
WHERE abs(c.pp_change) > hackathon.cfg_num('E3', 'pp_threshold', 3);

COMMENT ON VIEW hackathon.v_brief_e3_availability_shift IS
  'E3 — Availability shift. Fires when the DEX-liquid share of tracked ONyc moved more than E3.pp_threshold (percentage points) vs 7d baseline.';
