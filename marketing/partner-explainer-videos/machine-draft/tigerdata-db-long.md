# TigerData — Video Script (Long, ~10 min)

**Title:** The Database Layer of a Real-time DeFi Risk Platform — Why TigerData
**Version:** Long (~10 min / ~1,300 words spoken)
**Format:** Talking head with slide transitions noted inline

---

## Script

[ON CAMERA]

In this video I want to go deep on the database layer of the platform — the choices I made, the tradeoffs I considered, and why TigerData ended up being the right fit. They're the database platform powering the operational intelligence behind this dashboard, and they've been a genuinely great partner throughout this build.

Let's start from first principles, because I think the reasoning is interesting and it applies to anyone building serious analytics on blockchain data.

---

[SLIDE: Why Blockchain Data Needs ETL]

[ON CAMERA]

Blockchain data is fundamentally low-level. Unlike a traditional application database, where your application writes structured records that directly represent business concepts, blockchain data is a log of state transitions at the protocol layer. You don't get a "swap record" with a price, volume, and direction. You get raw instructions, account state diffs, and token balance changes — and it's your job to reconstruct the business events from those primitives.

On Solana, this is more pronounced than on most other chains. Solana's account model is designed for parallel execution, which means state is distributed across many small accounts rather than stored in a few large ones. A DEX pool isn't a single record — it's a pool state account holding the current price and liquidity curve parameters, two separate token vault accounts holding the actual reserves, a series of tick array accounts that define the full liquidity distribution across the price range, and potentially additional accounts for fees and protocol configuration. When a swap happens, multiple accounts change simultaneously, and you need all of them to reconstruct what occurred.

This fragmentation is one of the reasons Solana can achieve the throughput it does — but it means that for analytics purposes, the ETL burden is unusually high. The gap between raw on-chain data and analytics-ready measures is large, and closing it is where most of the real engineering effort in this kind of platform lives.

---

[ON CAMERA]

So where does that ETL work happen?

The first instinct might be to handle it at ingestion — decode, transform, and write clean records directly from the data stream. And for simple cases, that works. But for anything computationally non-trivial, it's the wrong design.

Here's why. Ingestion services sit on the critical path of a real-time stream. Their job is to receive data from the blockchain as fast as it's produced and write it to storage without falling behind. If you push heavy computation into that layer — loading supporting data, running complex calculations, joining against existing records — you introduce latency that competes with the incoming stream. Under peak load, the computation can't keep pace with the data rate, backpressure builds, and you start dropping events. On a chain like Solana that's producing thousands of transactions per second, the margin for inline computation is tight.

The right design separates concerns: write raw data fast, and do the transformation work asynchronously inside the database. The raw data is the ground truth. The ETL produces the derived measures. And the database — with its own compute resources, transaction isolation, and access to all historical state — is the right place for that second step.

---

[SLIDE: Why PostgreSQL?]

[ON CAMERA]

Once you've committed to doing the ETL inside the database, you need to choose the right database. And this is where I want to explain a choice that might not be obvious at first.

If you've been around the data engineering world recently, you've heard a lot about columnar databases — ClickHouse, DuckDB, BigQuery, Redshift. They're genuinely excellent for their intended use case: bulk analytical queries over large datasets, pre-aggregated rollups, fast scans on specific columns. If your workload is "run this dashboard query over 100 million rows once a minute", a columnar store is hard to beat.

But that's not what this workload looks like. This workload requires ongoing, procedural, stateful ETL that happens continuously as data arrives. And for that, columnar stores have significant limitations. They typically don't support trigger functions — logic that fires automatically when data is inserted. They have limited or no support for stored procedures with complex control flow. Their function extensibility is constrained. They're optimised for reading, not for the kind of write-time enrichment and transformation that this architecture depends on.

PostgreSQL is different. It's a fully extensible relational database with a mature procedural language — PL/pgSQL — built in. You can define functions that implement arbitrarily complex domain logic and have them called automatically from triggers at write time, or invoked from view functions at read time. These functions have full access to database state, can perform joins against other tables, and execute inside transactions with proper isolation.

For this platform, that extensibility is essential. There's domain-specific mathematical logic — calculations derived from how concentrated liquidity DEXes work, how lending market risk scales, how to measure liquidity depth in terms that are meaningful for risk analysis — that needs to run inside the database, called from triggers and views, without that logic needing to live in the application layer. PostgreSQL makes this natural. A columnar store would make it impossible or require a completely different architectural approach.

There's also the query complexity to consider. The view functions that serve the frontend aren't simple scans. They combine data from multiple continuous aggregates, join against reference tables, apply window functions for things like carrying the last observed value forward across time gaps, and return results bucketed at whatever time granularity the user has selected. Multi-CTE queries with lateral joins and dynamic bucketing. This is the full expressive power of SQL being used to engineer data into metrics of interest at query time, rather than pre-materialising every possible view. PostgreSQL handles this naturally. It's what it was built for.

---

[SLIDE: Database Architecture]

[ON CAMERA]

Now let me walk through how this actually works in practice, because the architecture is worth understanding in some detail.

The bottom layer is the source tables. These are hypertables — a TimescaleDB concept that I'll come back to — but for now think of them as the raw record store. Data arrives from the ingestion services and lands here quickly, with minimal transformation at write time.

