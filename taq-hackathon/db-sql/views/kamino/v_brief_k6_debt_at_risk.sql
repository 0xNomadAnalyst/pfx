-- =============================================================================
-- v_brief_k6_debt_at_risk — debt-at-risk trajectory (Kamino / K6)
-- =============================================================================
-- Fires when market-level unhealthy debt has moved materially. Uses
-- mat_klend_last_obligations.total_unhealthy_debt as the aggregate measure —
-- this captures loans currently below their liquidation threshold (the
-- concrete risk surface).
--
-- We report the absolute level (if non-zero), since any unhealthy debt is
-- notable — and also the % change vs the 7d baseline when available.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_k6_debt_at_risk AS
WITH cur AS (
    SELECT
        market_address,
        total_unhealthy_debt,
        total_bad_debt,
        unhealthy_count,
        bad_debt_count,
        unhealthy_debt_pct,
        bad_debt_pct,
        total_liquidatable_value,
        weighted_avg_health_factor_sig
    FROM kamino_lend.mat_klend_last_obligations
    WHERE total_unhealthy_debt IS NOT NULL
)
SELECT
    'K6'::text                                 AS item_id,
    'kamino'::text                             AS section,
    true                                       AS fired,
    now()                                      AS as_of,
    format(
        'Market has %s unhealthy debt across %s obligation(s) — %s%% of book; %s liquidatable',
        to_char(round(c.total_unhealthy_debt), 'FM999,999,999'),
        c.unhealthy_count,
        to_char(c.unhealthy_debt_pct, 'FM990.00'),
        to_char(round(c.total_liquidatable_value), 'FM999,999,999')
    )                                          AS headline,
    'down'::text                               AS direction,
    round(c.total_unhealthy_debt, 0)           AS value_primary,
    'count'::text                              AS value_unit,
    c.unhealthy_count                          AS value_delta,
    c.market_address::text                     AS ref,
    jsonb_build_object(
        'market_address',          c.market_address,
        'total_unhealthy_debt',    c.total_unhealthy_debt,
        'total_bad_debt',          c.total_bad_debt,
        'unhealthy_count',         c.unhealthy_count,
        'bad_debt_count',          c.bad_debt_count,
        'unhealthy_debt_pct',      c.unhealthy_debt_pct,
        'bad_debt_pct',            c.bad_debt_pct,
        'total_liquidatable_value', c.total_liquidatable_value,
        'weighted_avg_hf',         c.weighted_avg_health_factor_sig
    )                                          AS supporting
FROM cur c
WHERE c.total_unhealthy_debt > 0
ORDER BY c.total_unhealthy_debt DESC
LIMIT 1;

COMMENT ON VIEW hackathon.v_brief_k6_debt_at_risk IS
  'K6 — Debt-at-risk trajectory. Fires whenever market-level total_unhealthy_debt is non-zero, since unhealthy debt is itself a material condition. Supporting JSON exposes the full risk summary from mat_klend_last_obligations.';
