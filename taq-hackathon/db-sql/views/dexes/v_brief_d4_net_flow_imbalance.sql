-- =============================================================================
-- v_brief_d4_net_flow_imbalance — net sell-pressure imbalance (DEXes / D4)
-- =============================================================================
-- Fires when the 24h net sell pressure on ONyc exceeds the empirical p95
-- threshold from dexes.risk_pvalues (with sell_pressure_interval_mins=1440).
--
-- Scope caveat (v1): same as D2 — risk_pvalues tracks amount0_net, which is
-- ONyc-sell-net for Orca only. Raydium's token0 is USDG, so its pvalues track
-- USDG sells (ONyc buys) — the wrong side for this item. D4 fires on Orca
-- only in v1.
--
-- Returns at most one row.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_d4_net_flow_imbalance AS
WITH threshold AS (
    SELECT
        rp.protocol,
        rp.pair,
        rp.t0_sell_pressure_amount AS p95_threshold
    FROM dexes.risk_pvalues rp
    WHERE rp.date = (SELECT max(date) FROM dexes.risk_pvalues)
      AND rp.stat = hackathon.cfg_text('D4', 'pvalue_stat', '95')
      AND rp.sell_pressure_interval_mins = hackathon.cfg_num('D4', 'pvalue_interval_mins', 1440)
      AND rp.protocol = 'orca'   -- see scope caveat above
      AND rp.pair = 'onyc-usdc'
),
net_pressure AS (
    SELECT
        e.pool_address,
        e.protocol,
        e.token_pair,
        SUM(e.amount0_net)::numeric AS net_24h_onyc_sold
    FROM dexes.cagg_events_5s e
    WHERE e.bucket_time >= now() - interval '24 hours'
      AND e.activity_category = 'swap'
      AND e.protocol = 'orca'
    GROUP BY e.pool_address, e.protocol, e.token_pair
),
calc AS (
    SELECT
        n.pool_address, n.protocol, n.token_pair,
        n.net_24h_onyc_sold,
        t.p95_threshold,
        n.net_24h_onyc_sold - t.p95_threshold AS excess_over_p95
    FROM net_pressure n
    JOIN threshold t
      ON n.protocol = t.protocol
     AND LOWER(n.token_pair) = t.pair
    WHERE n.net_24h_onyc_sold > t.p95_threshold
)
SELECT
    'D4'::text                               AS item_id,
    'dexes'::text                            AS section,
    true                                     AS fired,
    now()                                    AS as_of,
    format(
        'Net ONyc sell pressure on %s %s: %s ONyc over 24h (>= p%s baseline %s)',
        c.protocol,
        c.token_pair,
        to_char(round(c.net_24h_onyc_sold), 'FM999,999,999'),
        hackathon.cfg_text('D4', 'pvalue_stat', '95'),
        to_char(round(c.p95_threshold), 'FM999,999,999')
    )                                        AS headline,
    'down'::text                             AS direction,
    round(c.net_24h_onyc_sold, 0)            AS value_primary,
    'onyc'::text                             AS value_unit,
    round(c.excess_over_p95, 0)              AS value_delta,
    c.pool_address::text                     AS ref,
    jsonb_build_object(
        'protocol',          c.protocol,
        'token_pair',        c.token_pair,
        'net_24h_onyc_sold', c.net_24h_onyc_sold,
        'p95_threshold',     c.p95_threshold,
        'pvalue_stat',       hackathon.cfg_text('D4', 'pvalue_stat', '95'),
        'interval_mins',     hackathon.cfg_num('D4', 'pvalue_interval_mins', 1440)
    )                                        AS supporting
FROM calc c
ORDER BY c.net_24h_onyc_sold DESC
LIMIT 1;

COMMENT ON VIEW hackathon.v_brief_d4_net_flow_imbalance IS
  'D4 — Net flow imbalance. Fires when 24h net ONyc-sell pressure exceeds the empirical p95 threshold from dexes.risk_pvalues (1440-min interval). Orca only in v1.';
