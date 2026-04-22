-- =============================================================================
-- v_brief_d5_large_swap — large single swap (DEXes / D5)
-- =============================================================================
-- Fires when any single swap event (either side of either pool) involved more
-- than D5.swap_onyc_threshold ONyc. This is a size-based event rather than a
-- statistical one, so a configurable threshold is more meaningful than a
-- percentile.
--
-- On Orca, ONyc is token0; on Raydium, ONyc is token1. We take whichever of
-- amount0_in_max / amount1_in_max refers to ONyc for the pool.
--
-- Returns at most one row — the single largest swap in the 24h window.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_d5_large_swap AS
WITH pool_sides AS (
    SELECT
        ptr.pool_address,
        ptr.protocol,
        ptr.token_pair,
        CASE WHEN ptr.token0_symbol = 'ONyc' THEN 't0'
             WHEN ptr.token1_symbol = 'ONyc' THEN 't1'
             ELSE NULL END AS onyc_side
    FROM dexes.pool_tokens_reference ptr
    WHERE ptr.token0_symbol = 'ONyc' OR ptr.token1_symbol = 'ONyc'
),
candidates AS (
    SELECT
        e.bucket_time,
        e.pool_address,
        ps.protocol,
        ps.token_pair,
        CASE WHEN ps.onyc_side = 't0' THEN e.amount0_in_max::numeric
             WHEN ps.onyc_side = 't1' THEN e.amount1_in_max::numeric
             ELSE NULL END AS onyc_amount_in,
        CASE WHEN ps.onyc_side = 't0' THEN 'sell'
             WHEN ps.onyc_side = 't1' THEN 'sell'
             ELSE NULL END AS trade_direction
    FROM dexes.cagg_events_5s e
    JOIN pool_sides ps USING (pool_address)
    WHERE e.bucket_time >= now() - interval '24 hours'
      AND e.activity_category = 'swap'
)
SELECT
    'D5'::text                                   AS item_id,
    'dexes'::text                                AS section,
    true                                         AS fired,
    now()                                        AS as_of,
    format(
        'Large single ONyc swap on %s %s: %s ONyc moved in one transaction',
        c.protocol,
        c.token_pair,
        to_char(round(c.onyc_amount_in), 'FM999,999,999')
    )                                            AS headline,
    'event'::text                                AS direction,
    round(c.onyc_amount_in, 0)                   AS value_primary,
    'onyc'::text                                 AS value_unit,
    round(c.onyc_amount_in - hackathon.cfg_num('D5', 'swap_onyc_threshold', 50000), 0) AS value_delta,
    c.pool_address::text                         AS ref,
    jsonb_build_object(
        'protocol',        c.protocol,
        'token_pair',      c.token_pair,
        'bucket_time',     c.bucket_time,
        'onyc_amount_in',  c.onyc_amount_in,
        'threshold',       hackathon.cfg_num('D5', 'swap_onyc_threshold', 50000)
    )                                            AS supporting
FROM candidates c
WHERE c.onyc_amount_in > hackathon.cfg_num('D5', 'swap_onyc_threshold', 50000)
ORDER BY c.onyc_amount_in DESC
LIMIT 1;

COMMENT ON VIEW hackathon.v_brief_d5_large_swap IS
  'D5 — Large single swap. Fires when any single ONyc-side swap in the last 24h exceeds D5.swap_onyc_threshold. Tracks both Orca (ONyc=t0) and Raydium (ONyc=t1) via pool_tokens_reference lookup.';
