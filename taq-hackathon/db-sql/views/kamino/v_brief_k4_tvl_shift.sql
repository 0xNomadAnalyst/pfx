-- =============================================================================
-- v_brief_k4_tvl_shift — reserve TVL shift (Kamino / K4)
-- =============================================================================
-- Fires when any tracked reserve's deposit_tvl or borrow_tvl moved more than
-- K4.tvl_pct_threshold vs its 7d baseline. Picks the single reserve with the
-- largest absolute move.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_k4_tvl_shift AS
WITH cur AS (
    SELECT
        reserve_address, symbol,
        deposit_tvl, borrow_tvl
    FROM kamino_lend.mat_klend_last_reserves
    WHERE deposit_tvl IS NOT NULL
),
baseline AS (
    SELECT
        reserve_address,
        avg(vault_liquidity_marketvalue) AS deposit_tvl_7d_avg,
        avg(vault_collateral_marketvalue) AS collateral_tvl_7d_avg
    FROM kamino_lend.mat_klend_reserve_ts_1m
    WHERE bucket_time >= now() - (hackathon.cfg_num('_global', 'baseline_days', 7) || ' days')::interval
      AND bucket_time <  now() - interval '24 hours'
    GROUP BY reserve_address
),
calc AS (
    SELECT
        c.reserve_address, c.symbol,
        c.deposit_tvl,
        b.deposit_tvl_7d_avg,
        ((c.deposit_tvl - b.deposit_tvl_7d_avg) / NULLIF(b.deposit_tvl_7d_avg, 0)) * 100.0 AS deposit_pct_change
    FROM cur c
    LEFT JOIN baseline b USING (reserve_address)
    WHERE b.deposit_tvl_7d_avg IS NOT NULL
      AND b.deposit_tvl_7d_avg > 0
)
SELECT
    'K4'::text                                AS item_id,
    'kamino'::text                            AS section,
    true                                      AS fired,
    now()                                     AS as_of,
    format(
        '%s deposit TVL moved %s%% vs 7d baseline (%s → %s)',
        c.symbol,
        to_char(round(c.deposit_pct_change, 1), 'FMS990.0'),
        to_char(round(c.deposit_tvl_7d_avg), 'FM999,999,999'),
        to_char(round(c.deposit_tvl),         'FM999,999,999')
    )                                         AS headline,
    CASE WHEN c.deposit_pct_change >= 0 THEN 'up' ELSE 'down' END AS direction,
    round(c.deposit_tvl, 0)                   AS value_primary,
    'pct'::text                               AS value_unit,
    round(c.deposit_pct_change, 1)            AS value_delta,
    c.symbol::text                            AS ref,
    jsonb_build_object(
        'reserve_address',     c.reserve_address,
        'symbol',              c.symbol,
        'deposit_tvl',         c.deposit_tvl,
        'deposit_tvl_7d_avg',  c.deposit_tvl_7d_avg,
        'deposit_pct_change',  c.deposit_pct_change
    )                                         AS supporting
FROM calc c
WHERE abs(c.deposit_pct_change) > hackathon.cfg_num('K4', 'tvl_pct_threshold', 10)
  -- Ignore dust reserves: both the current and baseline deposit_tvl must exceed
  -- K4.min_tvl_floor (in USD-equivalent market value units) so a swing from
  -- $4 -> $0 doesn't trigger a "100% collapse" headline.
  AND c.deposit_tvl          > hackathon.cfg_num('K4', 'min_tvl_floor', 10000)
  AND c.deposit_tvl_7d_avg   > hackathon.cfg_num('K4', 'min_tvl_floor', 10000)
ORDER BY abs(c.deposit_pct_change) DESC
LIMIT 1;

COMMENT ON VIEW hackathon.v_brief_k4_tvl_shift IS
  'K4 — TVL shift. Fires when any Kamino reserve''s deposit TVL moved more than K4.tvl_pct_threshold vs the 7d baseline.';
