# TigerData — Video Script (Short, ~4 min)

**Title:** Why I Chose PostgreSQL + TigerData for a Real-time DeFi Analytics Platform
**Version:** Short (~4 min / ~540 words spoken)
**Format:** Talking head with slide transitions noted inline

---

## Script

[ON CAMERA]

In this video I want to talk about the database layer of the platform — specifically why I chose TigerData as the database platform powering the operational intelligence behind this dashboard. They've been a great partner in this project, and I want to share the thinking behind that decision.

---

[SLIDE: Why Blockchain Data Needs ETL]

[ON CAMERA]

One characteristic of blockchain data that's easy to underestimate if you haven't worked with it before is how low-level it is. When data arrives off a blockchain, it doesn't come structured in business terms. You don't get a "swap record" with a price and a volume. You get raw instructions, account state diffs, and token balance changes.

On Solana, this is more pronounced than on most chains, because Solana's account model fragments a single logical operation across many separate accounts. A DEX pool isn't one record in a database — it's a pool state account, two token vault accounts, tick arrays for liquidity depth, potentially fee accounts. A single swap event touches all of them. The gap between what arrives off-chain and what's useful for analytics is large, and bridging it takes real ETL work.

---

[ON CAMERA]

The question is: where does that ETL live?

The answer is not in the ingestion layer. Ingestion services sit on the critical path of a real-time stream — their job is to receive data and write it to storage as fast as possible. If you push heavy computation into that layer, you create backpressure. Under load, the stream catches up to you, and you start dropping data. So the design principle is: write raw data quickly, do the transformations inside the database.

---

[SLIDE: Why PostgreSQL?]

[ON CAMERA]

Once you've decided the ETL lives in the database, the next question is what kind of database. And this is where I want to push back a bit on the assumption that a high-speed columnar analytics database is the right answer for this kind of workload.

Columnar OLAP databases are excellent at what they're designed for: bulk scans, pre-aggregated data, read-heavy analytical queries. But this workload isn't just read-heavy. It requires procedural extensibility — the ability to define custom domain logic and have it run inside the database. Trigger functions that fire at write time. Stored procedures that implement domain-specific calculations. Parameterized views that compose multiple data sources dynamically and serve flexible results to the frontend.

That kind of extensibility is native to PostgreSQL and its PL/pgSQL language. You can define exactly the logic you need — in my case, things like price impact calculations using DEX-specific math, risk metrics, and concentration measures — and have them called automatically from triggers or view functions. This keeps the transformation logic close to the data and makes the system composable and testable in a way that would be awkward or impossible in a pure columnar store.

---

[SLIDE: Database Architecture]

[ON CAMERA]

TigerData is a managed PostgreSQL platform built around the TimescaleDB extension, and that extension adds exactly what standard PostgreSQL lacks for a time-series workload like this.

Hypertables give you automatic time-based partitioning — your data is chunked by time period under the hood, which keeps queries on recent data fast without you having to manage partitioning manually. Continuous aggregates — CAGGs — are incrementally materialised views that pre-compute rollups on a schedule. In this platform, there are over twenty of them refreshing on a five-second cycle. Without pre-materialisation, every frontend query would be doing that aggregation work live against the raw data, which at any meaningful data volume wouldn't be fast enough. And TimescaleDB's columnar compression applies to historical chunks, so storage stays manageable as the dataset grows.

The pattern in practice looks like this: raw data arrives and is written to source tables — hypertables with time partitioning. Trigger functions fire at insert time to enrich that data before it lands. Continuous aggregates roll up the enriched data into pre-computed summaries. And parameterised view functions sit on top, called directly by the frontend, composing data from multiple aggregates and returning exactly what the UI needs at whatever granularity is requested — without creating separate materialised tables for every possible query variant.

The TigerData team were also proactive and hands-on throughout — they made sure I had the guidance and technical context I needed to get set up effectively.

Link in the description if you want to explore the platform.

---

## Slide Content

### Slide 1: Why Blockchain Data Needs ETL
Two-column comparison:

| What arrives off-chain | What analytics needs |
|---|---|
| Raw instructions (binary-encoded) | Prices, volumes, trade direction |
| Account state diffs | TVL, reserve ratios, liquidity depth |
| Token balance changes | Risk metrics, percentile distributions |
| Fragmented across many accounts | Clean, structured, time-aligned records |

Subtext: *On Solana, one logical operation = many accounts. The ETL gap is large.*

---

### Slide 2: Why PostgreSQL?
Three properties:

- **Procedural extensibility** — PL/pgSQL functions, trigger functions, stored procedures; complex domain logic lives in the database
- **Complex joins + window functions** — multi-CTE queries, LATERAL joins, DISTINCT ON, LOCF; data engineered into metrics on the way to the consumer
- **Full SQL ecosystem** — parameterised views, dynamic queries, composable functions; no separate tools for different query types

Subtext: *Columnar OLAP stores optimise for read-heavy bulk scans — not for ongoing procedural ETL with triggers and domain functions*

---

### Slide 3: 4-Layer Database Architecture
Vertical stack diagram:

```
[ Raw source tables ]        ← hypertables, time-partitioned
        ↓ BEFORE INSERT triggers
[ Enriched raw data ]        ← domain logic applied at write time
        ↓ Continuous aggregates (CAGGs)
[ 5-second rollups ]         ← 21 CAGGs, incrementally materialised
        ↓ Parameterised view functions
[ Frontend-ready results ]   ← any interval, any time range, on demand
        ↓
[ Dashboard ]
```

---

### Slide 4: TimescaleDB Additions
Three columns:

| Hypertables | Continuous Aggregates | Columnar Compression |
|---|---|---|
| Automatic time partitioning | Incrementally materialised views | Applied to historical chunks |
| Fast queries on recent data | Pre-computed 5-second rollups | Significant storage reduction |
| Transparent to application | Refreshed on a schedule | Keeps hot data fast |