What makes this layer interesting is the trigger functions. Before a row is even committed to the table, a trigger fires and enriches it. In the DEX service, for example, a swap event that arrives from the blockchain doesn't initially carry a price impact figure — calculating that requires knowledge of the current liquidity distribution across the pool's tick range. The trigger function looks up the current liquidity snapshot, runs the necessary calculation, and embeds the result in the row before it lands. By the time the row is committed, it already carries the enriched data. This runs atomically, inside the same transaction, and it's transparent to the ingestion service — the trigger is entirely a database-layer concern.

On top of the source tables sit the continuous aggregates — CAGGs. These are incrementally materialised views, a TimescaleDB feature that pre-computes rollups and keeps them current as new data arrives. In this platform there are over twenty of them, refreshing every five seconds. They aggregate the raw event data into five-second buckets — swap volumes, liquidity metrics, pool state snapshots, price-impact distributions. Without pre-materialisation, every frontend query would be doing that aggregation work live against the full raw history, and at any meaningful data volume that wouldn't be fast enough for an interactive dashboard.

The key property of continuous aggregates is that they're incremental — only new data is recomputed, not the full history. So a five-second refresh doesn't re-aggregate everything; it adds the new five-second window to existing materialisations. This is what makes it viable to run this many aggregates at this refresh frequency.

On top of the aggregates sit the parameterised view functions. These are SQL functions — callable like any database function — that accept parameters like time interval and row count and compose results from multiple continuous aggregates into a single response. The frontend calls one of these functions with its desired granularity and time range, and gets back exactly what it needs, whether that's five-second bars for a live view or hourly bars for a historical chart. The same underlying aggregates serve both cases, with no separate tables per granularity. That's the "no unnecessary materialising" principle in practice — the data is pre-aggregated at five-second resolution, and view functions re-bucket upward on the fly.

---

[SLIDE: TimescaleDB + TigerData Platform]

[ON CAMERA]

Let me briefly cover what TimescaleDB specifically adds beyond standard PostgreSQL, since that's the engine under the hood.

Hypertables are the partitioning layer. They look like normal PostgreSQL tables but are automatically partitioned by time under the hood — each time chunk is a separate physical partition. This keeps index sizes manageable, makes chunk-level compression possible, and ensures queries over recent time ranges stay fast even as the total dataset grows.

Columnar compression applies to historical chunks — older time windows that are no longer being written to. TimescaleDB compresses these using a columnar format, which can reduce storage by a large factor, and queries against compressed chunks are often faster than against uncompressed row-format data for the kind of aggregation queries typical in analytics.

And tiered storage takes this further — historical compressed chunks can be moved automatically to object storage, keeping the hot compute tier focused on recent data while cold historical data remains queryable at lower cost.

TigerData as a managed platform adds the operational layer on top of all of this: connection pooling, automated backups, point-in-time recovery, monitoring, and the option of high-availability replicas with automatic failover if the workload demands it. For a production system, not having to manage those concerns is genuinely valuable.

The TigerData team were proactive and hands-on throughout — they made sure I had the technical context and support I needed, which made a real difference when setting up a workload this specific.

Link in the description if you want to explore the platform.

---

## Slide Content

### Slide 1: Why Blockchain Data Needs ETL
Two-column comparison:

| What arrives off-chain | What analytics needs |
|---|---|
| Raw instructions (binary-encoded) | Prices, volumes, trade direction |
| Account state diffs | TVL, reserve ratios, depth metrics |
| Token balance changes | Risk measures, percentile distributions |
| Fragmented across many accounts | Clean, time-aligned, structured records |

Subtext: *Solana: one swap = pool state + vault accounts + tick arrays + fee accounts — all changing simultaneously*

---

### Slide 2: ETL Belongs in the Database
Two-column:

| Ingestion layer | Database layer |
|---|---|
| On the critical path | Async, decoupled from stream |
| Needs to keep pace with the blockchain | Has independent compute budget |
| Write raw data fast | Transform, enrich, aggregate |
| No tolerance for inline computation lag | Full access to historical state |

Subtext: *Separate concerns: raw data is ground truth; derived measures are produced asynchronously*

---

### Slide 3: Why PostgreSQL?
Three properties:

- **Procedural extensibility** — PL/pgSQL triggers + stored functions; domain logic lives in the database, close to the data
- **Complex SQL** — multi-CTE, LATERAL joins, window functions, DISTINCT ON, dynamic bucketing; data engineered into metrics at query time
- **Full ACID transactions** — trigger enrichment runs atomically at write time; no partial or inconsistent derived data

Subtext: *Columnar OLAP (ClickHouse, BigQuery) — excellent for bulk read scans, not designed for trigger-based write-time enrichment or complex procedural ETL*

---

### Slide 4: 4-Layer Database Architecture
Vertical stack:

```
  Raw source tables (hypertables)
        │
        ▼ BEFORE INSERT triggers fire
  Enriched rows committed
        │
        ▼ Continuous aggregates refresh every 5 seconds
  21 CAGGs — 5-second materialised rollups
        │
        ▼ Parameterised view functions compose on demand
  Frontend-ready results (any interval, any time range)
        │
        ▼
  Dashboard
```

---

### Slide 5: TimescaleDB + TigerData Platform
Four columns:

| Hypertables | Continuous Aggregates | Columnar Compression | Managed Platform |
|---|---|---|---|
| Time-based auto-partitioning | Incrementally materialised | Applied to historical chunks | Backups, pooling, monitoring |
| Fast queries on recent data | 21 CAGGs at 5-second refresh | Large storage reduction | HA replicas available |
| Chunk-level operations | Incremental — not full re-scan | Queries often faster | Tiered S3 archival |
