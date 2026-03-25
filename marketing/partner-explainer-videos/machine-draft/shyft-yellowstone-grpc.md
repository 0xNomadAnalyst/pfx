# Shyft + Yellowstone gRPC — Video Script (Short, ~4 min)

**Title:** Real-time Solana Data: How Yellowstone gRPC Works
**Version:** Short (~4 min / ~540 words spoken)
**Format:** Talking head with slide transitions noted inline

---

## Script

[ON CAMERA]

Before we get into it — today's video is sponsored by Shyft. Shyft provided the key infrastructure I use to ingest real-time Solana data into the risk dashboard I've been building, and I'll be sharing why I chose them at the end. First, let's talk about how this all works.

---

[ON CAMERA]

If you've built anything that needs current Solana data, you've probably started with the standard JSON-RPC API. And that's fine for occasional lookups. But if you need to capture every swap, every liquidity change, every account update — in real time — polling doesn't work. Solana processes thousands of transactions per second. Polling burns through rate limits, introduces latency, and at some point you simply can't go fast enough to keep up. What you need is a push-based stream.

---

[SLIDE: The Solana Data Pipeline]

[ON CAMERA]

That's what Yellowstone gRPC provides. It's built on top of the Geyser plugin system — an interface that Solana validators expose, which allows an external process to receive data directly as the validator processes each block. Yellowstone, sometimes called Dragon's Mouth, wraps this in a standard gRPC API.

What that means in practice: you declare subscriptions to exactly what you care about. Transactions involving specific program addresses. Account state updates for particular accounts or owner programs. Or full block data with embedded transactions for when you need the canonical block timestamp. The filtering happens at the source — before data leaves the node — so you're not receiving the entire Solana firehose and discarding most of it. Data arrives at confirmed commitment, which on Solana means sub-second latency.

---

[SLIDE: From Raw Stream to Signal]

[ON CAMERA]

Now — this stream is fast, and it's filtered. But what arrives is still raw and low-level. A transaction on Solana is a bundle of instructions, each addressed to a program, with a binary-encoded payload. To extract anything useful you have to work for it.

First, you identify which program each instruction belongs to. Then you decode the instruction data against that program's schema to understand what operation it represents. But here's where it gets more involved: Solana allows programs to call other programs — cross-program invocations — so a single swap transaction will typically contain outer instructions that trigger a chain of inner instructions nested within them. You need to unnest all of that, then correlate the decoded instruction data with the pre- and post-transaction token balance changes to reconstruct what actually moved: which token, in which direction, and at what implied price.

Only after that full correlation chain can you say — this was a swap, this was the amount, this was the direction. Multiply that across multiple DEX programs, a lending protocol, and aggregator routes that may route a single trade through several programs in one transaction, and that's the scope of the ingestion engineering challenge.

---

[SLIDE: Shyft Services]

[ON CAMERA]

So why Shyft? A few things stood out.

Pricing first. At the time I evaluated providers, Shyft was the most cost-competitive option for dedicated Yellowstone gRPC access — flat-rate, not metered per request, which matters when you're running a continuous stream.

Documentation. Shyft has genuinely high-quality docs — not just reference material, but use-case guides built around specific DEXes, with code examples in multiple languages. If you're getting started with Yellowstone for the first time, that's a real differentiator. They also have a good web UI for exploration if you're not deep in developer tooling.

Beyond gRPC, Shyft offers a GraphQL indexer — which lets you efficiently query all active accounts owned by a given program. That's the alternative to `getProgramAccounts`, which is a full on-chain scan that's expensive and slow at scale. I use the indexer for querying LP positions across DEX pools and obligation accounts across the lending protocol. All three services — gRPC, the indexer, and standard RPC — run on the same API key, which keeps things operationally simple.

And finally — the team. When I was integrating, Shyft's support was genuinely responsive and hands-on. I got real answers quickly, which made a real difference early on.

Link in the description if you want to explore. Next up: why I chose TigerData for the database layer.

---

## Slide Content

### Slide 1: The Solana Data Pipeline
Simple left-to-right flow diagram:

> **Solana Validator** → *Geyser plugin* → **Yellowstone gRPC** → *Your ingestion service* → **Database**

Subtext: *Filtering at source — only relevant data travels the pipe*

---

### Slide 2: What You Can Subscribe To
Three columns:

| Transactions | Account Updates | Blocks |
|---|---|---|
| Filter by program ID or account address | Filter by specific accounts or owner programs | Full block with embedded transactions |
| Identify operations as they occur | Track state changes in real time | Canonical block timestamp |

---

### Slide 3: From Raw Stream to Signal
Nested diagram showing the decoding chain:

```
Transaction
└── Outer instruction (program ID + encoded data)
    ├── Inner instruction (CPI call)
    │   └── Inner instruction (CPI call)
    └── Pre/post token balance changes
         ↓
    Decoded event: swap / LP add / borrow
    (amount, direction, price)
```

---

### Slide 4: Shyft Services
Three columns (same API key):

| Yellowstone gRPC | GraphQL Indexer | JSON-RPC |
|---|---|---|
| Real-time transaction & account stream | Query all program-owned accounts at scale | Standard account polling & backfill |
| Sub-second latency at CONFIRMED | Alternative to expensive getProgramAccounts | Same API key, same endpoint provider |
