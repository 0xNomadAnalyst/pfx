-- =============================================================================
-- Slack "Add to Slack" OAuth support for hackathon.subscription
-- =============================================================================
-- Two-phase flow:
--   phase-1  /api/subscribe inserts a row with pending_token (opaque OAuth
--            state) and no webhook/workspace/channel yet.
--   phase-2  /slack/oauth/callback exchanges the Slack code for a webhook
--            URL + team + channel and fills those in, clearing the token.
--
-- last_sent_brief_date is the sender-side idempotency flag — a manual re-run
-- of the cron on the same brief_date will not double-post.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS + ALTER COLUMN DROP NOT NULL is a
-- no-op when already applied.
-- =============================================================================

ALTER TABLE hackathon.subscription
    ADD COLUMN IF NOT EXISTS pending_token        text,
    ADD COLUMN IF NOT EXISTS last_sent_brief_date date;

-- Workspace + channel arrive from the Slack OAuth callback, not the form,
-- so phase-1 rows have them NULL until the callback lands.
ALTER TABLE hackathon.subscription
    ALTER COLUMN slack_workspace DROP NOT NULL,
    ALTER COLUMN slack_channel   DROP NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ux_subscription_pending_token
    ON hackathon.subscription (pending_token)
    WHERE pending_token IS NOT NULL;

COMMENT ON COLUMN hackathon.subscription.pending_token IS
  'Opaque token used as the Slack OAuth state parameter during the phase-1 -> callback handoff. NULL once the webhook URL is persisted or the row is unsubscribed.';
COMMENT ON COLUMN hackathon.subscription.last_sent_brief_date IS
  'Date of the most recently delivered daily brief for this subscription. Sender skips rows whose last_sent_brief_date already matches today''s brief_date to avoid double-posts on cron re-runs.';
