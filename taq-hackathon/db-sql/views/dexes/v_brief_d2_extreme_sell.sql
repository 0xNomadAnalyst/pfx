-- =============================================================================
-- v_brief_d2_extreme_sell — extreme sell event (DEXes / D2)
-- =============================================================================
-- Fires when any individual single-swap sell of ONyc in the last 24h exceeds
-- the empirical percentile threshold (default p99) stored in dexes.risk_pvalues.
--
-- Substrate usage:
--   dexes.cagg_events_5s.amount0_in_max — largest single swap selling token0
--     per 5-second bucket
--   dexes.risk_pvalues (stat = D2.pvalue_stat, sell_pressure_interval_mins = 0)
--     — historical percentile of individual ONyc sells
--
-- Scope caveat (v1): Orca (ONyc-USDC, token0=ONyc) only. Raydium (USDG-ONyc,
-- token0=USDG) has risk_pvalues indexed on USDG-sells (buy side of ONyc), so
-- the symmetric ONyc-sell threshold does not exist in the substrate for
-- Raydium. A future enhancement would compute Raydium-ONyc-sell p-values;
-- until then, Orca carries the signal.
--
-- Returns at most one row: the most extreme sell event in the 24h window.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_d2_extreme_sell AS
WITH threshold AS (
    SELECT
        rp.protocol,
        rp.pair,
        rp.t0_sell_amount AS p99_sell_amount
    FROM dexes.risk_pvalues rp
    WHERE rp.date = (SELECT max(date) FROM dexes.risk_pvalues)
      AND rp.stat = hackathon.cfg_text('D2', 'pvalue_stat', '99')
      AND rp.sell_pressure_interval_mins = 0
      AND rp.protocol = 'orca'   -- see scope caveat above
      AND rp.pair = 'onyc-usdc'
),
candidates AS (
    SELECT
        e.bucket_time,
        e.pool_address,
        e.token_pair,
        e.protocol,
        e.amount0_in_max::numeric                             AS onyc_sell_amount,
        t.p99_sell_amount::numeric                            AS p99_sell_amount,
        (e.amount0_in_max::numeric - t.p99_sell_amount::numeric) AS excess_over_p99
    FROM dexes.cagg_events_5s e
    JOIN threshold t
      ON e.protocol = t.protocol
     AND LOWER(e.token_pair) = t.pair
    WHERE e.bucket_time >= now() - interval '24 hours'
      AND e.activity_category = 'swap'
      AND e.amount0_in_max IS NOT NULL
      AND e.amount0_in_max >= t.p99_sell_amount
)
SELECT
    'D2'::text                               AS item_id,
    'dexes'::text                            AS section,
    true                                     AS fired,
    now()                                    AS as_of,
    format(
        'Extreme ONyc sell on %s %s: %s ONyc in one swap (>= p%s baseline %s)',
        c.protocol,
        c.token_pair,
        to_char(round(c.onyc_sell_amount), 'FM999,999,999'),
        hackathon.cfg_text('D2', 'pvalue_stat', '99'),
        to_char(round(c.p99_sell_amount), 'FM999,999,999')
    )                                        AS headline,
    'down'::text                             AS direction,
    round(c.onyc_sell_amount, 0)             AS value_primary,
    'onyc'::text                             AS value_unit,
    round(c.excess_over_p99, 0)              AS value_delta,
    c.pool_address::text                     AS ref,
    jsonb_build_object(
        'bucket_time',      c.bucket_time,
        'protocol',         c.protocol,
        'token_pair',       c.token_pair,
        'onyc_sell_amount', c.onyc_sell_amount,
        'p99_sell_amount',  c.p99_sell_amount,
        'pvalue_stat',      hackathon.cfg_text('D2', 'pvalue_stat', '99')
    )                                        AS supporting
FROM candidates c
ORDER BY c.onyc_sell_amount DESC
LIMIT 1;

COMMENT ON VIEW hackathon.v_brief_d2_extreme_sell IS
  'D2 — Extreme sell event. Fires when any individual ONyc sell in the last 24h exceeds the empirical p99 threshold from dexes.risk_pvalues. Orca (ONyc-USDC) only in v1 — see view source for scope caveat.';
