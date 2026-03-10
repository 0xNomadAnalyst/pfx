-- =============================================================================
-- refresh_mat_health_all
-- Unified refresh procedure for all health materialised tables.
-- Calls each sub-procedure in dependency order.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

CREATE OR REPLACE PROCEDURE health.refresh_mat_health_all()
LANGUAGE plpgsql AS $$
BEGIN
    CALL health.refresh_mat_health_queue_benchmarks();
    CALL health.refresh_mat_health_trigger_stats();
    CALL health.refresh_mat_health_base_activity();
    CALL health.refresh_mat_health_cagg_status();
    CALL health.refresh_mat_health_base_hourly();
END;
$$;
