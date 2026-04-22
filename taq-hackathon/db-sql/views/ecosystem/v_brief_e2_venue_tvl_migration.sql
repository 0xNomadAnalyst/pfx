-- =============================================================================
-- v_brief_e2_venue_tvl_migration — venue TVL migration (Ecosystem / E2)
-- =============================================================================
-- Similar to E1 but about absolute ONyc amounts, not shares. Fires when ONyc
-- at any venue moved > E2.pct_threshold vs 7d baseline.
--
-- E1 captures share-of-pie shifts; E2 captures absolute flow shifts. A
-- simultaneous E1+E2 on the same venue means "both absolute and share moved";
-- a lone E1 means "other venues grew/shrank proportionally too."
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_e2_venue_tvl_migration AS
WITH cur AS (
    SELECT
        onyc_in_dexes, onyc_in_kamino, onyc_in_exponent, onyc_tracked_total
    FROM cross_protocol.mat_xp_last
    WHERE id = 1
),
baseline AS (
    SELECT
        avg(onyc_in_dexes)    AS dexes_7d,
        avg(onyc_in_kamino)   AS kamino_7d,
        avg(onyc_in_exponent) AS exponent_7d
    FROM cross_protocol.mat_xp_ts_1m
    WHERE bucket_time >= now() - (hackathon.cfg_num('_global', 'baseline_days', 7) || ' days')::interval
      AND bucket_time <  now() - interval '24 hours'
),
shifts AS (
    SELECT venue, now_amt, baseline_amt, pct_change
    FROM (
        SELECT 'dexes' AS venue, c.onyc_in_dexes AS now_amt, b.dexes_7d AS baseline_amt,
               ((c.onyc_in_dexes - b.dexes_7d) / NULLIF(b.dexes_7d, 0)) * 100.0 AS pct_change
               FROM cur c, baseline b
        UNION ALL
        SELECT 'kamino', c.onyc_in_kamino, b.kamino_7d,
               ((c.onyc_in_kamino - b.kamino_7d) / NULLIF(b.kamino_7d, 0)) * 100.0
               FROM cur c, baseline b
        UNION ALL
        SELECT 'exponent', c.onyc_in_exponent, b.exponent_7d,
               ((c.onyc_in_exponent - b.exponent_7d) / NULLIF(b.exponent_7d, 0)) * 100.0
               FROM cur c, baseline b
    ) x
    WHERE baseline_amt IS NOT NULL
      AND baseline_amt > 0
)
SELECT
    'E2'::text                               AS item_id,
    'ecosystem'::text                        AS section,
    true                                     AS fired,
    now()                                    AS as_of,
    format(
        'ONyc on %s moved %s%% vs 7d baseline (%s → %s ONyc)',
        s.venue,
        to_char(round(s.pct_change, 1), 'FMS9,999,990.0'),
        to_char(round(s.baseline_amt), 'FM999,999,999'),
        to_char(round(s.now_amt),      'FM999,999,999')
    )                                        AS headline,
    CASE WHEN s.pct_change >= 0 THEN 'in' ELSE 'out' END AS direction,
    round(s.now_amt, 0)                      AS value_primary,
    'onyc'::text                             AS value_unit,
    round(s.now_amt - s.baseline_amt, 0)     AS value_delta,
    s.venue::text                            AS ref,
    jsonb_build_object(
        'venue',        s.venue,
        'now_amt',      s.now_amt,
        'baseline_amt', s.baseline_amt,
        'pct_change',   s.pct_change
    )                                        AS supporting
FROM shifts s
WHERE abs(s.pct_change) > hackathon.cfg_num('E2', 'pct_threshold', 5)
ORDER BY abs(s.pct_change) DESC
LIMIT 1;

COMMENT ON VIEW hackathon.v_brief_e2_venue_tvl_migration IS
  'E2 — Venue TVL migration. Fires when the absolute ONyc amount held at any venue moved more than E2.pct_threshold vs 7d baseline.';
