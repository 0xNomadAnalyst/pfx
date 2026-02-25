-- =============================================================================
-- health.v_health_master_table
-- Master binary health summary — one row per domain + one MASTER row
-- RED = at least one critical indicator in any section
-- GREEN = everything else (tolerates ELEVATED and HIGH)
--
-- Depends on: health.v_health_queue_table, health.v_health_trigger_table,
--             health.v_health_base_table, health.v_health_cagg_table
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

DROP VIEW IF EXISTS health.v_health_master_table CASCADE;
CREATE OR REPLACE VIEW health.v_health_master_table AS

WITH domains AS (
    SELECT unnest(ARRAY['dexes','exponent','kamino_lend']) AS domain
),

domain_labels AS (
    SELECT * FROM (VALUES
        ('dexes',                'DEXes'),
        ('exponent',             'Exponent'),
        ('kamino_lend',          'Kamino')
    ) AS t(domain, domain_label)
),

-- Worst queue status per domain (is_red = summary_severity >= 3)
queue_agg AS (
    SELECT domain, BOOL_OR(is_red) AS queue_red
    FROM health.v_health_queue_table
    GROUP BY domain
),

-- Worst trigger status per domain
trigger_agg AS (
    SELECT domain, BOOL_OR(is_red) AS trigger_red
    FROM health.v_health_trigger_table
    GROUP BY domain
),

-- Worst base table status per domain
base_agg AS (
    SELECT schema_name AS domain, BOOL_OR(is_red) AS base_red
    FROM health.v_health_base_table
    GROUP BY schema_name
),

-- Worst CAGG status per domain
cagg_agg AS (
    SELECT view_schema AS domain, BOOL_OR(is_red) AS cagg_red
    FROM health.v_health_cagg_table
    GROUP BY view_schema
),

domain_summary AS (
    SELECT
        d.domain,
        dl.domain_label,
        COALESCE(q.queue_red,   false) AS queue_red,
        COALESCE(t.trigger_red, false) AS trigger_red,
        COALESCE(b.base_red,    false) AS base_red,
        COALESCE(c.cagg_red,    false) AS cagg_red,
        COALESCE(q.queue_red, false)
            OR COALESCE(t.trigger_red, false)
            OR COALESCE(b.base_red, false)
            OR COALESCE(c.cagg_red, false) AS domain_red
    FROM domains d
    LEFT JOIN domain_labels dl ON d.domain = dl.domain
    LEFT JOIN queue_agg     q  ON d.domain = q.domain
    LEFT JOIN trigger_agg   t  ON d.domain = t.domain
    LEFT JOIN base_agg      b  ON d.domain = b.domain
    LEFT JOIN cagg_agg      c  ON d.domain = c.domain
),

all_rows AS (
    -- Domain rows
    SELECT
        domain,
        domain_label,
        queue_red,
        trigger_red,
        base_red,
        cagg_red,
        domain_red                                          AS is_red,
        CASE WHEN domain_red THEN 'RED' ELSE 'GREEN' END   AS status,
        CASE domain
            WHEN 'dexes'                THEN 1
            WHEN 'exponent'             THEN 2
            WHEN 'kamino_lend'          THEN 3
        END AS sort_order
    FROM domain_summary

    UNION ALL

    -- Master summary row (worst across all domains)
    SELECT
        'MASTER',
        'MASTER',
        BOOL_OR(queue_red),
        BOOL_OR(trigger_red),
        BOOL_OR(base_red),
        BOOL_OR(cagg_red),
        BOOL_OR(domain_red),
        CASE WHEN BOOL_OR(domain_red) THEN 'RED' ELSE 'GREEN' END,
        0
    FROM domain_summary
)

SELECT domain, domain_label, queue_red, trigger_red, base_red, cagg_red, is_red, status
FROM all_rows
ORDER BY sort_order;
