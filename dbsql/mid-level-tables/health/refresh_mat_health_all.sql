-- =============================================================================
-- refresh_mat_health_all
-- Unified refresh procedure for all health materialised tables.
-- cagg_status runs FIRST to minimise the window between CAGG refresh
-- and the health snapshot (the remaining procedures are slower and would
-- otherwise let source tables advance, creating phantom lag).
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

CREATE OR REPLACE PROCEDURE health.refresh_mat_health_all()
LANGUAGE plpgsql AS $$
BEGIN
    CALL health.refresh_mat_health_cagg_status();
    CALL health.refresh_mat_health_queue_benchmarks();
    CALL health.refresh_mat_health_trigger_stats();
    CALL health.refresh_mat_health_base_activity();
    CALL health.refresh_mat_health_base_hourly();
END;
$$;
