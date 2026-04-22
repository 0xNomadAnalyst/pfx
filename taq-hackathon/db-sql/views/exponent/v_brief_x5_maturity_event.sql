-- =============================================================================
-- v_brief_x5_maturity_event — market discovery / imminent expiry (X5)
-- =============================================================================
-- Fires when either (a) a market's maturity is within X5.expiry_warning_days
-- days from now (and it has not yet expired), or (b) a market first appeared
-- in the last 24h (aux_key_relations.updated_at within the window).
--
-- Both discovery and near-expiry are structural events — rare and notable.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_x5_maturity_event AS
WITH bounds AS (
    SELECT hackathon.cfg_num('X5', 'expiry_warning_days', 7) AS warn_days
),
markets AS (
    SELECT
        akr.vault_address, akr.market_address, akr.meta_pt_name, akr.market_name,
        akr.maturity_date, akr.maturity_ts, akr.updated_at,
        akr.is_active, akr.is_expired,
        GREATEST(0, EXTRACT(EPOCH FROM (akr.maturity_date::timestamptz - now())) / 86400)::numeric AS days_to_maturity,
        CASE WHEN akr.updated_at >= now() - interval '24 hours' THEN true ELSE false END AS recently_added
    FROM exponent.aux_key_relations akr
    WHERE akr.is_active = true
),
candidates AS (
    SELECT
        m.*,
        CASE
            WHEN m.recently_added THEN 'discovered'
            WHEN m.is_expired = false
             AND m.days_to_maturity <= (SELECT warn_days FROM bounds)
             AND m.days_to_maturity > 0 THEN 'near_expiry'
            ELSE NULL
        END AS event_kind
    FROM markets m
)
SELECT
    'X5'::text                               AS item_id,
    'exponent'::text                         AS section,
    true                                     AS fired,
    now()                                    AS as_of,
    CASE c.event_kind
         WHEN 'discovered'  THEN format('New Exponent market discovered in last 24h: %s',
                                        COALESCE(c.meta_pt_name, c.market_name))
         WHEN 'near_expiry' THEN format('%s matures in %s days (on %s)',
                                        COALESCE(c.meta_pt_name, c.market_name),
                                        to_char(c.days_to_maturity, 'FM990.0'),
                                        to_char(c.maturity_date, 'YYYY-MM-DD'))
    END                                      AS headline,
    'event'::text                            AS direction,
    round(c.days_to_maturity, 1)             AS value_primary,
    'count'::text                            AS value_unit,
    NULL::numeric                            AS value_delta,
    c.market_address::text                   AS ref,
    jsonb_build_object(
        'market_address',    c.market_address,
        'vault_address',     c.vault_address,
        'pt_name',           c.meta_pt_name,
        'market_name',       c.market_name,
        'maturity_date',     c.maturity_date,
        'days_to_maturity',  c.days_to_maturity,
        'event_kind',        c.event_kind,
        'updated_at',        c.updated_at
    )                                        AS supporting
FROM candidates c
WHERE c.event_kind IS NOT NULL
ORDER BY CASE c.event_kind WHEN 'discovered' THEN 0 ELSE 1 END,
         c.days_to_maturity ASC
LIMIT 1;

COMMENT ON VIEW hackathon.v_brief_x5_maturity_event IS
  'X5 — Maturity / discovery event. Fires on either a newly-discovered market in the last 24h, or an active market within X5.expiry_warning_days of maturity.';
