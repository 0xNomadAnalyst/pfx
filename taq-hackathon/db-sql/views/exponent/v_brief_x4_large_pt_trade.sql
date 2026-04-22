-- =============================================================================
-- v_brief_x4_large_pt_trade — large PT trade (Exponent / X4)
-- =============================================================================
-- Fires when any single 5-second bucket saw AMM PT trade volume exceeding
-- X4.pt_onyc_threshold. We sum amount_amm_pt_in + amount_amm_pt_out within a
-- bucket as the single-burst proxy, and join to aux_key_relations for
-- labelling.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_x4_large_pt_trade AS
WITH candidates AS (
    SELECT
        e.bucket_time,
        e.market_address,
        akr.meta_pt_name,
        akr.vault_address,
        (COALESCE(e.amount_amm_pt_in, 0) + COALESCE(e.amount_amm_pt_out, 0))::numeric AS pt_traded
    FROM exponent.cagg_tx_events_5s e
    LEFT JOIN exponent.aux_key_relations akr USING (market_address)
    WHERE e.bucket_time >= now() - interval '24 hours'
      AND e.event_category = 'trade'
)
SELECT
    'X4'::text                               AS item_id,
    'exponent'::text                         AS section,
    true                                     AS fired,
    now()                                    AS as_of,
    format(
        'Large PT trade on %s: %s PT moved in one bucket',
        COALESCE(c.meta_pt_name, 'unknown market'),
        to_char(round(c.pt_traded), 'FM999,999,999')
    )                                        AS headline,
    'event'::text                            AS direction,
    round(c.pt_traded, 0)                    AS value_primary,
    'onyc'::text                             AS value_unit,
    round(c.pt_traded - hackathon.cfg_num('X4', 'pt_onyc_threshold', 25000), 0) AS value_delta,
    c.market_address::text                   AS ref,
    jsonb_build_object(
        'market_address', c.market_address,
        'vault_address',  c.vault_address,
        'pt_name',        c.meta_pt_name,
        'bucket_time',    c.bucket_time,
        'pt_traded',      c.pt_traded,
        'threshold',      hackathon.cfg_num('X4', 'pt_onyc_threshold', 25000)
    )                                        AS supporting
FROM candidates c
WHERE c.pt_traded > hackathon.cfg_num('X4', 'pt_onyc_threshold', 25000)
ORDER BY c.pt_traded DESC
LIMIT 1;

COMMENT ON VIEW hackathon.v_brief_x4_large_pt_trade IS
  'X4 — Large PT trade. Fires when any single 5s bucket''s AMM PT trade volume exceeds X4.pt_onyc_threshold.';
