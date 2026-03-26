# Shyft Yellowstone gRPC — Slide Deck Content

<!--
REVIEW NOTES (strip before passing to Gamma):
- Each slide is marked with [LAYOUT: HALF PAGE] or [LAYOUT: FULL PAGE]
- [SCRIPT CUE: "..."] marks the opening sentence from the narration where this slide should appear
- [DIAGRAM] and [IMAGE] notes describe suggested visuals
- Text is kept minimal and close to narrated words to avoid read/listen conflict
-->

---

## Slide 1 — Title

<!-- [LAYOUT: FULL PAGE] -->
<!-- [SCRIPT CUE: "This video is sponsored by Shyft."] -->

### Real-Time Solana Data Ingestion
**Yellowstone gRPC & the Challenges of Live Blockchain Data**

Sponsored by Shyft

<!-- [IMAGE: Dashboard screenshot or stylized hero graphic of the live dashboard. If you have a clean screenshot of the actual dashboard, use that — it grounds the video immediately.] -->

---

## Slide 2 — What We'll Cover

<!-- [LAYOUT: HALF PAGE] -->
<!-- [SCRIPT CUE: "In this video, I'll outline the main challenges..."] -->

- The challenges of live Solana data ingestion
- How the ingestion architecture works
- Where Shyft fits into the stack

---

## Slide 3 — The Goal

<!-- [LAYOUT: HALF PAGE] -->
<!-- [SCRIPT CUE: "Let's start with the basics."] -->

### Live Dashboard → Real-Time Decisions

We need relevant event data **as soon as it occurs**

<!-- [IMAGE: Simple icon or small screenshot of the dashboard in action — reinforces the "end-goal" the narration describes.] -->

---

## Slide 4 — Pull-Based Polling

<!-- [LAYOUT: FULL PAGE] -->
<!-- [SCRIPT CUE: "Across much of the internet, the standard way of getting data is through pull-based methods..."] -->

### Polling: The Standard Approach

You request → Server responds

<!-- [DIAGRAM: Simple two-party sequence diagram. Client on the left, Server on the right. Arrows going right labeled "request", arrows going left labeled "response". Show 3–4 repeated cycles stacked vertically to convey the polling loop.] -->

---

## Slide 5 — The Polling Problem

<!-- [LAYOUT: FULL PAGE] -->
<!-- [SCRIPT CUE: "But this approach is not ideal for real-time event ingestion."] -->

### Events Between Polls Are Missed

Polling faster doesn't solve the problem — it just gets inefficient

<!-- [DIAGRAM: Same two-party layout as Slide 4, but now add small "event" markers (dots or lightning bolts) appearing on a timeline between the request/response arrows. Visually show that events fire in the gaps where no request is active — making them invisible to the client.] -->

---

## Slide 6 — Push-Based Streaming

<!-- [LAYOUT: FULL PAGE] -->
<!-- [SCRIPT CUE: "What you really want is a push-based streaming model..."] -->

### Streaming: Data Delivered As It Happens

Updates pushed to you — no need to keep asking

<!-- [DIAGRAM: Server on the left now, Client on the right. A single persistent connection line between them. Multiple small arrows flowing left-to-right from server to client, each labeled with an event. Conveys continuous delivery without repeated requests.] -->

---

## Slide 7 — Two Push-Based Options

<!-- [LAYOUT: HALF PAGE] -->
<!-- [SCRIPT CUE: "When it comes to Solana data ingestion, you will mainly see two push-based options..."] -->

### WebSocket Subscriptions vs. gRPC Streams

gRPC provides a more **structured and flexible** way to consume real-time Solana data

---

## Slide 8 — Yellowstone gRPC

<!-- [LAYOUT: FULL PAGE] -->
<!-- [SCRIPT CUE: "The standard gRPC interface most people use for Solana data ingestion is Yellowstone gRPC."] -->

### Yellowstone gRPC

Built on Solana's **Geyser plugin system**

Validator data — accounts, transactions, blocks, slots — streamed out to external systems in real time

*Named after geysers in Yellowstone National Park by Triton One*

