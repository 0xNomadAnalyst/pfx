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

## LLM narrative (Perplexity)

The generator calls `app.generator.narrative.synthesise_narrative(payload)`
between `get_brief()` and the upsert. It's fully implemented and wired into
the frontend, but **gated on the `PERPLEXITY_API_KEY` environment variable**:

| Key state             | Behaviour                                                        |
| --------------------- | ---------------------------------------------------------------- |
| Unset                 | No-op — returns `None`, brief ships without the narrative field |
| Set, zero items fired | Returns a canned quiet-day line (no API call)                    |
| Set, items fired      | Calls Perplexity, folds the response into `payload.narrative`   |

Failure posture is fail-open: any exception is caught; the brief is still
persisted without the narrative. No SQL or frontend change is needed to
activate — just add the key to `pfx/.env.pfx.core`:

```
PERPLEXITY_API_KEY=pplx-xxxxxxxx
PERPLEXITY_MODEL=sonar          # optional override; default is "sonar"
```

The prompt tells the model to use only the provided JSON and not to search.
See [`narrative.py`](narrative.py) for the system prompt and payload shape.

## Phase-2 hooks

- `slack.py` — post a compact summary to `SLACK_WEBHOOK_URL` after successful
  upsert. Deferred; no stub yet.
