-- =============================================================================
-- v_brief_e4_activity_rotation — activity rotation (Ecosystem / E4)
-- =============================================================================
-- Fires when the 24h activity-share distribution across venues deviates
-- materially from the 7d mean. Uses the `*_volume_pct` columns from
-- cross_protocol.mat_xp_ts_1m as the share series.
--
-- For each venue, compute 24h average share and its 7d baseline (mean, stddev)
-- across the trailing 7d (excluding the last 24h). Fire if any venue's 24h
-- average deviates from baseline by more than E4.zscore_threshold standard
-- deviations.
--
-- Returns at most one row — the venue with the largest |z|.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_e4_activity_rotation AS
WITH last_24h AS (
    SELECT
        avg(dex_volume_pct) AS dex_pct_24h,
        avg(kam_volume_pct) AS kam_pct_24h,
        avg(exp_volume_pct) AS exp_pct_24h
    FROM cross_protocol.mat_xp_ts_1m
    WHERE bucket_time >= now() - interval '24 hours'
),
baseline AS (
    SELECT
        avg(dex_volume_pct) AS dex_mean, stddev_samp(dex_volume_pct) AS dex_std,
        avg(kam_volume_pct) AS kam_mean, stddev_samp(kam_volume_pct) AS kam_std,
        avg(exp_volume_pct) AS exp_mean, stddev_samp(exp_volume_pct) AS exp_std
    FROM cross_protocol.mat_xp_ts_1m
    WHERE bucket_time >= now() - (hackathon.cfg_num('_global', 'baseline_days', 7) || ' days')::interval
      AND bucket_time <  now() - interval '24 hours'
),
zscores AS (
    SELECT venue, pct_24h, mean_7d, std_7d,
           CASE WHEN std_7d > 0 THEN (pct_24h - mean_7d) / std_7d ELSE NULL END AS z
    FROM (
        SELECT 'dexes'    AS venue, l.dex_pct_24h AS pct_24h, b.dex_mean AS mean_7d, b.dex_std AS std_7d FROM last_24h l, baseline b
        UNION ALL
        SELECT 'kamino',         l.kam_pct_24h,         b.kam_mean,         b.kam_std         FROM last_24h l, baseline b
        UNION ALL
        SELECT 'exponent',       l.exp_pct_24h,         b.exp_mean,         b.exp_std         FROM last_24h l, baseline b
    ) x
    WHERE pct_24h IS NOT NULL AND mean_7d IS NOT NULL
)
SELECT
    'E4'::text                               AS item_id,
    'ecosystem'::text                        AS section,
    true                                     AS fired,
    now()                                    AS as_of,
    format(
        'Activity on %s is %s vs 7d norm (24h share %s%%, baseline %s%%, z=%s)',
        z.venue,
        CASE WHEN z.z > 0 THEN 'elevated' ELSE 'below average' END,
        to_char(z.pct_24h, 'FM990.00'),
        to_char(z.mean_7d, 'FM990.00'),
        to_char(round(z.z, 2), 'FMS990.00')
    )                                        AS headline,
    CASE WHEN z.z >= 0 THEN 'up' ELSE 'down' END AS direction,
    round(z.pct_24h, 2)                      AS value_primary,
    'pct'::text                              AS value_unit,
    round(z.z, 2)                            AS value_delta,
    z.venue::text                            AS ref,
    jsonb_build_object(
        'venue',    z.venue,
        'pct_24h',  z.pct_24h,
        'mean_7d',  z.mean_7d,
        'std_7d',   z.std_7d,
        'zscore',   z.z
    )                                        AS supporting
FROM zscores z
WHERE abs(z.z) > hackathon.cfg_num('E4', 'zscore_threshold', 2)
ORDER BY abs(z.z) DESC
LIMIT 1;

COMMENT ON VIEW hackathon.v_brief_e4_activity_rotation IS
  'E4 — Activity rotation. Fires when any venue''s 24h activity share deviates from its 7d mean by more than E4.zscore_threshold standard deviations.';
