-- =============================================================================
-- v_brief_section_ecosystem — Ecosystem section collector
-- =============================================================================
-- UNION ALL of every E* per-item view. Returns 0..5 rows per call.
-- =============================================================================

CREATE OR REPLACE VIEW hackathon.v_brief_section_ecosystem AS
SELECT * FROM hackathon.v_brief_e1_supply_composition
UNION ALL SELECT * FROM hackathon.v_brief_e2_venue_tvl_migration
UNION ALL SELECT * FROM hackathon.v_brief_e3_availability_shift
UNION ALL SELECT * FROM hackathon.v_brief_e4_activity_rotation
UNION ALL SELECT * FROM hackathon.v_brief_e5_cross_venue_yield_spread;

COMMENT ON VIEW hackathon.v_brief_section_ecosystem IS
  'Section collector: union of all Ecosystem (E*) per-item views. Returns 0..5 rows.';
