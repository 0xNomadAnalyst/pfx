# TAQ Hackathon — App Concept: The Daily Brief

Working concept for the hackathon build. Sits on top of the existing `risk_dash` substrate described in [project-brief.md](project-brief.md).

---

## Concept in one sentence

A **daily onchain briefing** — pushed to Slack and archived on a simple web view — that tells a project owner or treasury manager, in plain language, what changed overnight in their DeFi exposure and whether it matters.

---

## Why this direction fits

- **Push, not pull.** The TAQ audience are operators — CFOs, controllers, treasury managers, DAO finance leads. They already live in Slack for every other serious work input. Dashboards are for analysts; briefs are for owners. A thing that arrives with an opinion ("quiet" / "elevated" / "read this") respects their time and maps to how they already consume information.
- **Forces the database to do real work.** A useful brief cannot be produced with a naive query-to-LLM loop. It requires multi-domain synthesis across DEX, lending, and yield data — comparing today vs. yesterday vs. historical percentile baselines, then *selecting* what is material and discarding the rest. This is exactly what the substrate is designed for and what is nearly impossible without it.
- **The thesis writes itself.** Every bullet in the brief maps to a view function whose columns carry `COMMENT ON` annotations. The LLM produces analyst-quality prose because the database already speaks finance. The demo is a live illustration of context-engineering-at-the-data-layer.
- **Demo-friendly.** A Slack message landing + a click-through to a web view is two moves. No interactive state, no shaky real-time features. Fits a 2–3 minute demo naturally.
- **Reuses existing assets.** The current risk dashboard becomes the "proof layer" behind the brief — every claim deep-links to its corresponding chart. One week of build becomes realistic because we are not rebuilding dataviz.

---

## What the brief contains

The brief must be **selective**: boring most days, sharp when it matters. That discipline is what makes it useful and what separates it from yet another dashboard. Most sections will be empty on most days. That is the point.

Proposed shape:

1. **Verdict line** at the top — one of `Quiet` / `Elevated — N items` / `Material change — read this`. Sets the tone before the reader reads anything else.
2. **Material changes** — things that moved beyond threshold overnight: price, liquidity depth, utilisation, yields, reserve balances.
3. **Anomalies vs. baseline** — events ranked by empirical percentile against the precomputed distributions in `risk_pvalues`. Naturally showcases the substrate.
4. **State transitions** — anything that crossed a configured risk zone threshold (e.g. a lending reserve moving from normal into stressed utilisation).
5. **Counterparty / venue events** — concentration shifts, large positional flows, unwinds, notable new LPs or borrowers.
6. **LLM-written synthesis paragraph** — the "so what," turning the facts above into a forwardable narrative. Grounded exclusively in the pre-computed JSON of facts; the LLM does not fetch, does not infer numbers, only writes prose.

---

## Three layers of credibility (the unusual property)

Because the existing dashboard already exists, every claim in the brief can deep-link to a live chart. Most briefs are unverifiable; ours is not. A voter sees:

1. **The bullet** — a one-line claim in plain finance language.
2. **The chart** — the existing dashboard view showing the movement.
3. **The schema** — the column with its `COMMENT ON` annotation explaining what the number means.

Three layers of credibility in a single click-through. Very few hackathon submissions can offer this, and it is a direct artefact of the substrate investment.

---

## Key design decisions

These need to be settled before build begins.

- **Watch profile.** One configurable "what am I watching" — a token, a treasury wallet, a protocol, or a curated mix. For the hackathon, start with a preset profile (the ecosystem substrate already monitored) and a single knob to swap it. Multi-tenant profiles are week-two work.
- **Materiality thresholds.** Use the existing `risk_pvalues` distributions as the default source of materiality (e.g. a sell event above p95 for its time window is "material"). This keeps the brief principled, avoids arbitrary hand-chosen numbers, and dogfoods the substrate.
- **LLM scope.** Facts come exclusively from SQL queries against the DB. The LLM receives a structured JSON of pre-computed facts and writes prose around them. No hallucination surface, no tool-use, no freestyle. We can tell this story explicitly: "grounded generation by schema."
- **Slack mechanics.** For the demo, a single incoming webhook into a demo workspace channel is sufficient. A full multi-tenant OAuth Slack app is polish that does not change the vote outcome and can be explicitly called out as a roadmap item.
- **Frontend.** A simple archive view — feed of past briefs, each bullet deep-linking to the relevant chart on the existing risk dashboard. No new charts, no interactive widgets. Every visual already exists.
- **Delivery cadence.** Daily (morning), with the option of an intra-day "alert" brief if a material event fires outside schedule. Intra-day is optional for hackathon scope.

---

## Naming direction

The name should read like something a bank, fund, or treasury desk would send — not like a crypto tool. Avoid "AI," "agent," "smart," "insight" in the name; TAQ voters will mentally downgrade it into the pile of vibe-coded submissions.

Candidates to consider:

- *The Morning Close*
- *Morning Brief*
- *Ledger Line*
- *Position Note*
- *The Daily Note*
- *Book Watch*

---

## What this concept intentionally does **not** do

- It does not attempt to be a dashboard. If the reader wants depth, the existing dashboard exists one click away.
- It does not attempt natural-language query ("ask the data") — shaky demos, crowded category, off-message.
- It does not attempt real-time streaming alerts. Daily cadence is the product.
- It does not attempt multi-tenant onboarding. Single-workspace demo is enough for votes; the story about multi-tenancy is future roadmap.

Scope discipline is the point. A polished, narrow artefact beats a broad vibe-coded one.

---

## Open questions for the next pass

Before writing code, resolve:

1. **Which watch profile** ships as the default demo? The ecosystem substrate as-is, or a reframed/re-skinned version (e.g. a generic "DAO treasury" portfolio) to land better with a finance audience?
2. **Which sections survive v1?** All six above, or a tighter three-section MVP?
3. **Where does the brief "live" between sends?** Flat files, a table in the existing DB, or a small separate store?
4. **What is the final name?** Needed before any UI or landing copy is written.
5. **How will the demo be narrated?** The voting-time pitch needs to lead with the *owner* experience (Slack), not the *technical* experience (schema, LLM grounding). The substrate story is the finale, not the opener.

Next artefact when the above is settled: a buildable spec — data sources per section, LLM prompt contract, Slack + web surface details, and a demo script.
