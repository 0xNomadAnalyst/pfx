-- =============================================================================
-- hackathon.brief — persisted daily briefs
-- =============================================================================
-- One row per calendar date (UTC). Payload is the structured JSON returned by
-- hackathon.get_brief(as_of). Primary key on brief_date: re-running the
-- generator for the same day overwrites via ON CONFLICT DO UPDATE.
--
-- schema_version lets the frontend tolerate old payloads if item column shape
-- changes. Bump on breaking changes.
-- =============================================================================

CREATE TABLE IF NOT EXISTS hackathon.brief (
    brief_date      date        NOT NULL PRIMARY KEY,
    generated_at    timestamptz NOT NULL DEFAULT now(),
    items_fired     int         NOT NULL DEFAULT 0,
    payload         jsonb       NOT NULL,
    schema_version  int         NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS ix_brief_generated_at
    ON hackathon.brief (generated_at DESC);

COMMENT ON TABLE hackathon.brief IS
  'One row per UTC calendar date. payload is the jsonb output of hackathon.get_brief(as_of). Idempotent: re-generating a day overwrites via ON CONFLICT.';
COMMENT ON COLUMN hackathon.brief.brief_date IS
  'UTC calendar date this brief covers (last 24h window ending at end-of-day).';
COMMENT ON COLUMN hackathon.brief.generated_at IS
  'Wall-clock timestamp at which the brief was computed and persisted.';
COMMENT ON COLUMN hackathon.brief.items_fired IS
  'Total number of brief items fired across all sections. Denormalised from payload for fast feed sort.';
COMMENT ON COLUMN hackathon.brief.payload IS
  'Structured jsonb result of hackathon.get_brief(). Keys: as_of, generated_at, items_fired, sections.{ecosystem,dexes,kamino,exponent}.{items,n_fired}.';
COMMENT ON COLUMN hackathon.brief.schema_version IS
  'Payload schema version. Increment on breaking item-shape changes; frontend tolerates older versions.';
