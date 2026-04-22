-- =============================================================================
-- v_brief_d6_large_lp_event — large LP event (DEXes / D6)
-- =============================================================================
-- Fires when any single 5s bucket saw LP activity greater than D6.pool_pct of
-- pool reserves. We use the per-bucket sum of LP token0 in+out from
-- cagg_events_5s as the single-event proxy (a burst of adds/removes in a 5s
-- bucket is overwhelmingly one or few LP actors), normalised by the pool's
-- current t0 reserve from mat_dex_last.
--
-- Returns at most one row — the largest event in the 24h window.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_d6_large_lp_event AS
WITH pool_state AS (
    SELECT
        mdl.pool_address,
        mdl.protocol,
        mdl.token_pair,
        mdl.t0_reserve::numeric AS t0_reserve,
        CASE WHEN ptr.token0_symbol = 'ONyc' THEN 't0'
             WHEN ptr.token1_symbol = 'ONyc' THEN 't1'
             ELSE NULL END AS onyc_side
    FROM dexes.mat_dex_last mdl
    JOIN dexes.pool_tokens_reference ptr USING (pool_address)
),
lp_events AS (
    SELECT
        e.bucket_time,
        e.pool_address,
        ps.protocol,
        ps.token_pair,
        ps.t0_reserve,
        ps.onyc_side,
        (e.amount0_in + e.amount0_out)::numeric AS lp_t0_total
    FROM dexes.cagg_events_5s e
    JOIN pool_state ps USING (pool_address)
    WHERE e.bucket_time >= now() - interval '24 hours'
      AND e.activity_category = 'lp'
      AND ps.t0_reserve > 0
),
calc AS (
    SELECT
        le.bucket_time,
        le.pool_address, le.protocol, le.token_pair,
        le.lp_t0_total,
        (le.lp_t0_total / le.t0_reserve) * 100.0 AS pct_of_pool_t0
    FROM lp_events le
)
SELECT
    'D6'::text                                   AS item_id,
    'dexes'::text                                AS section,
    true                                         AS fired,
    now()                                        AS as_of,
    format(
        'Large LP event on %s %s: single bucket moved %s%% of pool token0 reserves',
        c.protocol,
        c.token_pair,
        to_char(round(c.pct_of_pool_t0, 2), 'FM999.00')
    )                                            AS headline,
    'event'::text                                AS direction,
    round(c.pct_of_pool_t0, 2)                   AS value_primary,
    'pct'::text                                  AS value_unit,
    round(c.pct_of_pool_t0 - hackathon.cfg_num('D6', 'pool_pct_threshold', 5), 2) AS value_delta,
    c.pool_address::text                         AS ref,
    jsonb_build_object(
        'protocol',       c.protocol,
        'token_pair',     c.token_pair,
        'bucket_time',    c.bucket_time,
        'lp_t0_total',    c.lp_t0_total,
        'pct_of_pool_t0', c.pct_of_pool_t0,
        'threshold_pct',  hackathon.cfg_num('D6', 'pool_pct_threshold', 5)
    )                                            AS supporting
FROM calc c
WHERE c.pct_of_pool_t0 > hackathon.cfg_num('D6', 'pool_pct_threshold', 5)
ORDER BY c.pct_of_pool_t0 DESC
LIMIT 1;

COMMENT ON VIEW hackathon.v_brief_d6_large_lp_event IS
  'D6 — Large LP event. Fires when a single 5s bucket''s LP activity on a tracked pool exceeds D6.pool_pct_threshold of that pool''s current t0 reserves. Returns at most one row (largest in 24h).';
