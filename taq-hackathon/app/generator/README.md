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

```cron
10 0 * * * cd /opt/hackathon && /opt/venv/bin/python -m app.generator.run_brief >> /var/log/hackathon-brief.log 2>&1
```

On Railway, wire this command to the platform's cron service. Same env vars
are required regardless of scheduler.

## LLM narrative + Slack digest (Perplexity)

The generator calls two synthesis functions between `get_brief()` and the
upsert, both in [`narrative.py`](narrative.py):

- `synthesise_narrative(payload)` — analyst-voice prose for the web detail
  page. Folded into `payload.narrative`.
- `synthesise_slack_digest(payload, brief_date)` — short-form Slack digest.
  The LLM produces the body; the header (title + per-section item counts)
  and footer (link to the web detail page) are assembled deterministically
  around it so typography and the URL stay on-brand. Folded into
  `payload.slack_digest`.

Both are **gated on the `PERPLEXITY_API_KEY` environment variable**:

| Key state             | Behaviour                                                                              |
| --------------------- | -------------------------------------------------------------------------------------- |
| Unset                 | No-op — brief ships with the sample placeholder narrative + Slack digest               |
| Set, zero items fired | Canned quiet-day line (no API call) for both                                           |
| Set, items fired      | Two Perplexity calls; responses fold into `payload.narrative` + `payload.slack_digest` |

Failure posture is fail-open: any exception is caught; the brief is still
persisted with the placeholder in place of the failed field. No SQL or
frontend change is needed to activate — just add the key to
`pfx/.env.pfx.core` (local dev) or the Railway service env (production):

```ini
PERPLEXITY_API_KEY=pplx-xxxxxxxx
PERPLEXITY_MODEL=sonar            # optional; default "sonar"
BRIEF_BASE_URL=https://your-app.up.railway.app   # optional; used in the Slack footer link
```

Each prompt tells the model to use only the provided JSON and not to search.
See [`narrative.py`](narrative.py) for both system prompts and payload shapes.

## Phase-2 hooks

- Slack webhook sender — drain the `hackathon.subscription` queue and post
  `payload.slack_digest` to each active workspace/channel. Deferred; the
  digest is generated and persisted today, but delivery is stubbed.
