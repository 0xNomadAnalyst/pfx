-- =============================================================================
-- v_brief_e1_supply_composition — supply composition shift (Ecosystem / E1)
-- =============================================================================
-- Fires when the share of ONyc across deployment forms (DEXes / Kamino /
-- Exponent) has shifted materially. Here we use venue shares from
-- cross_protocol.mat_xp_last and mat_xp_ts_1m (7d baseline).
--
-- "Supply composition" in the ONyc ecosystem is effectively the venue
-- distribution — there is no separate "unwrapped / SY / PT+YT" cut at the
-- ecosystem level in cross_protocol, so E1 captures the largest share shift
-- across {dexes, kamino, exponent} shares.
--
-- Returns at most one row — the venue with the largest absolute shift.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_e1_supply_composition AS
WITH cur AS (
    SELECT
        onyc_in_dexes_pct    AS dexes_pct_now,
        onyc_in_kamino_pct   AS kamino_pct_now,
        onyc_in_exponent_pct AS exponent_pct_now,
        onyc_tracked_total
    FROM cross_protocol.mat_xp_last
    WHERE id = 1
),
baseline AS (
    SELECT
        avg(onyc_in_dexes_pct)    AS dexes_pct_7d,
        avg(onyc_in_kamino_pct)   AS kamino_pct_7d,
        avg(onyc_in_exponent_pct) AS exponent_pct_7d
    FROM cross_protocol.mat_xp_ts_1m
    WHERE bucket_time >= now() - (hackathon.cfg_num('_global', 'baseline_days', 7) || ' days')::interval
      AND bucket_time <  now() - interval '24 hours'
),
shifts AS (
    SELECT venue, now_pct, baseline_pct, pp_change
    FROM (
        SELECT 'dexes'    AS venue, c.dexes_pct_now    AS now_pct, b.dexes_pct_7d    AS baseline_pct,
               c.dexes_pct_now    - b.dexes_pct_7d    AS pp_change FROM cur c, baseline b
        UNION ALL
        SELECT 'kamino',          c.kamino_pct_now,          b.kamino_pct_7d,
               c.kamino_pct_now   - b.kamino_pct_7d        FROM cur c, baseline b
        UNION ALL
        SELECT 'exponent',        c.exponent_pct_now,        b.exponent_pct_7d,
               c.exponent_pct_now - b.exponent_pct_7d      FROM cur c, baseline b
    ) x
)
SELECT
    'E1'::text                               AS item_id,
    'ecosystem'::text                        AS section,
    true                                     AS fired,
    now()                                    AS as_of,
    format(
        'ONyc supply share on %s shifted %s pp vs 7d baseline (%s%% → %s%%)',
        s.venue,
        to_char(round(s.pp_change, 2), 'FMS990.00'),
        to_char(s.baseline_pct, 'FM990.00'),
        to_char(s.now_pct,      'FM990.00')
    )                                        AS headline,
    CASE WHEN s.pp_change >= 0 THEN 'up' ELSE 'down' END AS direction,
    round(s.now_pct, 2)                      AS value_primary,
    'pp'::text                               AS value_unit,
    round(s.pp_change, 2)                    AS value_delta,
    s.venue::text                            AS ref,
    jsonb_build_object(
        'venue',         s.venue,
        'now_pct',       s.now_pct,
        'baseline_pct',  s.baseline_pct,
        'pp_change',     s.pp_change
    )                                        AS supporting
FROM shifts s
WHERE abs(s.pp_change) > hackathon.cfg_num('E1', 'pp_threshold', 2)
ORDER BY abs(s.pp_change) DESC
LIMIT 1;

COMMENT ON VIEW hackathon.v_brief_e1_supply_composition IS
  'E1 — Supply composition shift. Fires when ONyc share on any venue (DEXes / Kamino / Exponent) moved more than E1.pp_threshold (percentage points) vs 7d baseline.';
