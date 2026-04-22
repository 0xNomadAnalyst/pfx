-- =============================================================================
-- Schema-isolation guardrail
-- =============================================================================
-- Any row returned by this query is a bug: it means the hackathon schema
-- depends on an external schema that is not on the allowed list. Run this
-- after every deploy.
-- =============================================================================

SELECT DISTINCT n.nspname AS referenced_schema
FROM pg_depend d
    JOIN pg_rewrite r   ON d.objid         = r.oid
    JOIN pg_class   c   ON r.ev_class      = c.oid
    JOIN pg_namespace hn ON c.relnamespace  = hn.oid
    JOIN pg_class   rc  ON d.refobjid      = rc.oid
    JOIN pg_namespace n  ON rc.relnamespace = n.oid
WHERE hn.nspname = 'hackathon'
  AND n.nspname NOT IN ('hackathon','dexes','kamino_lend','exponent','cross_protocol','health','pg_catalog','public')
ORDER BY n.nspname;
