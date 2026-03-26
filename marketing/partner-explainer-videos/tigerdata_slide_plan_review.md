# TigerData Video Slide Plan (Review Version)

> Notes:
> - `Layout:` should be either `half-page` or `full-page`
> - `Script cue:` gives the opening words of the sentence this slide matches
> - `Review note:` comments intended to be stripped before Gamma generation
> - Use minimal on-slide text; keep wording close to narration

---

## Slide 1
**Layout:** half-page  
**Script cue:** “This video is sponsored by TigerData.”  
**Slide title:** Real-Time Solana Analytics: The Database Layer  
**Slide text:**
- Public risk dashboard demo
- Database architecture behind the platform
- Infrastructure supported by TigerData

**Review note:** Opening sponsor/title slide. Keep your talking head visible on one side.  
**Visual suggestion:** Use a dashboard screenshot on the slide side, with a subtle TigerData logo lockup if appropriate.

---

## Slide 2
**Layout:** half-page  
**Script cue:** “In the last video, I covered the infrastructure needed...”  
**Slide title:** Ingestion Is Only Half the Job  
**Slide text:**
- Data arrives
- Work is not over
- Database layer matters next

**Review note:** Bridge from the previous Shyft video.  
**Diagram note:** Simple two-stage flow: `Ingestion -> Database / Analytics`

---

## Slide 3
**Layout:** half-page  
**Script cue:** “Blockchain data is fundamentally low-level.”  
**Slide title:** Raw Blockchain Data  
**Slide text:**
- Not business-ready
- Instructions
- State changes
- Balance updates

**Review note:** Keep this sparse and close to narration.  
**Diagram note:** None needed.

---

## Slide 4
**Layout:** full-page  
**Script cue:** “On Solana, that problem is especially pronounced.”  
**Slide title:** Why Solana Makes This Harder  
**Slide text:**
- One logical event
- Multiple accounts
- Data scattered across the system

**Review note:** This is a good place for a fuller explanatory visual.  
**Diagram note:** One event branching to many separate account boxes.

---

## Slide 5
**Layout:** full-page  
**Script cue:** “A striking example are Solana's concentrated liquidity DEXes.”  
**Slide title:** Concentrated Liquidity Means Fragmented State  
**Slide text:**
- Price range split into segments
- State spread across many on-chain accounts
- Liquidity insight requires reconstruction

**Review note:** This is an important concrete example; worth visual emphasis.  
**Diagram note:** Price line broken into segments, each linked to its own account box. Avoid protocol branding if unnecessary.

---

## Slide 6
**Layout:** half-page  
**Script cue:** “That means the transformation layer is not some minor cleanup step...”  
**Slide title:** Transformation Is Central  
**Slide text:**
- Not minor cleanup
- Core part of the architecture

**Review note:** This is a short, emphatic takeaway slide.  
**Diagram note:** None needed.

---

## Slide 7
**Layout:** half-page  
**Script cue:** “And that leads to the next question: Where should that transformation work live?”  
**Slide title:** Where Should Heavy ETL Live?  
**Slide text:**
- Ingestion layer?
- Database layer?

**Review note:** Set up the design choice clearly.  
**Diagram note:** Two-box comparison: `Ingestion` vs `Database`

---

## Slide 8
**Layout:** half-page  
**Script cue:** “My view is that the ingestion layer is the wrong place...”  
**Slide title:** Keep Ingestion Light  
**Slide text:**
- Ingestion is on the critical path
- Receive data fast
- Write data fast
- Avoid backpressure

**Review note:** This is a design-principle slide.  
**Diagram note:** Pipeline showing congestion/backpressure if heavy compute is inserted at ingest.

---

## Slide 9
**Layout:** half-page  
**Script cue:** “So the design principle I settled on was simple:”  
**Slide title:** Design Principle  
**Slide text:**
- Write raw data quickly
- Do heavier transformation inside the database

**Review note:** Strong concise architectural statement.  
**Diagram note:** `Raw write -> DB transformation`

---

## Slide 10
**Layout:** half-page  
**Script cue:** “Once you make that decision, the database choice becomes...”  
**Slide title:** Then the Database Choice Changes  
**Slide text:**
- Not just a storage choice
- Architectural choice

**Review note:** Pivot into the DB selection argument.  
**Diagram note:** None needed.

---

## Slide 11
**Layout:** half-page  
**Script cue:** “At first glance, it is tempting to think...”  
**Slide title:** The Obvious Instinct  
**Slide text:**
- Choose the fastest analytics database
- Reasonable instinct
- But not the whole story

**Review note:** This sets up the contrast without naming too many products on-slide.  
**Diagram note:** Optional speedometer / benchmark motif.

---

## Slide 12
**Layout:** half-page  
**Script cue:** “ClickHouse, for example, is explicitly built...”  
**Slide title:** Fast Analytics Is Real  
**Slide text:**
- Strong analytical scans
- Column-oriented querying
- Insert-time transforms via materialized views

**Review note:** Keep this fair and non-combative.  
**Diagram note:** None needed.

---

## Slide 13
**Layout:** half-page  
**Script cue:** “But that was not the full shape of my workload.”  
**Slide title:** My Workload Was Different  
**Slide text:**
- Fast ingestion
- Fast querying
- Heavy ongoing transformation

**Review note:** This is the real thesis slide.  
**Diagram note:** Three stacked workload blocks.

---

## Slide 14
**Layout:** half-page  
**Script cue:** “That is where PostgreSQL stood out to me.”  
**Slide title:** Why PostgreSQL Stood Out  
**Slide text:**
- Workhorse for transformation-heavy architecture
- Procedural logic
- Triggers
- Function-based abstraction

