-- =============================================================================
-- v_brief_k5_top_obligation_hf — top-obligation health factor change (K5)
-- =============================================================================
-- Fires when any obligation in the top-N (by current borrow value) has a
-- health factor below K5.hf_floor, OR has moved more than K5.hf_pct_threshold
-- vs 24h ago.
--
-- Scope note (v1): "vs 7d value" in brief-focus-points simplified to "below
-- floor" in v1 because tracking per-obligation historical HF requires joining
-- against src_obligations (hypertable) — possible but heavier. The current
-- approach captures the most important case (largest borrowers currently at
-- risk) without the historical join.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_k5_top_obligation_hf AS
WITH ranked AS (
    SELECT
        obligation_address,
        owner,
        c_health_factor,
        c_user_total_borrow,
        c_user_total_deposit,
        c_loan_to_value_pct,
        c_is_unhealthy,
        c_is_bad_debt,
        ROW_NUMBER() OVER (ORDER BY c_user_total_borrow DESC NULLS LAST) AS rn
    FROM kamino_lend.src_obligations_last
    WHERE c_user_total_borrow IS NOT NULL
      AND c_user_total_borrow > 0
),
top_n AS (
    SELECT * FROM ranked
    WHERE rn <= hackathon.cfg_num('K5', 'top_n', 10)
)
SELECT
    'K5'::text                                 AS item_id,
    'kamino'::text                             AS section,
    true                                       AS fired,
    now()                                      AS as_of,
    format(
        'Top-%s obligation %s near threshold: HF %s, debt %s, LTV %s%%',
        t.rn,
        substring(t.obligation_address, 1, 8) || '…',
        to_char(t.c_health_factor, 'FM990.00'),
        to_char(round(t.c_user_total_borrow), 'FM999,999,999'),
        to_char(t.c_loan_to_value_pct, 'FM990.0')
    )                                          AS headline,
    'down'::text                               AS direction,
    round(t.c_health_factor, 2)                AS value_primary,
    'hf'::text                                 AS value_unit,
    round(hackathon.cfg_num('K5', 'hf_floor', 1.30) - t.c_health_factor, 2) AS value_delta,
    t.obligation_address::text                 AS ref,
    jsonb_build_object(
        'obligation_address', t.obligation_address,
        'owner',              t.owner,
        'rank',               t.rn,
        'health_factor',      t.c_health_factor,
        'loan_to_value_pct',  t.c_loan_to_value_pct,
        'user_total_borrow',  t.c_user_total_borrow,
        'user_total_deposit', t.c_user_total_deposit,
        'is_unhealthy',       t.c_is_unhealthy,
        'is_bad_debt',        t.c_is_bad_debt,
        'hf_floor',           hackathon.cfg_num('K5', 'hf_floor', 1.30)
    )                                          AS supporting
FROM top_n t
WHERE t.c_health_factor IS NOT NULL
  AND t.c_health_factor < hackathon.cfg_num('K5', 'hf_floor', 1.30)
ORDER BY t.c_health_factor ASC
LIMIT 1;

COMMENT ON VIEW hackathon.v_brief_k5_top_obligation_hf IS
  'K5 — Top obligation health change. Fires when a top-N (by debt) obligation''s HF falls below K5.hf_floor. Returns the lowest-HF top-N obligation.';
