# ONyc Daily Brief — TAQ hackathon

A daily briefing web viewer that reports shifts over the last 24 hours
across the ONyc ecosystem (Ecosystem, DEXes, Kamino, Exponent). Sits on
top of the production ONyc substrate as read-only; everything the app
creates is isolated in the `hackathon` schema.

## Layout

```
pfx/taq-hackathon/
├── brief-focus-points.md       # the 22 items the brief reports on
├── concept-daily-brief.md      # product concept
├── project-brief.md            # AI-agent context
├── db-sql/                     # isolated DDL
│   ├── 00_schema.sql
│   ├── tables/                 # brief_config, brief, seed
│   ├── views/
│   │   ├── dexes/, kamino/, exponent/, ecosystem/
│   │   └── sections/           # section collectors
│   ├── functions/              # cfg helpers + get_brief
│   ├── verify_isolation.sql    # schema-isolation guardrail
│   └── deploy.py               # apply / teardown / reset / dry-run
└── app/                        # FastAPI + Jinja + htmx viewer
    ├── main.py                 # two routes: feed + detail
    ├── db.py                   # psycopg connection
    ├── generator/run_brief.py  # brief-generator CLI
    ├── pages/, templates/, static/
    ├── Dockerfile, requirements.txt, start.sh
```

## Five-minute demo sequence

The project is self-contained: a local `.venv` under `pfx/taq-hackathon/.venv`
is created by the bootstrap script, and every wrapper script
(`deploy.sh`, `run_brief.sh`, `start.sh`) uses that venv directly. No need to
activate anything or install packages into your shell's Python.

```bash
cd pfx/taq-hackathon

# 0. One-time setup — creates .venv and installs deps
bash bootstrap.sh

# 1. Deploy the hackathon schema (apply + reset is idempotent)
bash db-sql/deploy.sh --apply --reset --yes

# 2. Generate today's brief
bash app/run_brief.sh

# 3. Serve
bash app/start.sh
# Browse http://localhost:8003/
```

Creds are loaded from `pfx/.env.pfx.core` by every script (same contract).

### Teardown / reset

```bash
bash db-sql/deploy.sh --teardown --yes           # drop hackathon schema
rm -rf .venv                                     # remove the local venv
```

Expected layout at `/`: a chronological feed of past briefs with section
badges showing items fired per section. Click any row to view the detail —
headlines, deltas, and refs per item organised under the four sections.

## Teardown

```bash
cd pfx/taq-hackathon/db-sql
python deploy.py --teardown --yes
```

`DROP SCHEMA hackathon CASCADE;` removes the full footprint. Nothing in
`dexes`, `kamino_lend`, `exponent`, `cross_protocol`, or `health` is ever
written to.

## Substrate dependencies (read-only)

| Schema           | Objects used |
|------------------|---|
| `cross_protocol` | `mat_xp_last`, `mat_xp_ts_1m` (E1–E5) |
| `dexes`          | `mat_dex_last`, `mat_dex_timeseries_1m`, `cagg_events_5s`, `risk_pvalues`, `pool_tokens_reference` (D1–D6) |
| `kamino_lend`    | `mat_klend_last_reserves`, `mat_klend_last_obligations`, `mat_klend_last_activities`, `mat_klend_reserve_ts_1m`, `src_obligations_last`, `cagg_activities_5s` (K1–K6) |
| `exponent`       | `mat_exp_last`, `mat_exp_timeseries_1m`, `aux_key_relations`, `cagg_tx_events_5s` (X1–X5) |

Thresholds for every item live in `hackathon.brief_config` and can be tuned
via SQL `UPDATE` without a redeploy. See
`db-sql/tables/12_seed_brief_config.sql` for shipped defaults.

## Not in v1 (phase-2)

- **LLM narrative synthesis** at the top of each brief.
- **Slack webhook delivery** of the daily brief to a channel.
- **Weekly rollup** (`/rollup/<week>` aggregating 7 daily briefs).
- **Threshold admin UI** (currently thresholds are tuned via SQL only).
