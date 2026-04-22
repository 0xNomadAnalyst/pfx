# Brief generator

CLI that invokes `hackathon.get_brief(as_of)` and upserts the result into
`hackathon.brief`. One row per UTC calendar date; re-running the same day
overwrites.

## Usage

```bash
# From pfx/taq-hackathon/
python -m app.generator.run_brief                  # today (UTC)
python -m app.generator.run_brief --date 2026-04-21
python -m app.generator.run_brief --dry-run        # prints payload, no write
```

Creds come from `pfx/.env.pfx.core` — same contract as `db-sql/deploy.py`.
Fail-closed: on exception, exits 1 and leaves the `hackathon.brief` table
untouched.

## Scheduling

Not wired in v1 — the CLI is the unit of work. To run daily at 00:10 UTC, add
a cron entry on the host:

```
10 0 * * * cd /opt/hackathon && /opt/venv/bin/python -m app.generator.run_brief >> /var/log/hackathon-brief.log 2>&1
```

On Railway, wire this command to the platform's cron service. Same env vars
are required regardless of scheduler.

## Phase-2 hooks

- `slack.py` — post a compact summary to `SLACK_WEBHOOK_URL` after successful
  upsert. Deferred; no stub yet.
- LLM narrative — fold a `synthesise_narrative(payload) -> text` call in
  between `get_brief()` and the upsert, writing the prose into
  `payload.narrative`. The frontend already has a slot for a top-of-page
  narrative paragraph (see `app/templates/detail.html`).
