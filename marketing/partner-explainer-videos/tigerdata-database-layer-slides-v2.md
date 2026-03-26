TigerData Video Slide Plan (Review Version)
Notes:
* `Layout:` should be either `half-page` or `full-page`
* `Script cue:` gives the opening words of the sentence this slide matches
* `Review note:` comments intended to be stripped before Gamma generation
* Use minimal on-slide text; keep wording close to narration

Slide 1
Layout: half-page Script cue: "This video is sponsored by TigerData." Slide title: The Database Layer for Real-Time Solana Data Slide text:
* Public risk dashboard demo
* Real-time Solana data pipeline
* Database infrastructure powered by TigerData
Review note: Opening sponsor/title slide. Mirror the visual treatment from the Shyft video for series consistency. Visual suggestion: Dashboard screenshot with TigerData logo lockup.

Slide 2
Layout: half-page Script cue: "In this video I want to talk about the database layer..." Slide title: What We'll Cover Slide text:
* The database layer of the platform
* Why TigerData was selected
* Operational intelligence behind the dashboard
Review note: Simple framing slide; let the narration carry the energy. Diagram note: None needed.

Slide 3
Layout: half-page Script cue: "In the last video, I covered the infrastructure needed..." Slide title: Previously: Ingestion Slide text:
* Part 1 covered real-time ingestion
* Data processing at the stream level
* Once data arrives, the job is only half done
Review note: Quick recap to orient returning viewers and catch up new ones. Diagram note: None needed.

Slide 4
Layout: half-page Script cue: "Blockchain data is fundamentally low-level." Slide title: Blockchain Data Is Low-Level Slide text:
* No clean swap records
* No ready-made risk metrics
* Raw instructions, state changes, balance updates
Review note: Keep this punchy. The narration delivers the contrast; the slide reinforces the "raw" feeling. Diagram note: None needed.

Slide 5
Layout: half-page Script cue: "It does not arrive in business terms." Slide title: What You Get vs. What You Need Slide text:
* You get: execution data
* You need: analysis-ready metrics
* Your job to bridge the gap
Review note: This pairs tightly with slide 4; together they set up the core problem. Diagram note: None needed.

Slide 6
Layout: half-page Script cue: "On Solana, that problem is especially pronounced." Slide title: Solana Makes It Harder Slide text:
* One logical event can involve multiple accounts
* Data you need is spread across the chain
Review note: Sets up the CLMM example on the next slide. Diagram note: None needed.

Slide 7
Layout: full-page Script cue: "A striking example are Solana's concentrated liquidity DEXes." Slide title: Concentrated Liquidity: Data Is Everywhere Slide text:
* Price range chopped into chunks
* Each chunk managed by a separate on-chain account
* Liquidity data spread across dozens of accounts
Review note: This is the most concrete example in the video — give it space. Diagram note: Horizontal price line divided into discrete bins/segments. Each bin points down to a separate account box (Account 1, Account 2 ... Account N). Conveys fragmentation.

Slide 8
Layout: half-page Script cue: "That means the transformation layer is not some minor cleanup step..." Slide title: Transformation Is Central Slide text:
* Not a cleanup step
* A central part of the architecture
Review note: Short and emphatic. Let the narration carry the weight. Diagram note: None needed.

Slide 9
Layout: half-page Script cue: "And that leads to the next question..." Slide title: Where Should Transformation Live? Slide text:
* Ingestion layer?
* Database layer?
Review note: Framing slide; the answer comes on the next slide. Diagram note: None needed.

Slide 10
Layout: full-page Script cue: "My view is that the ingestion layer is the wrong place for heavy ETL." Slide title: Keep Ingestion Light Slide text:
* Ingestion sits on the critical path of a live stream
* Heavy computation creates backpressure
* Design principle: write raw data fast, transform inside the database
Review note: Key architectural decision slide. Worth making the design principle visually prominent. Diagram note: Two-path comparison. Top path (labeled "Risky"): gRPC Stream -> heavy ETL box -> Database. Bottom path (labeled "Better"): gRPC Stream -> slim Write box -> Database with Transform happening inside. Conveys moving heavy work off the streaming path.

Slide 11
Layout: half-page Script cue: "Once you make that decision, the database choice becomes much more important." Slide title: Database Choice Matters More Now Slide text:
* If transformation lives in the database
* The database is no longer just storage
* It becomes a core processing layer
Review note: Transitional slide; sets up the database comparison. Diagram note: None needed.

Slide 12
Layout: half-page Script cue: "At first glance, it is tempting to think the answer should simply be..." Slide title: Why Not Just the Fastest Analytics DB? Slide text:
* ClickHouse: fast columnar scans, materialized views
* Built for analytical workloads
* But that was not the full shape of my workload
Review note: Be fair to ClickHouse — the narration is respectful about it. Diagram note: None needed.

Slide 13
Layout: half-page Script cue: "My database did not just need to support fast ingestion and fast querying." Slide title: The Full Workload Shape Slide text:
* Fast ingestion
* Fast querying
* Heavy, ongoing transformation layer
* Raw scan speed is not the whole story
Review note: This is the bridge from "why not analytics-only" to "why PostgreSQL." Diagram note: None needed.

