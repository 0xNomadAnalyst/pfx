-- =============================================================================
-- v_brief_x1_fixed_rate_move — implied PT fixed APY move (Exponent / X1)
-- =============================================================================
-- Fires when any active PT market's implied fixed APY moved more than
-- X1.bps_threshold vs 24h ago.
--
-- Reads mat_exp_last.c_market_implied_apy (current) and the closest
-- mat_exp_timeseries_1m bucket at ~24h ago.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_x1_fixed_rate_move AS
WITH cur AS (
    SELECT
        vault_address,
        market_address,
        meta_pt_name,
        c_market_implied_apy,
        is_expired,
        maturity_ts
    FROM exponent.mat_exp_last
    WHERE c_market_implied_apy IS NOT NULL
      AND is_expired = false
),
prior AS (
    SELECT DISTINCT ON (market_address)
        market_address,
        c_market_implied_apy AS implied_apy_prior
    FROM exponent.mat_exp_timeseries_1m
    WHERE bucket_time BETWEEN now() - interval '24 hours 5 minutes'
                          AND now() - interval '23 hours 55 minutes'
      AND c_market_implied_apy IS NOT NULL
    ORDER BY market_address, bucket_time DESC
),
calc AS (
    SELECT
        cur.vault_address, cur.market_address, cur.meta_pt_name,
        (cur.c_market_implied_apy * 100.0)       AS implied_apy_now_pct,
        (prior.implied_apy_prior * 100.0)        AS implied_apy_prior_pct,
        (cur.c_market_implied_apy - prior.implied_apy_prior) * 10000.0 AS delta_bps
    FROM cur JOIN prior USING (market_address)
)
SELECT
    'X1'::text                               AS item_id,
    'exponent'::text                         AS section,
    true                                     AS fired,
    now()                                    AS as_of,
    format(
        '%s implied fixed APY moved %s bps over 24h (%s%% → %s%%)',
        c.meta_pt_name,
        to_char(round(c.delta_bps, 0), 'FMS990'),
        to_char(c.implied_apy_prior_pct, 'FM990.00'),
        to_char(c.implied_apy_now_pct,   'FM990.00')
    )                                        AS headline,
    CASE WHEN c.delta_bps > 0 THEN 'up' ELSE 'down' END AS direction,
    round(c.delta_bps, 0)                    AS value_primary,
    'bps'::text                              AS value_unit,
    round(c.delta_bps, 0)                    AS value_delta,
    c.market_address::text                   AS ref,
    jsonb_build_object(
        'vault_address',         c.vault_address,
        'market_address',        c.market_address,
        'pt_name',               c.meta_pt_name,
        'implied_apy_now_pct',   c.implied_apy_now_pct,
        'implied_apy_prior_pct', c.implied_apy_prior_pct,
        'delta_bps',             c.delta_bps
    )                                        AS supporting
FROM calc c
WHERE abs(c.delta_bps) > hackathon.cfg_num('X1', 'bps_threshold', 40)
ORDER BY abs(c.delta_bps) DESC
LIMIT 1;

COMMENT ON VIEW hackathon.v_brief_x1_fixed_rate_move IS
  'X1 — Fixed rate movement. Fires when any active Exponent market''s implied PT fixed APY moved more than X1.bps_threshold vs 24h ago.';
