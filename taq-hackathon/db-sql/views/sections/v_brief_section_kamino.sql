-- =============================================================================
-- v_brief_section_kamino — Kamino section collector
-- =============================================================================
-- UNION ALL of every K* per-item view. Returns 0..6 rows per call.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_section_kamino AS
SELECT * FROM hackathon.v_brief_k1_zone_transition
UNION ALL SELECT * FROM hackathon.v_brief_k2_liquidations
UNION ALL SELECT * FROM hackathon.v_brief_k3_borrow_apy_move
UNION ALL SELECT * FROM hackathon.v_brief_k4_tvl_shift
UNION ALL SELECT * FROM hackathon.v_brief_k5_top_obligation_hf
UNION ALL SELECT * FROM hackathon.v_brief_k6_debt_at_risk;

COMMENT ON VIEW hackathon.v_brief_section_kamino IS
  'Section collector: union of all Kamino (K*) per-item views. Returns 0..6 rows.';
