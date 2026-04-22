-- =============================================================================
-- Add slack_webhook_url to hackathon.subscription
-- =============================================================================
-- The webhook URL is the actual contract for delivery (each Slack incoming
-- webhook is bound to a channel at creation time, so the URL determines where
-- messages land). The `slack_channel` column stays as a display label.
--
-- Idempotent: uses `IF NOT EXISTS`.
-- =============================================================================

ALTER TABLE hackathon.subscription
    ADD COLUMN IF NOT EXISTS slack_webhook_url text;

COMMENT ON COLUMN hackathon.subscription.slack_webhook_url IS
  'Slack incoming-webhook URL used for delivery. Sensitive — anyone with this URL can post to the channel it is bound to. Format: https://hooks.slack.com/services/...';
