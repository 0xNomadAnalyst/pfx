-- =============================================================================
-- v_brief_x3_amm_depth_deployment — AMM depth / deployment change (X3)
-- =============================================================================
-- Fires when any active market's SY-in-pool (`pool_depth_in_sy`) OR the AMM
-- deployment ratio (`amm_share_sy_pct`) moved more than X3.pct_threshold vs
-- 24h ago.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_x3_amm_depth_deployment AS
WITH cur AS (
    SELECT
        vault_address, market_address, meta_pt_name,
        pool_depth_in_sy, amm_share_sy_pct, is_expired
    FROM exponent.mat_exp_last
    WHERE pool_depth_in_sy IS NOT NULL
      AND is_expired = false
),
prior AS (
    SELECT DISTINCT ON (market_address)
        market_address,
        pool_depth_in_sy AS depth_prior,
        pool_depth_sy_pct AS share_prior_pct
    FROM exponent.mat_exp_timeseries_1m
    WHERE bucket_time BETWEEN now() - interval '24 hours 5 minutes'
                          AND now() - interval '23 hours 55 minutes'
      AND pool_depth_in_sy IS NOT NULL
    ORDER BY market_address, bucket_time DESC
),
calc AS (
    SELECT
        cur.vault_address, cur.market_address, cur.meta_pt_name,
        cur.pool_depth_in_sy, prior.depth_prior,
        cur.amm_share_sy_pct, prior.share_prior_pct,
        ((cur.pool_depth_in_sy - prior.depth_prior) / NULLIF(prior.depth_prior, 0)) * 100.0 AS depth_pct_change,
        (cur.amm_share_sy_pct - COALESCE(prior.share_prior_pct, cur.amm_share_sy_pct))     AS share_pp_change
    FROM cur JOIN prior USING (market_address)
    WHERE prior.depth_prior > 0
)
SELECT
    'X3'::text                               AS item_id,
    'exponent'::text                         AS section,
    true                                     AS fired,
    now()                                    AS as_of,
    format(
        '%s AMM SY depth moved %s%% over 24h (%s → %s)',
        c.meta_pt_name,
        to_char(round(c.depth_pct_change, 1), 'FMS990.0'),
        to_char(round(c.depth_prior), 'FM999,999,999'),
        to_char(round(c.pool_depth_in_sy),  'FM999,999,999')
    )                                        AS headline,
    CASE WHEN c.depth_pct_change >= 0 THEN 'up' ELSE 'down' END AS direction,
    round(c.depth_pct_change, 1)             AS value_primary,
    'pct'::text                              AS value_unit,
    round(c.share_pp_change, 2)              AS value_delta,
    c.market_address::text                   AS ref,
    jsonb_build_object(
        'vault_address',      c.vault_address,
        'market_address',     c.market_address,
        'pt_name',            c.meta_pt_name,
        'pool_depth_in_sy',   c.pool_depth_in_sy,
        'depth_prior',        c.depth_prior,
        'depth_pct_change',   c.depth_pct_change,
        'amm_share_sy_pct',   c.amm_share_sy_pct,
        'share_prior_pct',    c.share_prior_pct,
        'share_pp_change',    c.share_pp_change
    )                                        AS supporting
FROM calc c
WHERE abs(c.depth_pct_change) > hackathon.cfg_num('X3', 'pct_threshold', 15)
ORDER BY abs(c.depth_pct_change) DESC
LIMIT 1;

COMMENT ON VIEW hackathon.v_brief_x3_amm_depth_deployment IS
  'X3 — AMM depth / deployment change. Fires when an active market''s pool_depth_in_sy moved more than X3.pct_threshold vs 24h ago.';
