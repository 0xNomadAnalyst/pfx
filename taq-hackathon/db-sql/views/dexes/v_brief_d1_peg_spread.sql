-- =============================================================================
-- v_brief_d1_peg_spread — peg spread / price drift event (DEXes / D1)
-- =============================================================================
-- ONyc is not a stablecoin; it trades at a free-floating reference price. So
-- D1 fires on *drift*: the 24h VWAP moved by more than D1.drift_bps_threshold
-- vs the prior 24h VWAP. "Peg" in brief-focus-points is reinterpreted as
-- "established short-term reference" — what moved matters, not distance from
-- a static 1.00.
--
-- Works across both slot conventions (Orca ONyc=t0, Raydium ONyc=t1) because
-- we take the ratio of today vs yesterday of whatever `price_t1_per_t0` means
-- per pool — a directional move on either side is a meaningful event.
--
-- Returns at most one row — the pool with the largest drift.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_d1_peg_spread AS
WITH current_price AS (
    SELECT
        pool_address,
        protocol,
        token_pair,
        price_t1_per_t0         AS price_now,
        price_t1_per_t0_avg     AS vwap_24h
    FROM dexes.mat_dex_last
),
prior_vwap AS (
    -- 1-minute bucket right at ~24h ago. Use the closest bucket within a 5-min
    -- tolerance to be resilient to pipeline gaps.
    SELECT DISTINCT ON (pool_address)
        pool_address,
        vwap_buy_t0,
        vwap_sell_t0,
        price_t1_per_t0,
        bucket_time
    FROM dexes.mat_dex_timeseries_1m
    WHERE bucket_time BETWEEN now() - interval '24 hours 5 minutes'
                          AND now() - interval '23 hours 55 minutes'
      AND price_t1_per_t0 IS NOT NULL
    ORDER BY pool_address, bucket_time DESC
),
calc AS (
    SELECT
        cp.pool_address,
        cp.protocol,
        cp.token_pair,
        cp.vwap_24h,
        cp.price_now,
        pv.price_t1_per_t0                                        AS price_prior_24h,
        -- signed drift: now vs 24h ago, in bps, proportionate to prior price
        (((cp.price_now - pv.price_t1_per_t0) / pv.price_t1_per_t0) * 10000)::numeric AS drift_bps
    FROM current_price cp
    JOIN prior_vwap pv USING (pool_address)
    WHERE cp.price_now IS NOT NULL
      AND pv.price_t1_per_t0 IS NOT NULL
      AND pv.price_t1_per_t0 > 0
)
SELECT
    'D1'::text                           AS item_id,
    'dexes'::text                        AS section,
    true                                 AS fired,
    now()                                AS as_of,
    format(
        '%s %s: price drifted %s bps over 24h (%s → %s)',
        c.protocol,
        c.token_pair,
        to_char(round(c.drift_bps, 1), 'FMS990.0'),
        to_char(c.price_prior_24h, 'FM0.0000'),
        to_char(c.price_now,       'FM0.0000')
    )                                    AS headline,
    CASE WHEN c.drift_bps > 0 THEN 'up' ELSE 'down' END AS direction,
    round(c.drift_bps, 1)                AS value_primary,
    'bps'::text                          AS value_unit,
    round(c.drift_bps, 1)                AS value_delta,
    c.pool_address::text                 AS ref,
    jsonb_build_object(
        'protocol',         c.protocol,
        'token_pair',       c.token_pair,
        'vwap_24h',         c.vwap_24h,
        'price_now',        c.price_now,
        'price_prior_24h',  c.price_prior_24h,
        'drift_bps',        c.drift_bps
    )                                    AS supporting
FROM calc c
WHERE abs(c.drift_bps) > hackathon.cfg_num('D1', 'drift_bps_threshold', 15)
ORDER BY abs(c.drift_bps) DESC
LIMIT 1;

COMMENT ON VIEW hackathon.v_brief_d1_peg_spread IS
  'D1 — Peg spread event. Fires when 24h VWAP is off-peg beyond D1.peg_bps_threshold, or when it has drifted more than D1.drift_bps_threshold vs the prior 24h. Returns at most one row (the most extreme pool).';
