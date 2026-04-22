-- =============================================================================
-- TAQ Hackathon — schema bootstrap
-- =============================================================================
-- Creates the `hackathon` schema that holds every object the daily-brief app
-- deploys. Everything the hackathon app creates lives in this schema; nothing
-- outside it is ever written to, altered, or migrated by this project.
--
-- Teardown invariant: `DROP SCHEMA hackathon CASCADE;` removes the full
-- hackathon footprint.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS hackathon;

COMMENT ON SCHEMA hackathon IS
  'TAQ hackathon daily-brief artefacts. Read-only against dexes, kamino_lend, exponent, cross_protocol, health. Fully removable via DROP SCHEMA hackathon CASCADE.';
