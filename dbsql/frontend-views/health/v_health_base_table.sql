-- =============================================================================
-- health._fn_base_table  (onyc)
-- Reads pre-materialised health.mat_health_base_activity + base_hourly.
-- No dynamic SQL / loop — pure SELECT from intermediate tables.
--
-- Two indicator columns per row, plus a summary:
--   activity_severity / activity_status — row count + gap logic (existing)
--   insert_severity   / insert_status   — mean INSERT ms from pg_stat_statements
--   summary_severity  / summary_status  — GREATEST of both; drives is_red
--
-- insert_severity = -1 (no recent timing data) does not degrade the summary.
-- GREATEST(act_sev, GREATEST(ins_sev, 0)) gives the correct behaviour.
--
-- Depends on: health.mat_health_base_activity, health.mat_health_base_hourly,
--             health.mat_health_insert_timing
--             (all refreshed by health.refresh_mat_health_all)
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

DROP VIEW  IF EXISTS health.v_health_base_table CASCADE;
DROP FUNCTION IF EXISTS health._fn_base_table();

CREATE OR REPLACE FUNCTION health._fn_base_table()
RETURNS TABLE (
    schema_name          text,
    table_name           text,
    latest_time          timestamptz,
    minutes_since_latest double precision,
    rows_last_hour       bigint,
    rows_last_24h        bigint,
    avg_rows_per_hour    double precision,
    sample_count         bigint,
    p5_hourly_count      double precision,
    p95_hourly_count     double precision,
    expected_gap_mins    double precision,
    gap_ratio            double precision,
    activity_severity    integer,
    activity_status      text,
    insert_mean_ms       double precision,
    insert_severity      integer,
    insert_status        text,
    summary_severity     integer,
    summary_status       text,
    is_red               boolean
)
LANGUAGE sql STABLE
AS $fn$
    WITH hourly_stats AS (
        SELECT
            h.schema_name,
            h.table_name,
            PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY h.row_count) AS p5,
            PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY h.row_count) AS p95
        FROM health.mat_health_base_hourly h
        WHERE h.hour > NOW() - INTERVAL '7 days'
        GROUP BY h.schema_name, h.table_name
    ),

    -- Latest insert timing per table — most recent row with an actual reading.
    -- Filtering recent_mean_ms IS NOT NULL avoids flipping when a cycle happens
    -- to record zero new calls (NULL delta); 30-minute window covers tables that
    -- INSERT infrequently without losing their last known reading.
    insert_latest AS (
        SELECT DISTINCT ON (schema_name, table_name)
            schema_name, table_name, recent_mean_ms
        FROM health.mat_health_insert_timing
        WHERE time > NOW() - INTERVAL '30 minutes'
          AND recent_mean_ms IS NOT NULL
        ORDER BY schema_name, table_name, time DESC
    ),

    enriched AS (
        SELECT
            a.schema_name,
            a.table_name,
            a.latest_time,
            EXTRACT(EPOCH FROM (NOW() - a.latest_time)) / 60.0                 AS msl,
            a.rows_last_hour,
            a.rows_last_24h,
            a.avg_rows_per_hour,
            a.sample_count,
            COALESCE(hs.p5, 0)                                                  AS p5,
            COALESCE(hs.p95, 0)                                                 AS p95,
            a.expected_gap_mins                                                 AS egm,
            CASE WHEN a.expected_gap_mins IS NOT NULL AND a.expected_gap_mins > 0
                 THEN (EXTRACT(EPOCH FROM (NOW() - a.latest_time)) / 60.0)
                      / a.expected_gap_mins
                 ELSE NULL
            END                                                                 AS gr,
            il.recent_mean_ms                                                   AS ins_ms
        FROM health.mat_health_base_activity a
        LEFT JOIN hourly_stats  hs ON a.schema_name = hs.schema_name
                                  AND a.table_name  = hs.table_name
        LEFT JOIN insert_latest il ON a.schema_name = il.schema_name
                                  AND a.table_name  = il.table_name
        WHERE a.latest_time IS NOT NULL
    ),

    -- Compute per-dimension severities before final projection
    scored AS (
        SELECT
            e.*,
            -- Activity severity (row count + gap logic — unchanged)
            CASE
                WHEN e.rows_last_hour = 0 AND e.avg_rows_per_hour >= 10
                     AND (e.egm IS NULL OR e.egm < 60)                         THEN 3
                WHEN e.egm IS NOT NULL AND e.egm > 0 THEN
                    CASE WHEN e.gr <= 2.0 THEN 0
                         WHEN e.gr <= 3.0 THEN 1
                         WHEN e.gr <= 5.0 THEN 2
                         ELSE 3 END
                WHEN e.msl <= 720  THEN 0
                WHEN e.msl <= 1440 THEN 1
                WHEN e.msl <= 4320 THEN 2
                ELSE 3
            END AS act_sev,
            -- Insert timing severity (-1 = no data, will not degrade summary)
            CASE
                WHEN e.ins_ms IS NULL  THEN -1
                WHEN e.ins_ms <    50  THEN  0
                WHEN e.ins_ms <   500  THEN  1
                WHEN e.ins_ms <  5000  THEN  2
                ELSE                         3
            END AS ins_sev
        FROM enriched e
    )

    SELECT
        s.schema_name,
        s.table_name,
        s.latest_time,
        s.msl,
        s.rows_last_hour,
        s.rows_last_24h,
        s.avg_rows_per_hour,
        s.sample_count,
        s.p5,
        s.p95,
        s.egm,
        s.gr,
        -- Activity indicator
        s.act_sev,
        CASE s.act_sev
            WHEN 0 THEN 'Active'  WHEN 1 THEN 'Check'
            WHEN 2 THEN 'Stale'   ELSE        'ANOMALY'
        END,
        -- Insert timing indicator
        s.ins_ms,
        s.ins_sev,
        CASE
            WHEN s.ins_sev = -1 THEN NULL
            WHEN s.ins_sev =  0 THEN 'NORMAL'
            WHEN s.ins_sev =  1 THEN 'ELEVATED'
            WHEN s.ins_sev =  2 THEN 'HIGH'
            ELSE                     'ANOMALY'
        END,
        -- Summary: worst of both (-1 treated as 0 so no-data never degrades)
        GREATEST(s.act_sev, GREATEST(s.ins_sev, 0)),
        CASE GREATEST(s.act_sev, GREATEST(s.ins_sev, 0))
            WHEN 0 THEN 'NORMAL'  WHEN 1 THEN 'ELEVATED'
            WHEN 2 THEN 'HIGH'    ELSE        'ANOMALY'
        END,
        GREATEST(s.act_sev, GREATEST(s.ins_sev, 0)) >= 3
    FROM scored s
    ORDER BY s.schema_name, s.msl DESC;
$fn$;

CREATE OR REPLACE VIEW health.v_health_base_table AS
SELECT * FROM health._fn_base_table();
