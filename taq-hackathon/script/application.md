# TAQ Hackathon Submission — Application Form Copy

Drafted to mirror the form fields in order. Pre-filled fields noted but
not re-drafted. Copy is tuned for the TAQ audience — finance-fluent,
partially crypto-fluent, largely non-technical — and carries the "moat
is the schema, not the model" thesis implicitly rather than stating it.

---

## YOUR PROFILE

**Full name:** Roderick McKinley *(already filled)*

**Hacking status:** Solo *(already selected)*

---

## PROJECT DETAILS

### Project name

> **Daily Brief**

*(Matches what the app calls itself on screen. If a more distinctive
name is wanted, "Onchain Morning Note" deliberately evokes the
sell-side analyst tradition — same finance-desk connotation the TAQ
audience already has in their head.)*

---

### One-liner summary

> A once-a-day AI brief that surfaces the material shifts across a
> token's liquidity, lending, and yield markets — delivered to Slack.

---

### What does it do?

> The app watches a DeFi token's deployment across multiple onchain
> venues — DEX liquidity pools, lending markets, yield markets — and
> produces a short daily brief of what actually changed in the past 24
> hours. Each day's brief pairs an LLM-written interpretation with the
> specific underlying events the agent was given, so the summary is
> auditable against the data that drove it. The brief is also posted
> once a day to any subscribed Slack channel, so treasury and finance
> teams get the digest where they already work, rather than behind yet
> another login.
>
> Under the hood, the app sits on a continuously-ingested Solana
> analytics database. Every table and column in that database carries
> annotations — source, units, scaling, processing rules — which is
> what lets the coding agent and the summarising LLM reason about the
> data accurately. The hackathon app itself was a few days of work on
> top of that substrate; the substrate is an existing production asset.

**Image slots (up to 3)** — suggestions in priority order:

1. The daily brief detail page — the analysis block at the top, with
   the underlying events visible below. This is the centrepiece of
   the product.
2. The Slack message view — the same brief formatted for Slack, so
   voters see both delivery channels.
3. *(Optional)* The homepage running log of past briefs, showing the
   cadence.

---

### What problem does it solve?

> A DeFi project's token can sit in many protocols at once — liquidity
> pools, lending markets, yield markets — each moving on its own clock.
> Finance and treasury teams who need to know what happened overnight
> typically face two bad options: log into half a dozen operational
> dashboards every morning, or build one giant dashboard that captures
> everything and is overwhelming to actually read.
>
> Daily Brief inverts the direction. Instead of asking a human to go
> looking, it surfaces the small number of things that materially
> shifted today, writes a first-pass interpretation of them, and posts
> it to the place the team already watches. The human reads a few
> paragraphs, not fifty charts, and only opens the full protocol
> dashboard when something in the brief warrants a closer look.
>
> The broader point is a methodological one. This kind of app becomes
> quick to build — days, not months — once the underlying database is
> well-structured and richly annotated. That combination is the
> emerging shift worth paying attention to in the crypto-finance tool
> stack.

**Image slot (up to 3)** — suggestion:

1. A screenshot of the full protocol dashboard behind the brief (the
   existing risk-monitoring platform the app links out to), shown
   small enough that it reads as "dense" rather than legible. The
   point is visual: the brief collapses *that* into a few paragraphs.

---

### Tools used

*Already selected: Claude Code, Perplexity Computer, Cursor.*

Worth double-checking the real build:

- **Claude Code** — yes, coding agent.
- **Perplexity Computer** — confirm whether this was actually used in
  the build; if not, deselect to stay honest.
- **Cursor** — confirm similarly.
- **Claude Chat / Claude Cowork** — consider adding if either was used
  for design or scoping conversations.
- Mention in the write-up (but not as a selectable tool) that Claude's
  design tool was used to scrape the existing website and derive the
  design system — this is part of the "didn't take much prompting"
  thesis.

---

### Video demo link

https://youtu.be/n6vOrpNp2-k *(already filled)*

---

### Cover image

Recommendation: use a crop of the daily brief detail page —
specifically the analysis block with the "Daily brief · 2026-04-23"
heading visible. Dark background, orange accents, a few lines of the
LLM summary readable. That frame carries the product's whole concept in
one still, and the dark palette will stand out against other
submissions that lean pastel or AI-generated.

If generating something instead, avoid the default AI-art aesthetic —
voters will scroll past it. A minimal typographic cover ("Daily Brief
— onchain activity, once a day, in Slack") over a dark field will read
better than anything illustrative.

---

### Source code link (optional)

https://taq-hackathon-daily-upates-ws.up.railway.app/ *(already filled)*

Note: this is the live app URL, not a source-code repository. The field
label asks for GitHub / GitLab / public repo. Two options:

- **Leave as is** — the field is optional, and the live link is
  arguably more useful for a voter than source code they won't read.
- **Replace with a public repo link** if a stripped-down public mirror
  of the app is posted. Worth doing only if time permits; voters
  mostly won't click through to code.

---

### TEAM MEMBERS

Solo — leave empty.

---

## Submission checklist

- [ ] Project name entered
- [ ] One-liner summary entered
- [ ] "What does it do?" entered + images attached
- [ ] "What problem does it solve?" entered + image attached
- [ ] Tools list matches what was actually used
- [ ] Video link plays and is unlisted or public (not private)
- [ ] Cover image uploaded
- [ ] Source code field reviewed (leave live link or swap for repo)
- [ ] Final pass: no specific client names, no Solana-dev-speak as
      primary voice, no "built from scratch in a week" framing
