-- =============================================================================
-- v_brief_k1_zone_transition — utilisation zone transition (Kamino / K1)
-- =============================================================================
-- Fires when any tracked reserve crossed a utilisation zone boundary in the
-- 24h window. Zones are defined by configurable percent thresholds:
--   normal:     utilisation <  K1.zone_stressed_from_pct
--   stressed:   utilisation in [stressed, critical)
--   critical:   utilisation >= K1.zone_critical_from_pct
--
-- Returns at most one row — the most severe transition (direction of travel
-- preferred toward critical).
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_k1_zone_transition AS
WITH bounds AS (
    SELECT
        hackathon.cfg_num('K1', 'zone_stressed_from_pct', 70) AS stressed_from,
        hackathon.cfg_num('K1', 'zone_critical_from_pct', 90) AS critical_from
),
cur AS (
    SELECT
        reserve_address, symbol, market_address,
        utilization_ratio * 100.0 AS util_now_pct
    FROM kamino_lend.mat_klend_last_reserves
    WHERE utilization_ratio IS NOT NULL
),
prior AS (
    SELECT DISTINCT ON (reserve_address)
        reserve_address,
        utilization_ratio * 100.0 AS util_prior_pct
    FROM kamino_lend.mat_klend_reserve_ts_1m
    WHERE bucket_time BETWEEN now() - interval '24 hours 5 minutes'
                          AND now() - interval '23 hours 55 minutes'
      AND utilization_ratio IS NOT NULL
    ORDER BY reserve_address, bucket_time DESC
),
calc AS (
    SELECT
        cur.reserve_address,
        cur.symbol,
        cur.market_address,
        cur.util_now_pct,
        prior.util_prior_pct,
        b.stressed_from,
        b.critical_from,
        CASE WHEN cur.util_now_pct >= b.critical_from THEN 'critical'
             WHEN cur.util_now_pct >= b.stressed_from THEN 'stressed'
             ELSE 'normal' END AS zone_now,
        CASE WHEN prior.util_prior_pct >= b.critical_from THEN 'critical'
             WHEN prior.util_prior_pct >= b.stressed_from THEN 'stressed'
             ELSE 'normal' END AS zone_prior
    FROM cur
    LEFT JOIN prior USING (reserve_address)
    CROSS JOIN bounds b
    WHERE prior.util_prior_pct IS NOT NULL
)
SELECT
    'K1'::text                               AS item_id,
    'kamino'::text                           AS section,
    true                                     AS fired,
    now()                                    AS as_of,
    format(
        '%s reserve crossed %s → %s over 24h (utilisation %s%% → %s%%)',
        c.symbol,
        c.zone_prior,
        c.zone_now,
        to_char(c.util_prior_pct, 'FM990.0'),
        to_char(c.util_now_pct,   'FM990.0')
    )                                        AS headline,
    CASE WHEN c.util_now_pct > c.util_prior_pct THEN 'up' ELSE 'down' END AS direction,
    round(c.util_now_pct, 1)                 AS value_primary,
    'pct'::text                              AS value_unit,
    round(c.util_now_pct - c.util_prior_pct, 1) AS value_delta,
    c.symbol::text                           AS ref,
    jsonb_build_object(
        'reserve_address', c.reserve_address,
        'symbol',          c.symbol,
        'market_address',  c.market_address,
        'zone_prior',      c.zone_prior,
        'zone_now',        c.zone_now,
        'util_now_pct',    c.util_now_pct,
        'util_prior_pct',  c.util_prior_pct
    )                                        AS supporting
FROM calc c
WHERE c.zone_now IS DISTINCT FROM c.zone_prior
ORDER BY CASE c.zone_now WHEN 'critical' THEN 0 WHEN 'stressed' THEN 1 ELSE 2 END,
         abs(c.util_now_pct - c.util_prior_pct) DESC
LIMIT 1;

COMMENT ON VIEW hackathon.v_brief_k1_zone_transition IS
  'K1 — Utilisation zone transition. Fires when any tracked Kamino reserve crossed a zone boundary (normal/stressed/critical) in the 24h window. Bounds configured via hackathon.brief_config K1 keys.';
