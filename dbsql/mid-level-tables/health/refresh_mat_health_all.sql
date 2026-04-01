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
    -- Each COMMIT makes the preceding sub-procedure durable, so a failure
    -- in a later step (e.g. OOM in base_hourly) cannot roll back earlier work.
    CALL health.refresh_mat_health_cagg_status();
    COMMIT;

    CALL health.refresh_mat_health_queue_benchmarks();
    COMMIT;

    CALL health.refresh_mat_health_trigger_stats();
    COMMIT;

    CALL health.refresh_mat_health_base_activity();
    COMMIT;

    CALL health.refresh_mat_health_insert_timing();
    COMMIT;

    -- base_hourly last: heaviest step and most likely to OOM.
    CALL health.refresh_mat_health_base_hourly();
END;
$$;
