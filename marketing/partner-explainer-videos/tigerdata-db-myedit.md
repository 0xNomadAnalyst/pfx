# TigerData — Video Script (Short, ~4 min)

**Title:** Why I Chose PostgreSQL + TigerData for a Real-time DeFi Analytics Platform
**Version:** Short (~4 min / ~540 words spoken)
**Format:** Talking head with slide transitions noted inline

---

## Script

[ON CAMERA]

This video is sponsored by TigerData. TigerData provides key infrastructure for this public risk dashboard demo I built, supporting the real-time Solana data pipeline behind it. The dashboard is now live, and you can check it out via the link in the description box below.

In this video I want to talk about the database layer of that platform — and why I specifically selected TigerData as the database solution to power the operational intelligence behind this dashboard. Let's go!

---

[SLIDE: Why Blockchain Data Needs ETL]

[ON CAMERA]

In the last video, I covered the infrastructure needed to ingest real-time Solana data and some of the data processing that needs to happen at that stage. But once that data arrives, the job is only half done!

Blockchain data is fundamentally low-level.

It does not arrive in business terms. You do not get a clean swap record, a ready-made risk metric, or a neat summary of what just happened in a market. You get raw instructions, state changes, balance updates, and other low-level execution data — and it is your job to turn that into something useful for analysis and decision-making.

On Solana, that problem is especially pronounced. A single logical event can involve multiple accounts, meaning that the data you need to build a complete picture of the system lies all over the place.

A striking example are Solana's concentrated liquidity DEXes. These protocols manage liquidity provider positions by chopping up the price line into chunks that each have their state managed by separate onchain accounts. That means the data you need to say anything useful about liquidity can easily be spread out across dozens of accounts!

That means the transformation layer is not some minor cleanup step at the end. It is a central part of the architecture.

And that leads to the next question: 


---

[ON CAMERA]

Where should that transformation work live?

My view is that the ingestion layer is the wrong place for heavy ETL. Ingestion sits on the critical path of a live stream. Its job is to receive data and write it quickly. If you load that layer up with too much computation, you create backpressure and start making the streaming problem harder than it needs to be. So the design principle I settled on was simple: write raw data quickly, and do the heavier transformation work inside the database. 

---

[SLIDE: Why PostgreSQL?]

[ON CAMERA]

Once you make that decision, the database choice becomes much more important.

At first glance, it is tempting to think the answer should simply be: choose the fastest analytics database you can find. And that instinct is not unreasonable. There are databases that are extremely strong at high-speed analytical scans over large datasets. ClickHouse, for example, is explicitly built for analytical workloads and fast column-oriented querying, and it also supports insert-time transformations through materialized views.

But that was not the full shape of my workload.

My database did not just need to support fast ingestion and fast querying. It also needed to sustain a heavy, ongoing transformation layer that continuously turns low-level blockchain data into domain-specific metrics. And for that, raw scan speed is not the whole story.

That is where PostgreSQL stood out to me. It felt less like a pure analytics engine, and more like a dependable workhorse for a transformation-heavy architecture. Part of that comes from the fact that PostgreSQL natively supports procedural logic, triggers, and function-based abstraction.

And those features turned out to have other significant benefits that I had not anticipated.

They allowed me to approach the transformation problem in a way that felt much closer to ordinary programming: first do this, then do that, then expose the result in a reusable form. I found that much more natural for the kind of ongoing data engineering this platform required.

Functions were especially valuable. In finance, risk, and economics, many of the things you want to calculate are formula-based. Being able to define functions inside the database gave me a clean way to express those calculations in terms that were close to how I was already thinking about the problem. That made it easier to design metrics that were actually useful for the platform, and to call them as part of the database’s own transformation workflow.

And I eventually discovered that functions were critically useful right at the end of the stack too, because they gave me an efficient way to expose parameterized query interfaces that could return different results depending on how users interacted with the frontend dashboard.

But all this still leaves an obvious question. 

PostgreSQL itself is hardly new — it has been around for decades. So what exactly does TigerData add on top of that foundation that makes it especially well suited to this kind of on-chain, time-series workload?

---

[SLIDE: Database Architecture]

[ON CAMERA]

TigerData IS built on PostgreSQL, with the TimescaleDB extension adding the time-series features that make this kind of workload much more practical and performant than in pure PostgreSQL.

One key example is continuous aggregates. They let you precompute rollups and keep them refreshed automatically in the background as new data arrives. And crucially, that refresh happens incrementally, so you are not recomputing the full dataset every time.

That matters a lot for a live dashboard.

If every frontend query had to aggregate directly from raw history each time, the system would become expensive and sluggish very quickly. Continuous aggregates let you maintain reusable summaries without redoing the whole computation from scratch. That is exactly the kind of thing a monitoring platform needs.

TigerData also adds hypertables, which partition time-series data by time under the hood and make it much easier to scale time-based workloads cleanly. And for historical retention, it includes compression and columnstore features that reduce storage requirements substantially while keeping older data queryable, alongside integrated tiered-storage options that can automatically move colder data into low-cost object storage.

So how did I actually apply these capabilities in practice — to support this real-time dashboard?

---

At a high level, the architecture looks like this:

Raw data lands in source tables first.

From there, enrichment logic lives close to the data.

On top of that, continuous aggregates roll the data into reusable summaries.

And then a query layer sits above those summaries, performing final analytical calculations and serving the frontend the shape it actually needs — without forcing you to materialize every possible view in advance.

So the short version is this:

I did not choose TigerData because I thought database selection was just a contest for the fastest benchmark.

I chose it because this platform needed a database that could do two things well at the same time: support an ongoing transformation layer for low-level blockchain data, and still perform strongly as a time-series analytics engine once that data had been shaped into something useful.

TigerData gave me both: the extensibility of PostgreSQL, and the time-series capabilities needed to make that architecture practical.

The team were also proactive and helpful throughout the process, which matters more than people often expect when you are building something specific.

If you want to learn more about TigerData, I have included a link in the description box below.

---

And so, that's a wrap! 

I hope this has given you a solid introduction to the data-engineering challenges involved in working with real-time Solana data — and to how those challenges shape the database architecture you end up choosing.

I have enjoyed putting this two-part technical series together. And if you have not seen the first video yet, you can find it linked in the description below and in the end cards here.

Thanks for watching.

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
