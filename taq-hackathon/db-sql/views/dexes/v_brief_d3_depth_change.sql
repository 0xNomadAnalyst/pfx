-- =============================================================================
-- v_brief_d3_depth_change — liquidity depth change (DEXes / D3)
-- =============================================================================
-- Fires when cumulative depth within the peg neighbourhood has moved by more
-- than D3.depth_pct_threshold vs its 7-day baseline.
--
-- Uses `concentration_peg_pct_1` from mat_dex_timeseries_1m — the share of
-- liquidity within ±1% of peg. Compares now vs the 7d mean of that column.
--
-- Returns at most one row — the most affected pool.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_d3_depth_change AS
WITH cur AS (
    SELECT DISTINCT ON (pool_address)
        pool_address, protocol, token_pair,
        concentration_peg_pct_1 AS depth_now
    FROM dexes.mat_dex_timeseries_1m
    WHERE bucket_time >= now() - interval '15 minutes'
      AND concentration_peg_pct_1 IS NOT NULL
    ORDER BY pool_address, bucket_time DESC
),
baseline AS (
    SELECT
        pool_address,
        avg(concentration_peg_pct_1) AS depth_7d_avg
    FROM dexes.mat_dex_timeseries_1m
    WHERE bucket_time >= now() - (hackathon.cfg_num('_global', 'baseline_days', 7) || ' days')::interval
      AND bucket_time <  now() - interval '24 hours'
      AND concentration_peg_pct_1 IS NOT NULL
    GROUP BY pool_address
),
calc AS (
    SELECT
        c.pool_address, c.protocol, c.token_pair,
        c.depth_now,
        b.depth_7d_avg,
        c.depth_now - b.depth_7d_avg                                         AS depth_pp_change,
        ((c.depth_now - b.depth_7d_avg) / NULLIF(b.depth_7d_avg, 0)) * 100.0 AS depth_pct_change
    FROM cur c
    LEFT JOIN baseline b USING (pool_address)
    WHERE b.depth_7d_avg IS NOT NULL
)
SELECT
    'D3'::text                                 AS item_id,
    'dexes'::text                              AS section,
    true                                       AS fired,
    now()                                      AS as_of,
    format(
        '%s %s: depth-at-peg %s vs 7d baseline (%s%% → %s%%)',
        c.protocol,
        c.token_pair,
        CASE WHEN c.depth_pct_change > 0 THEN 'grew' ELSE 'shrank' END,
        to_char(c.depth_7d_avg, 'FM990.0'),
        to_char(c.depth_now,     'FM990.0')
    )                                          AS headline,
    CASE WHEN c.depth_pct_change >= 0 THEN 'up' ELSE 'down' END AS direction,
    round(c.depth_pct_change, 1)               AS value_primary,
    'pct'::text                                AS value_unit,
    round(c.depth_pp_change, 1)                AS value_delta,
    c.pool_address::text                       AS ref,
    jsonb_build_object(
        'protocol',        c.protocol,
        'token_pair',      c.token_pair,
        'depth_now',       c.depth_now,
        'depth_7d_avg',    c.depth_7d_avg,
        'depth_pct_change',c.depth_pct_change
    )                                          AS supporting
FROM calc c
WHERE abs(c.depth_pct_change) > hackathon.cfg_num('D3', 'depth_pct_threshold', 15)
ORDER BY abs(c.depth_pct_change) DESC
LIMIT 1;

COMMENT ON VIEW hackathon.v_brief_d3_depth_change IS
  'D3 — Liquidity depth change. Fires when concentration_peg_pct_1 (share of liquidity within ±1%% of peg) moved by more than D3.depth_pct_threshold vs 7d baseline. Returns at most one row.';