Slide 14
Layout: half-page Script cue: "That is where PostgreSQL stood out to me." Slide title: PostgreSQL as Workhorse Slide text:
* Procedural logic
* Triggers
* Function-based abstraction
* A dependable workhorse for transformation-heavy work
Review note: Keep the tone grounded — "workhorse" is the right register, not "best database ever." Diagram note: None needed.

Slide 15
Layout: half-page Script cue: "And those features turned out to have other significant benefits..." Slide title: Closer to Ordinary Programming Slide text:
* First do this, then do that, then expose the result
* More natural for ongoing data engineering
Review note: The narration delivers this as a pleasant surprise; let the slide stay understated. Diagram note: None needed.

Slide 16
Layout: half-page Script cue: "Functions were especially valuable." Slide title: Functions for Domain Calculations Slide text:
* Formula-based: risk, finance, economics
* Define calculations inside the database
* Express metrics close to how you think about the problem
Review note: This is the finance/risk audience hook — keep the wording domain-relevant. Diagram note: None needed.

Slide 17
Layout: half-page Script cue: "And I eventually discovered that functions were critically useful right at the end of the stack too..." Slide title: Functions as Query Interfaces Slide text:
* Parameterized query endpoints
* Return different results based on frontend interaction
* Efficient bridge between database and dashboard
Review note: This completes the "three uses of functions" arc. Diagram note: None needed.

Slide 18
Layout: half-page Script cue: "But all this still leaves an obvious question." Slide title: So What Does TigerData Add? Slide text:
* PostgreSQL has been around for decades
* What makes TigerData suited to this workload?
Review note: Rhetorical bridge slide. Keep it clean and let the narration pose the question. Diagram note: None needed.

Slide 19
Layout: half-page Script cue: "TigerData IS built on PostgreSQL..." Slide title: TigerData = PostgreSQL + TimescaleDB Slide text:
* Built on PostgreSQL
* TimescaleDB extension for time-series
* More practical and performant for on-chain workloads
Review note: Clean identity slide. Diagram note: None needed.

Slide 20
Layout: full-page Script cue: "One key example is continuous aggregates." Slide title: Continuous Aggregates Slide text:
* Precompute rollups automatically
* Refresh incrementally as new data arrives
* No full recompute every time
Review note: Core TigerData feature slide — worth the visual space. Diagram note: Left: tall stack of raw event rows (many). Arrow through a box labeled "Continuous Aggregate (incremental refresh)." Right: compact summary table (small). A second arrow from "New Data" shows it merging into the aggregate without touching full history. Conveys incremental, additive nature.

Slide 21
Layout: half-page Script cue: "That matters a lot for a live dashboard." Slide title: Why This Matters for a Live Dashboard Slide text:
* Without aggregates: every query hits raw history
* System becomes expensive and sluggish
* Continuous aggregates maintain reusable summaries
Review note: Reinforces the practical payoff; keep it grounded. Diagram note: None needed.

Slide 22
Layout: half-page Script cue: "TigerData also adds hypertables..." Slide title: Hypertables Slide text:
* Automatic time-based partitioning
* Easier to scale time-series workloads cleanly
Review note: Keep this brief; the narration groups three features together but hypertables deserve their own beat. Diagram note: None needed.

Slide 23
Layout: half-page Script cue: (continuation of same passage) Slide title: Compression & Tiered Storage Slide text:
* Compression and columnstore for historical data
* Substantially reduced storage requirements
* Tiered storage: cold data moves to low-cost object storage automatically
Review note: Pairs with slide 22; together they cover the operational features. Diagram note: None needed.

Slide 24
Layout: full-page Script cue: "So how did I actually apply these capabilities in practice..." Slide title: The Architecture in Practice Slide text:
* Raw data lands in source tables
* Enrichment logic lives close to the data
* Continuous aggregates roll up reusable summaries
* Query layer serves the frontend the shape it needs
Review note: This is the key architecture overview — invest in a clean visual here. Diagram note: Left-to-right pipeline with four stages. Stage 1: "Source Tables" (raw ingested data). Stage 2: "Enrichment" (functions, triggers — close to data). Stage 3: "Continuous Aggregates" (rolled-up summaries). Stage 4: "Query Layer / Functions" -> "Frontend Dashboard." Each stage visually narrower/cleaner than the last. Conveys progressive refinement.

Slide 25
Layout: half-page Script cue: "So the short version is this..." Slide title: Why I Chose TigerData Slide text:
* Not about the fastest benchmark
* Needed two things at once:
* Ongoing transformation layer for blockchain data
* Time-series analytics once data is shaped
Review note: This is the summary value proposition. Keep it clean and confident. Diagram note: None needed.

Slide 26
Layout: half-page Script cue: "TigerData gave me both..." Slide title: PostgreSQL Extensibility + Time-Series Capability Slide text:
* Extensibility of PostgreSQL
* Time-series capabilities of TimescaleDB
* Proactive and helpful team throughout
Review note: Final sponsor beat. Visual suggestion: TigerData logo placed cleanly, same treatment as Shyft logo slide in Part 1.

Slide 27
Layout: half-page Script cue: "And so, that's a wrap!" Slide title: Series Wrap Slide text:
* Part 1: Real-time ingestion — Yellowstone gRPC & Shyft
* Part 2: Database architecture — TigerData
* Dashboard is live — link in the description
Review note: Closing slide. Visual suggestion: Series graphic showing both parts, or final dashboard screenshot. Keep it warm and clean.