<!-- [DIAGRAM: Flow diagram. On the left: a box labeled "Solana Validator" with a sub-label "Geyser Plugin". An arrow erupts rightward (styled to evoke a geyser if possible) into a box labeled "Yellowstone gRPC". From there, arrows fan out to multiple boxes on the right representing external consumer systems (e.g., "Your Application", "Database", "Dashboard").] -->

---

## Slide 9 — Subscribe to What You Care About

<!-- [LAYOUT: HALF PAGE] -->
<!-- [SCRIPT CUE: "What this means in practice is that you can subscribe to exactly what you care about."] -->

### Targeted Subscriptions

- Transactions by program address
- Account updates by account or owner
- Full block data for block-level context

**Filtering happens at the source** — before data leaves the node

---

## Slide 10 — The Raw Data Challenge

<!-- [LAYOUT: HALF PAGE] -->
<!-- [SCRIPT CUE: "Definitely valuable... but the irony is that when you're dealing with raw Solana data..."] -->

### Still a Lot of Raw Data

Even with source-level filtering, you still process far more than you need

<!-- This is a transitional beat — the narration is setting up the deeper problem. Keep the slide sparse to let the spoken words carry weight. -->

---

## Slide 11 — Unpacking Solana Transactions

<!-- [LAYOUT: FULL PAGE] -->
<!-- [SCRIPT CUE: "Because even with a fast and well-filtered stream, what arrives is still raw Solana transaction data."] -->

### Raw Transactions Are Structured — But Not Simple

A single user action can trigger multiple program interactions

The specific data you care about may be **buried in nested inner instructions**

<!-- [DIAGRAM: Visual of a Solana transaction as a layered/nested structure. Outermost box labeled "Transaction". Inside it, 2–3 boxes labeled "Instruction". Inside one of those, 2–3 smaller boxes labeled "Inner Instruction". One inner instruction is highlighted or circled, labeled "Your target data" — showing how deep you may need to go.] -->

---

## Slide 12 — Filtering Only Goes So Far

<!-- [LAYOUT: HALF PAGE] -->
<!-- [SCRIPT CUE: "And hidden is the key word here, because it means that information is not available to tighten your filtering upstream..."] -->

### gRPC Filters Can Narrow the Stream — But Only So Far

After filtering, you still need to:

- Unpack each transaction
- Determine if it contains your target interaction
- Understand the protocol to interpret the data correctly

---

## Slide 13 — The Real Ingestion Challenge

<!-- [LAYOUT: FULL PAGE] -->
<!-- [SCRIPT CUE: "So if your goal is not just to observe raw chain activity..."] -->

### From Raw Stream → Clean, Queryable Events

**Ingestion-time processing** is required to:

Isolate relevant events → Normalize into usable form → Write only signal to storage

<!-- [DIAGRAM: Pipeline flow, left to right. "gRPC Stream" (large, noisy — many small items) flows into a box labeled "Ingestion Processing" (with sub-labels: filter, unpack, normalize). Out the other side, a narrower, cleaner flow labeled "Clean Events" feeds into "Database / Storage". Conveys volume reduction and transformation.] -->

---

## Slide 14 — Why Shyft?

<!-- [LAYOUT: FULL PAGE] -->
<!-- [SCRIPT CUE: "So why choose Shyft as my gRPC service provider?"] -->

### Why I Chose Shyft

**Pricing** — Most cost-competitive option at time of evaluation

**Documentation** — Practical examples built around real Solana protocols

**Data Stack** — Indexed query layers for account discovery and protocol-level querying at scale

**Support** — Noticeably responsive and helpful team during implementation

<!-- [IMAGE: Shyft logo, placed cleanly. This is the co-marketing beat — give the brand presence here.] -->

---

## Slide 15 — What's Next

<!-- [LAYOUT: HALF PAGE] -->
<!-- [SCRIPT CUE: "And that gives you a solid introduction to the infrastructure needed..."] -->

### Infrastructure ✓ — Now: The Database Layer

Even with a working pipeline, raw blockchain data still needs transformation into useful metrics

**Next video:** Database setup for real-time monitoring

<!-- [IMAGE: Optional — a simple "part 1 → part 2" visual or series graphic if you have a consistent series look.] -->

---
