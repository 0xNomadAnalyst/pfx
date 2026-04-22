-- =============================================================================
-- v_brief_section_exponent — Exponent section collector
-- =============================================================================
-- UNION ALL of every X* per-item view. Returns 0..5 rows per call.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_section_exponent AS
SELECT * FROM hackathon.v_brief_x1_fixed_rate_move
UNION ALL SELECT * FROM hackathon.v_brief_x2_fixed_variable_spread
UNION ALL SELECT * FROM hackathon.v_brief_x3_amm_depth_deployment
UNION ALL SELECT * FROM hackathon.v_brief_x4_large_pt_trade
UNION ALL SELECT * FROM hackathon.v_brief_x5_maturity_event;

COMMENT ON VIEW hackathon.v_brief_section_exponent IS
  'Section collector: union of all Exponent (X*) per-item views. Returns 0..5 rows.';
