-- =============================================================================
-- v_brief_k3_borrow_apy_move — borrow APY move (Kamino / K3)
-- =============================================================================
-- Fires when any tracked reserve's borrow APY moved more than K3.apy_bps_threshold
-- (bps) vs 24h ago. Reads mat_klend_last_reserves for current and
-- mat_klend_reserve_ts_1m for the 24h-ago bucket.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_k3_borrow_apy_move AS
WITH cur AS (
    SELECT
        reserve_address, symbol,
        borrow_apy * 100.0 AS apy_now_pct   -- borrow_apy is a ratio (0..1)
    FROM kamino_lend.mat_klend_last_reserves
    WHERE borrow_apy IS NOT NULL
),
prior AS (
    SELECT DISTINCT ON (reserve_address)
        reserve_address,
        borrow_apy * 100.0 AS apy_prior_pct
    FROM kamino_lend.mat_klend_reserve_ts_1m
    WHERE bucket_time BETWEEN now() - interval '24 hours 5 minutes'
                          AND now() - interval '23 hours 55 minutes'
      AND borrow_apy IS NOT NULL
    ORDER BY reserve_address, bucket_time DESC
),
calc AS (
    SELECT
        cur.reserve_address,
        cur.symbol,
        cur.apy_now_pct,
        prior.apy_prior_pct,
        (cur.apy_now_pct - prior.apy_prior_pct) * 100.0 AS delta_bps
    FROM cur JOIN prior USING (reserve_address)
)
SELECT
    'K3'::text                               AS item_id,
    'kamino'::text                           AS section,
    true                                     AS fired,
    now()                                    AS as_of,
    format(
        '%s borrow APY moved %s bps over 24h (%s%% → %s%%)',
        c.symbol,
        to_char(round(c.delta_bps, 0), 'FMS990'),
        to_char(c.apy_prior_pct, 'FM990.00'),
        to_char(c.apy_now_pct,   'FM990.00')
    )                                        AS headline,
    CASE WHEN c.delta_bps > 0 THEN 'up' ELSE 'down' END AS direction,
    round(c.delta_bps, 0)                    AS value_primary,
    'bps'::text                              AS value_unit,
    round(c.delta_bps, 0)                    AS value_delta,
    c.symbol::text                           AS ref,
    jsonb_build_object(
        'reserve_address', c.reserve_address,
        'symbol',          c.symbol,
        'apy_now_pct',     c.apy_now_pct,
        'apy_prior_pct',   c.apy_prior_pct,
        'delta_bps',       c.delta_bps
    )                                        AS supporting
FROM calc c
WHERE abs(c.delta_bps) > hackathon.cfg_num('K3', 'apy_bps_threshold', 50)
ORDER BY abs(c.delta_bps) DESC
LIMIT 1;

COMMENT ON VIEW hackathon.v_brief_k3_borrow_apy_move IS
  'K3 — Borrow APY move. Fires when any tracked Kamino reserve''s borrow APY moved more than K3.apy_bps_threshold vs 24h ago.';
