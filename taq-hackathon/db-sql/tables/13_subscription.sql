-- =============================================================================
-- hackathon.subscription — Slack daily-brief subscriptions
-- =============================================================================
-- One row per subscribe action. Soft-delete via unsubscribed_at; the "active"
-- subscription for an email is the most recent row with unsubscribed_at IS NULL.
-- A partial unique index guarantees at most one active row per email.
--
-- Phase-2: a Slack webhook job will iterate active rows and post the daily
-- brief's slack_digest into each (slack_workspace, slack_channel). The UI
-- flow that populates this table is live today; delivery is stubbed until
-- the webhook lands.
-- =============================================================================

CREATE TABLE IF NOT EXISTS hackathon.subscription (
    id                bigserial  PRIMARY KEY,
    email             text       NOT NULL,
    slack_workspace   text       NOT NULL,
    slack_channel     text       NOT NULL,
    frequency         text       NOT NULL DEFAULT 'daily',
    created_at        timestamptz NOT NULL DEFAULT now(),
    unsubscribed_at   timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_subscription_email_active
    ON hackathon.subscription (email)
    WHERE unsubscribed_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_subscription_created
    ON hackathon.subscription (created_at DESC);

COMMENT ON TABLE hackathon.subscription IS
  'Slack daily-brief subscriptions. Soft-delete via unsubscribed_at. At most one active row per email enforced by partial unique index. Feeds the phase-2 Slack webhook job.';
COMMENT ON COLUMN hackathon.subscription.email IS
  'Subscriber email address, lowercased.';
COMMENT ON COLUMN hackathon.subscription.slack_workspace IS
  'Slack workspace identifier (e.g. "mycompany.slack.com" or workspace ID).';
COMMENT ON COLUMN hackathon.subscription.slack_channel IS
  'Target channel, with or without leading # (canonicalised at write time).';
COMMENT ON COLUMN hackathon.subscription.frequency IS
  '''daily'' (morning brief only) or ''intraday'' (morning brief + intra-day alerts).';
COMMENT ON COLUMN hackathon.subscription.unsubscribed_at IS
  'Timestamp of unsubscribe. NULL means active. Subscriptions are never hard-deleted — audit trail is preserved.';
