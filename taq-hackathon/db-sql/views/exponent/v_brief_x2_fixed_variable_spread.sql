-- =============================================================================
-- v_brief_x2_fixed_variable_spread — fixed-variable rate spread (Exponent / X2)
-- =============================================================================
-- Fires when the spread between implied PT fixed APY and the realised
-- underlying variable yield (sy_trailing_apy_24h) changed more than
-- X2.bps_threshold vs 24h ago.
--
-- Spread sign convention: positive means fixed > variable (positive carry for
-- PT holders); negative means fixed < variable (market expects higher future
-- yield).
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_x2_fixed_variable_spread AS
WITH cur AS (
    SELECT
        vault_address, market_address, meta_pt_name,
        c_market_implied_apy, sy_trailing_apy_24h, is_expired
    FROM exponent.mat_exp_last
    WHERE c_market_implied_apy IS NOT NULL
      AND sy_trailing_apy_24h IS NOT NULL
      AND is_expired = false
),
prior AS (
    -- mat_exp_timeseries_1m does not carry sy_trailing_apy_*. We approximate
    -- the prior variable rate as the current sy_trailing_apy_24h (stable
    -- assumption — SY APYs are trailing averages that move slowly). Prior
    -- fixed rate is the market's implied APY at the 24h-ago bucket.
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
        (cur.c_market_implied_apy - cur.sy_trailing_apy_24h)        AS spread_now,
        (prior.implied_apy_prior   - cur.sy_trailing_apy_24h)        AS spread_prior,
        ((cur.c_market_implied_apy - prior.implied_apy_prior) * 10000.0) AS spread_delta_bps
    FROM cur JOIN prior USING (market_address)
)
SELECT
    'X2'::text                               AS item_id,
    'exponent'::text                         AS section,
    true                                     AS fired,
    now()                                    AS as_of,
    format(
        '%s fixed-variable spread %s %s bps over 24h (%s → %s)',
        c.meta_pt_name,
        CASE WHEN c.spread_delta_bps >= 0 THEN 'widened' ELSE 'narrowed' END,
        to_char(round(abs(c.spread_delta_bps), 0), 'FM990'),
        to_char(c.spread_prior * 100, 'FMS990.00') || '%',
        to_char(c.spread_now   * 100, 'FMS990.00') || '%'
    )                                        AS headline,
    CASE WHEN c.spread_delta_bps >= 0 THEN 'up' ELSE 'down' END AS direction,
    round(c.spread_now * 10000, 0)           AS value_primary,
    'bps'::text                              AS value_unit,
    round(c.spread_delta_bps, 0)             AS value_delta,
    c.market_address::text                   AS ref,
    jsonb_build_object(
        'vault_address',     c.vault_address,
        'market_address',    c.market_address,
        'pt_name',           c.meta_pt_name,
        'spread_now',        c.spread_now,
        'spread_prior',      c.spread_prior,
        'spread_delta_bps',  c.spread_delta_bps
    )                                        AS supporting
FROM calc c
WHERE abs(c.spread_delta_bps) > hackathon.cfg_num('X2', 'bps_threshold', 40)
ORDER BY abs(c.spread_delta_bps) DESC
LIMIT 1;

COMMENT ON VIEW hackathon.v_brief_x2_fixed_variable_spread IS
  'X2 — Fixed-variable rate spread. Fires when (implied fixed APY − sy_trailing_apy_24h) changed more than X2.bps_threshold vs 24h ago.';