**Review note:** Keep this as a capability slide, not a benchmark slide.  
**Diagram note:** None needed.

---

## Slide 15
**Layout:** half-page  
**Script cue:** “And those features turned out to have other significant benefits...”  
**Slide title:** A More Natural Programming Model  
**Slide text:**
- First do this
- Then do that
- Expose the result in reusable form

**Review note:** Keep wording close to narration; this is about familiarity and workflow.  
**Diagram note:** Simple 3-step flow.

---

## Slide 16
**Layout:** half-page  
**Script cue:** “Functions were especially valuable.”  
**Slide title:** Why Functions Mattered  
**Slide text:**
- Formula-based metrics
- Close to how you think about the problem
- Useful inside the transformation workflow

**Review note:** This is a strong credibility slide; do not overload it.  
**Diagram note:** Optional formula -> function -> metric flow.

---

## Slide 17
**Layout:** half-page  
**Script cue:** “And I eventually discovered that functions were critically useful...”  
**Slide title:** Functions Helped Again at the End  
**Slide text:**
- Parameterized query interfaces
- Different results based on frontend interaction
- Less duplication

**Review note:** This bridges nicely into the final query layer.  
**Diagram note:** Frontend controls feeding into a parameterized function box.

---

## Slide 18
**Layout:** half-page  
**Script cue:** “But all this still leaves an obvious question.”  
**Slide title:** Then Why TigerData?  
**Slide text:**
- PostgreSQL is mature
- What does TigerData add?

**Review note:** Use this as a clean transition card.  
**Diagram note:** None needed.

---

## Slide 19
**Layout:** full-page  
**Script cue:** “TigerData IS built on PostgreSQL...”  
**Slide title:** TigerData + TimescaleDB  
**Slide text:**
- PostgreSQL foundation
- Time-series features on top
- Better fit for this workload

**Review note:** Full-page architecture branding slide.  
**Diagram note:** Layered stack: `Application / Query Layer -> TigerData / TimescaleDB -> PostgreSQL`

---

## Slide 20
**Layout:** half-page  
**Script cue:** “One key example is continuous aggregates.”  
**Slide title:** Continuous Aggregates  
**Slide text:**
- Precompute rollups
- Refresh automatically
- Incremental updates

**Review note:** This is a core feature slide.  
**Diagram note:** `Raw time-series -> continuous aggregate -> refreshed summary`

---

## Slide 21
**Layout:** half-page  
**Script cue:** “That matters a lot for a live dashboard.”  
**Slide title:** Why CAGGs Matter  
**Slide text:**
- Avoid aggregating from raw history every time
- Reusable summaries
- Better dashboard performance

**Review note:** Keep this close to business value.  
**Diagram note:** Side-by-side contrast: raw query every time vs reusable aggregate layer.

---

## Slide 22
**Layout:** half-page  
**Script cue:** “TigerData also adds hypertables...”  
**Slide title:** Hypertables, Compression, Tiering  
**Slide text:**
- Time partitioning under the hood
- Lower storage footprint
- Older data stays queryable
- Cold data can move to object storage

**Review note:** This slide should stay high-level; no need to explain mechanics in depth.  
**Diagram note:** Timeline of hot -> warm -> cold data storage.

---

## Slide 23
**Layout:** half-page  
**Script cue:** “So how did I actually apply these capabilities in practice...”  
**Slide title:** So What Did the Architecture Look Like?  
**Slide text:**
- How the pieces fit together
- In support of a real-time dashboard

**Review note:** Transition into the stack overview.  
**Diagram note:** None needed.

---

## Slide 24
**Layout:** full-page  
**Script cue:** “At a high level, the architecture looks like this:”  
**Slide title:** High-Level Architecture  
**Slide text:**
- Source tables
- Enrichment close to the data
- Continuous aggregates
- Query layer for the frontend

**Review note:** This is the main architecture diagram slide.  
**Diagram note:** Four-layer architecture: `Source tables -> Enrichment -> Continuous aggregates -> Query layer / Frontend`

---

## Slide 25
**Layout:** half-page  
**Script cue:** “So the short version is this:”  
**Slide title:** Why I Chose TigerData  
**Slide text:**
- Not just the fastest benchmark
- Support heavy transformation
- Perform strongly as a time-series analytics engine

**Review note:** This is the condensed thesis slide.  
**Diagram note:** None needed.

---

## Slide 26
**Layout:** half-page  
**Script cue:** “TigerData gave me both:”  
**Slide title:** What TigerData Gave Me  
**Slide text:**
- PostgreSQL extensibility
- Time-series capabilities
- Practical architecture fit

**Review note:** Good summary slide before closing sponsor mention.  
**Diagram note:** Two-column value slide.

---

## Slide 27
**Layout:** half-page  
**Script cue:** “The team were also proactive and helpful...”  
**Slide title:** Support Also Mattered  
**Slide text:**
- Proactive
- Helpful
- Valuable when building something specific

**Review note:** Brief sponsor-support slide.  
**Diagram note:** None needed.

---

## Slide 28
**Layout:** half-page  
**Script cue:** “And so, that's a wrap!”  
**Slide title:** Key Takeaway  
**Slide text:**
- Real-time Solana data creates real ETL challenges
- Those challenges shape the database architecture you choose

**Review note:** Closing summary slide.  
**Diagram note:** None needed.

---

## Slide 29
**Layout:** half-page  
**Script cue:** “I have enjoyed putting this two-part technical series together.”  
**Slide title:** Thanks for Watching  
**Slide text:**
- Two-part technical series
- First video linked below
- End cards here

**Review note:** Final end-card support slide.  
**Image suggestion:** Optional clean thumbnail previews of the two videos.
