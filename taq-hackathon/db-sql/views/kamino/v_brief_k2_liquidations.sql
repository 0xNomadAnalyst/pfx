-- =============================================================================
-- v_brief_k2_liquidations — liquidation events (Kamino / K2)
-- =============================================================================
-- Fires when any tracked reserve has seen any liquidation volume in the last
-- 24 hours. Liquidations are rare, so this item fires with "any > 0" — no
-- empirical threshold needed.
--
-- Reads mat_klend_last_activities.liquidate_vol_24h directly (already
-- pre-aggregated).
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_k2_liquidations AS
WITH total AS (
    SELECT
        SUM(liquidate_vol_24h) AS total_liquidate_vol,
        SUM(CASE WHEN liquidate_vol_24h > 0 THEN 1 ELSE 0 END) AS reserves_with_liqs
    FROM kamino_lend.mat_klend_last_activities
)
SELECT
    'K2'::text                                AS item_id,
    'kamino'::text                            AS section,
    true                                      AS fired,
    now()                                     AS as_of,
    format(
        'Liquidations in 24h: %s across %s reserve(s)',
        to_char(round(t.total_liquidate_vol), 'FM999,999,999'),
        t.reserves_with_liqs
    )                                         AS headline,
    'event'::text                             AS direction,
    round(t.total_liquidate_vol, 0)           AS value_primary,
    'count'::text                             AS value_unit,
    t.reserves_with_liqs                      AS value_delta,
    NULL::text                                AS ref,
    jsonb_build_object(
        'total_liquidate_vol', t.total_liquidate_vol,
        'reserves_with_liqs',  t.reserves_with_liqs
    )                                         AS supporting
FROM total t
WHERE t.total_liquidate_vol IS NOT NULL
  AND t.total_liquidate_vol > 0;

COMMENT ON VIEW hackathon.v_brief_k2_liquidations IS
  'K2 — Liquidations occurred. Fires when any liquidation volume registered against any tracked Kamino reserve in the last 24h. Rare event — leads the brief when it fires.';
