-- =============================================================================
-- mat_health_queue_benchmarks
-- Pre-computes 7-day P95 benchmarks (staleness, utilization, failures) per
-- domain/queue_name. Eliminates the expensive PERCENTILE_CONT scans that
-- previously ran on every request to v_health_queue_table.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

CREATE TABLE IF NOT EXISTS health.mat_health_queue_benchmarks (
    domain                       TEXT NOT NULL,
    queue_name                   TEXT NOT NULL,
    p95_staleness_7d             DOUBLE PRECISION,
    p95_utilization_pct_7d       DOUBLE PRECISION,
    p95_consecutive_failures_7d  DOUBLE PRECISION,
    refreshed_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (domain, queue_name)
);

-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE health.refresh_mat_health_queue_benchmarks()
LANGUAGE plpgsql AS $$
DECLARE
    _schema RECORD;
BEGIN
    TRUNCATE health.mat_health_queue_benchmarks;

    FOR _schema IN
        SELECT * FROM (VALUES
            ('dexes'),
            ('exponent'),
            ('kamino_lend')
        ) AS s(name)
    LOOP
        BEGIN
            EXECUTE format(
                $q$INSERT INTO health.mat_health_queue_benchmarks
                   (domain, queue_name, p95_staleness_7d,
                    p95_utilization_pct_7d, p95_consecutive_failures_7d, refreshed_at)
                 SELECT %L, queue_name,
                        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY seconds_since_last_write),
                        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY queue_utilization_pct),
                        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY consecutive_failures),
                        NOW()
                 FROM %I.queue_health
                 WHERE time > NOW() - INTERVAL '7 days'
                   AND seconds_since_last_write IS NOT NULL
                 GROUP BY queue_name$q$,
                _schema.name, _schema.name
            );
        EXCEPTION WHEN undefined_table THEN
            NULL;
        END;
    END LOOP;
END;
$$;
