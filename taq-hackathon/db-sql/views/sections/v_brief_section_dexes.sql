-- =============================================================================
-- v_brief_section_dexes — DEXes section collector
-- =============================================================================
-- UNION ALL of every D* per-item view. Returns 0..6 rows per call. The
-- per-item views are UNION-ALL compatible (same stable column shape) — see
-- the project-wide per-item contract documented in the plan.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_section_dexes AS
SELECT * FROM hackathon.v_brief_d1_peg_spread
UNION ALL SELECT * FROM hackathon.v_brief_d2_extreme_sell
UNION ALL SELECT * FROM hackathon.v_brief_d3_depth_change
UNION ALL SELECT * FROM hackathon.v_brief_d4_net_flow_imbalance
UNION ALL SELECT * FROM hackathon.v_brief_d5_large_swap
UNION ALL SELECT * FROM hackathon.v_brief_d6_large_lp_event;

COMMENT ON VIEW hackathon.v_brief_section_dexes IS
  'Section collector: union of all DEXes (D*) per-item views. Returns 0..6 rows.';
