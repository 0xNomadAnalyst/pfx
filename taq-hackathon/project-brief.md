# TAQ Hackathon — AI Agent Project Brief

This document is the context pack for AI coding agents assisting with a hackathon entry for **The Accountant Quits (TAQ)**. It does not specify the project itself — that will be decided in a separate prompt. Read this first on any new session; treat it as the source of truth for *why* we are building, *for whom*, and *what substrate* is already in place.

---

## 1. The Hackathon

- **Host:** The Accountant Quits (TAQ) — a community for people working at the intersection of accounting, finance, and crypto / Web3.
- **Prompt:** Build a working proof-of-concept that uses AI to solve a real problem in **crypto accounting or onchain finance**. It does not need to be production-ready. It needs to show: a clear problem, a creative solution, and evidence you actually built something.
- **Format:** Solo or small team. Kickoff → one build week → demo day → community vote (3 votes per member, no self-voting). Winner = most votes.
- **Prerequisites assumed by organisers:** none — "no coding experience required." Most participants will be vibe-coding. We are not most participants.
- **Example ideas they floated** (so we can see the audience's current mental model):
  - AI agent that categorises onchain transactions automatically
  - Tool that reconciles DeFi activity for accounting purposes
  - Dashboard that explains crypto treasury movements
  - AI assistant that answers crypto tax questions
  - Automated reporting tool for Web3 CFOs

### Audience profile

The voters and the broader TAQ following are:
- Accountants, controllers, and fractional CFOs moving into Web3.
- Finance operators at DAOs, protocols, and crypto-native funds.
- Tax and audit professionals dealing with onchain activity.
- Tool-builders and content creators in the crypto-finance niche.

They are **domain-fluent in finance/accounting**, **partially fluent in onchain mechanics**, and in many cases **non-technical**. Explanations must privilege the finance reader. "DEX CLMM tick array" is jargon; "liquidity that lives at specific price ranges" is language.

---

## 2. Strategic Goal (the reason this project exists)

The hackathon is a **marketing vehicle**, not an end in itself. The participant is a contractor whose edge is:

1. **Designing structured, richly-annotated databases for onchain data** — schemas that function as executable documentation and compress months of domain work into a queryable layer.
2. **Decoding protocols and turning raw chain data into meaningful, higher-level, actionable metrics** — not just ingesting, but *engineering* data on its path to consumption.
3. **Extracting leverage from that substrate** — once the data is shaped correctly, apps, dashboards, risk tools, and reports become cheap and fast to produce.

The submission must make this visible **implicitly through the work**, not through a pitch slide. The voter should walk away thinking:

> "Whoever built this has a database behind it that the rest of us don't, and that's why the app could exist in a week."

### The thesis to dramatise

"**A well-structured, well-labelled database is the real moat in the age of AI-assisted development.** Context engineering at the data layer — not in the prompt — is what lets a one-person team ship a polished, accurate analytics product in days. This is one of the biggest emerging shifts in data engineering, and it is barely on the radar of most crypto-finance tool-builders."

Content creators in the data/AI space (dlt, dbt, DuckDB, Hex, Preset, various LLM-tooling voices) are beginning to talk about this. The TAQ audience has mostly not heard it yet. We are early-signalling to them.

### What "winning" actually looks like

Optimise the submission against these, in order:

1. **Resonance with the TAQ audience** — the demo should feel useful to an accountant/CFO, not to a Solana dev.
2. **Credibility of the underlying work** — the app should visibly rest on something substantial (the database), not on a single ChatGPT call.
3. **Clarity of the narrative** — one clean sentence the voter can repeat to someone else about what this is and why it matters.
4. **Polish and completeness** — works end-to-end, reads well, no broken states during the 2–3 minute demo.
5. **Vote count** — downstream of the above.

---

## 3. Available Infrastructure

The contractor owns and operates a production-grade risk-monitoring platform for the **ONyc** DeFi ecosystem on Solana. It is already deployed, already running, and already producing a dashboard (see dashboard screenshots provided alongside this brief). We are **not rebuilding any of it**. The hackathon app will sit on top of it.

### 3.1 The database

A single TimescaleDB (Tiger Data Cloud) instance with protocol-isolated schemas:

| Schema | Protocol domain |
|---|---|
| `dexes` | Orca Whirlpool + Raydium CLMM (concentrated-liquidity AMMs) |
| `kamino_lend` | Kamino Lending (reserves, obligations, activity) |
| `exponent` | Exponent PT/YT yield-tokenisation markets |
| `health` | Cross-domain pipeline health monitoring |

**What makes this substrate distinctive:**

- **Every table and most columns carry `COMMENT ON` annotations** describing source, units, scaling, and processing rules. The SQL is the authoritative documentation. An LLM reading the schema gets the same context a human operator would.
- **Naming discipline** — raw IDL fields use `snake_case` from the original protocol structs; derived fields are prefixed `c_` to distinguish computed values from on-chain data. `src_*` = raw source tables, `cagg_*_5s` = 5-second continuous aggregates, `aux_*` = lookup tables, `get_view_*()` = parameterised view functions, `v_*` = views, `risk_*` = risk policy tables.
- **Three-layer ETL in the database:** source hypertables → 5-second continuous aggregates → parameterised SQL view functions. The frontend calls functions, not tables — time windows, grains, and filters are parameters.
- **Domain-specific SQL functions already exist** for non-trivial calculations: CLMM price-impact simulation via tick traversal, Pendle AMM PT pricing, Kamino risk sensitivity arrays (LTV/health factor stress), TVL-weighted cross-pool impact, borrow rate curves, empirical p-value distributions for sell events.
- **Risk tables already populated:** versioned risk policy configurations and daily-refreshed percentile distributions for sell magnitudes across six time horizons (5m / 15m / 30m / 1h / 6h / 24h).
- **Continuous five-second cadence** with 90-day retention on aggregates; longer history available on source tables.

This is the asset. A hackathon app that queries this database can produce answers that would take a normal builder weeks to get to even raw data for.

### 3.2 The existing dashboard

Already built and visible in the demo screenshots. Covers:

- **Cover / ecosystem overview** — ONyc issuance, supply deployment across venues, yields comparison, TVL and activity distribution.
- **DEX Pools** — liquidity distribution, depth curves, LP flows, swap metrics, price impact, event distributions for Orca and Raydium.
- **Kamino Lend** — reserve balances, borrow rate curves, utilisation, debt characteristics, liquidation stress tests, obligation watchlist.
- **Exponent Yield** — PT/YT market metrics, fixed vs variable rate spreads, AMM capital flows, yield trading activity by maturity.
- **Risk Analysis** — extreme sell event distributions, downside liquidity exhaustion, cross-protocol exposure, liquidation cascade amplification.
- **System Health** — queue health, CAGG refresh status, base table activity, trigger freshness, anomaly detection.

### 3.3 Implication for the hackathon app

We do **not** compete with the existing dashboard. The existing dashboard is a Solana-risk-analyst tool. The hackathon app is a **different artefact for a different audience**, built from the same substrate, to demonstrate that once the substrate exists, the next use-case is a few days of work — not a quarter.

The concept is likely going to be re-skinned / re-labelled so the TAQ audience sees it through a finance/accounting lens, not a crypto-risk-desk lens. Tokens may be represented with synthetic or illustrative branding to keep the focus on methodology rather than a specific live ecosystem. Treat the database as a generic Solana-DeFi substrate in any user-facing copy unless told otherwise.

---

## 4. Narrative Anchors (use these when drafting copy, docs, demo scripts)

When you generate user-facing text, landing pages, READMEs, or demo scripts, bias toward these framings:

- **"Context engineering at the data layer."** The reason this app could be built in a week is that the database already encodes the domain. The schema is the system prompt.
- **"The moat is the schema, not the model."** Any LLM can be pointed at this data. Few teams have data shaped like this to point an LLM at.
- **"Accounting-grade answers from onchain data."** The platform is already designed for risk monitoring, where being wrong has a cost. That discipline carries over.
- **"From raw chain bytes to auditable metrics."** The pipeline decodes Borsh, reconstructs fees from balance deltas, classifies activity, timestamps in block-time, and annotates every column. The result is something an accountant can actually cite.

Avoid:
- Crypto-trader or Solana-dev language as primary voice. Translate before showing.
- Over-claiming production-grade reliability for the hackathon app itself; do claim it for the substrate it sits on.
- Mentioning specific client names unless explicitly cleared.

---

## 5. Operating Principles for AI Agents on this Project

- **The database is the product's backbone. Query it, don't rebuild it.** If a needed metric does not exist as a function or CAGG, first check whether one already covers it (inline `COMMENT ON` annotations in `<service>/dbsql/` are the reference). Only compose new SQL on top; do not duplicate existing logic.
- **Read-only posture toward the database.** The hackathon app must not write to, alter, or migrate any production schemas (`dexes`, `kamino_lend`, `exponent`, `health`, or their CAGGs, view functions, or auxiliary tables). Every artefact the hackathon app creates — views, functions, tables — lives in a dedicated `hackathon` schema. DDL source of truth is [`db-sql/`](db-sql/); see [`db-sql/README.md`](db-sql/README.md) for the full conventions. Connection credentials come from `D:\dev\mano\risk_dash\pfx\.env.pfx.core`.
- **Favour speed of delivery over abstraction.** Build week is a week. No half-finished scaffolding, no future-proof abstractions, no test harnesses unless essential to the demo. If three similar pages do the trick, ship three pages — don't build a page framework.
- **Every user-facing surface must read to a non-technical finance person.** Label charts in finance language. Explain inputs in a sentence. Assume the viewer has never heard of a CLMM.
- **Where the app leans on existing work, say so — factually, not boastfully.** "Powered by a pre-existing continuously-ingested Solana analytics database" is honest and reinforces the thesis. "Built from scratch in a week" is both untrue and off-message.
- **Design, typography, and polish matter disproportionately.** The audience will not read the SQL. They will read the landing page, watch a 2-minute demo, and vote. A polished surface on a deep substrate sells the thesis. A crude surface on a deep substrate looks like everyone else's vibe-coded submission.
- **When in doubt about direction, ask.** The project scope is set in a separate prompt, not here. Do not guess what the app is — request the scoping prompt before scaffolding.

---

## 6. Reference Documents

For deep dives into the existing platform (loaded into the initiating conversation, not duplicated here):

| Doc | Covers |
|---|---|
| `00-GENERAL.md` | Platform overview, architecture, repository map |
| `01-INGESTION.md` | Python ingestion services, shared patterns |
| `02-DATABASE.md` | In-database ETL, schema design, CAGGs, view functions |
| `03-FRONTEND.md` | Existing dashboard services (HTMX UI + cached API) |
| `04-RESILIENCE.md` | Health monitoring, recovery, pipeline observability |
| `05-DEPENDENCIES.md` | External services (Shyft, Tiger Data, Clerk, etc.) |

These live in `d:\dev\mano\risk_dash\handover-docs-260300\`. SQL files under `<service>/dbsql/` are the authoritative schema reference.
