# Shyft + Yellowstone gRPC — Video Script (Long, ~10 min)

**Title:** Real-time Solana Data: Yellowstone gRPC Deep Dive (ft. Shyft)
**Version:** Long (~10 min / ~1,300 words spoken)
**Format:** Talking head with slide transitions noted inline

---

## Script

[ON CAMERA]

Before we get into it — today's video is sponsored by Shyft. Shyft provided the core infrastructure I rely on to ingest real-time Solana data for the risk dashboard I've been building. I'll explain exactly what that means and why I chose them, but first I want to give you a proper grounding in how this all works under the hood.

---

[ON CAMERA]

Let's start with the problem. If you're building a live analytics dashboard — something that updates in near real-time, where users expect to see current prices, current liquidity, current risk metrics — you have a latency budget that's measured in seconds, not minutes. You need data that's fresh, continuous, and complete. You can't afford to miss transactions.

The standard approach most people reach for first is the Solana JSON-RPC API. And RPC is fine for a lot of things — fetching account state, looking up a specific transaction, bootstrapping data on startup. But as a mechanism for capturing a continuous stream of blockchain activity? It has real limitations. Polling is request-driven. You ask, you get a response, you wait, you ask again. On Solana, where blocks are produced roughly every 400 milliseconds and thousands of transactions flow through per second, your polling frequency can never keep pace — and even if you poll aggressively, you're burning through rate limits and paying for a lot of redundant requests on intervals where nothing changed.

What you need is a push-based model. Something that delivers data to you as it happens, rather than requiring you to go fetch it.

---

[SLIDE: The Solana Data Pipeline]

[ON CAMERA]

That's exactly what the Yellowstone gRPC interface provides. To understand how it works, you need to know about the Geyser plugin system. Geyser is an interface that Solana validators can expose. It allows an external process — running alongside or connected to the validator — to receive data directly as the validator processes each block, before that data even hits the standard RPC layer. You're getting it from closer to the source.

Yellowstone, sometimes called Dragon's Mouth, is a specific implementation of this that wraps the Geyser data stream in a standard gRPC API. gRPC is a high-performance remote procedure call framework built on HTTP/2 and Protocol Buffers — it's widely used for exactly this kind of high-throughput streaming use case. The result is a streaming API that delivers Solana blockchain data with sub-second latency at confirmed commitment.

Confirmed commitment, for context, means the block has been voted on by a supermajority of validators. On Solana, that typically happens within one or two slots — under a second. This is the commitment level you want for real-time analytics: low latency, with a very high probability of finality.

---

[SLIDE: What You Can Subscribe To]

[ON CAMERA]

What you actually subscribe to via Yellowstone comes in a few forms. Transaction subscriptions let you declare that you want all transactions involving a particular program or set of accounts — the data arrives as those transactions are confirmed. Account subscriptions deliver updates whenever specific accounts change state, useful for tracking pool reserves, lending positions, or any account whose value you want to monitor continuously. Block subscriptions give you full block data with embedded transactions, which is useful when you need the canonical block timestamp rather than inferring it.

One of the more powerful features is that you can combine all three subscription types on a single connection — so a single gRPC stream carries your transaction events, account updates, and block pings together without needing separate connections per data type. You can also add new subscriptions dynamically to a live stream, which means you can discover new accounts to track at runtime without reconnecting.

And critically: all of this filtering happens at the source. You're not receiving the full Solana transaction stream and discarding what you don't need. You declare what you care about, and only that comes down the pipe. At Solana's throughput, that distinction matters enormously.

---

[SLIDE: From Raw Stream to Signal]

[ON CAMERA]

Now, let's talk about what you actually do with the data when it arrives — because this is where a lot of the real engineering lives.

What you receive from the stream is raw transaction data. A Solana transaction is essentially a bundle of instructions. Each instruction is addressed to a specific program, identified by its program ID, and carries a binary-encoded payload. That payload's structure depends entirely on the program — it's not standardised across protocols.

So step one is matching each instruction to a known program. You're looking for instructions addressed to, say, the Orca Whirlpool program, or the Raydium CLMM program, or the Kamino Lending program — each identified by its on-chain address. Once you've found a relevant instruction, you need to decode the payload. Programs publish their instruction schemas — their IDLs — and you use those to interpret the binary data and understand what operation was being performed and with what parameters.

But here's where it gets more involved. Solana supports cross-program invocations — one program calling another program as part of the same transaction. So a single user-facing swap transaction might have an outer instruction that routes through a DEX aggregator, which internally calls into the specific DEX program, which in turn interacts with a token program to move balances. These nested calls appear as inner instructions in the transaction data. You need to unnest all of them to get the complete picture.

And even after decoding the instructions, you're not quite done. To reconstruct the actual token flows — how much of which token moved in which direction — you need to correlate the decoded instruction data with the pre- and post-transaction token balance changes that are included in the transaction receipt. The instruction tells you what was intended; the balance changes confirm what actually happened, including the fees.

Only after working through that whole chain can you produce a clean event record: this was a swap, on this pool, of this token, for this amount, at this implied price. That's the signal. Everything before it is noise that has to be parsed out.

The complexity scales with what you're monitoring. If you're tracking a single DEX program in isolation, it's manageable. If you're tracking multiple DEXes, a lending protocol, a stablecoin protocol, and transactions routed through aggregators that may invoke several of those programs in a single trade — then you're dealing with a substantial parsing and correlation challenge.

---

[SLIDE: Shyft Services]

[ON CAMERA]

So, given all of that — why Shyft?

Let me start with pricing, because it's concrete. At the time I evaluated providers, Shyft was the most cost-competitive option for dedicated Yellowstone gRPC access. And importantly, it's flat-rate pricing — not metered per request or per data volume. When you're running a continuous stream, metered pricing is unpredictable and hard to budget. Flat-rate means you know what you're paying regardless of how much data flows through, which is what you want for a production real-time system.

Documentation matters a lot more than people expect when you're first getting started. Shyft has genuinely high-quality docs. Not just API reference material, but actual use-case guides built around specific protocols — Orca, Raydium, PumpFun. Code examples across multiple languages. The kind of documentation where you can go from zero to a working subscription in an afternoon rather than spending a week figuring it out from first principles. They also have a solid web UI for exploring the API and testing filters if you're not starting from a terminal.

Beyond the gRPC streaming, Shyft also provides a GraphQL indexer — and this turned out to be genuinely useful for a different class of problem. The indexer maintains a queryable index of all accounts owned by specific programs. The alternative to this, for account discovery at scale, is `getProgramAccounts` — which is a full on-chain scan, expensive in terms of compute, slow, and not something you want to be calling repeatedly on a live system. The indexer replaces that with a fast, paginated GraphQL query. I use it to discover all LP positions across monitored DEX pools, and to fetch the full set of obligation accounts across the Kamino Lending markets — which numbers in the thousands. That's not practical via individual RPC calls.

All three Shyft services — Yellowstone gRPC, the GraphQL indexer, and standard JSON-RPC — operate on the same API key. One credential, one provider relationship, covering all three data access patterns.

Finally, the team. When I was first integrating Yellowstone, I had real questions that required real answers — not just the documentation, but specific behaviour I needed to understand. Shyft's team were actively responsive, helpful, and engaged. That kind of support when you're getting started has a real value that doesn't show up in a feature comparison table.

If you're building anything on Solana that requires real-time data, I'd strongly recommend checking them out. Link in the description. The next video covers the database layer — why I chose TigerData and how the ETL pipeline works from there.

---

## Slide Content

### Slide 1: The Solana Data Pipeline
Left-to-right flow diagram:

> **Solana Validator** → *Geyser plugin (in-process)* → **Yellowstone gRPC** → *Ingestion service* → **Database** → *Frontend*

Subtext: *Push-based stream — data arrives as blocks are confirmed, not when you ask for it*

---

### Slide 2: What You Can Subscribe To
Three columns with detail:

| Transactions | Account Updates | Blocks |
|---|---|---|
| Filter by program ID | Filter by account address | Full block with embedded txns |
| Filter by required accounts | Filter by owner program | Canonical block timestamp |
| Include/exclude failed txns | State changes only | Combine with tx subscriptions |
| *Use for: event capture* | *Use for: live state monitoring* | *Use for: block time alignment* |

Subtext: *All three on a single multiplexed connection — dynamic subscription updates without reconnecting*

---

### Slide 3: From Raw Stream to Signal
Step-by-step breakdown:

```
Raw transaction
  └─ Step 1: Match instructions to known program IDs
  └─ Step 2: Decode instruction payload (program IDL)
  └─ Step 3: Unnest inner instructions (CPI calls)
  └─ Step 4: Correlate with pre/post token balance changes
        ↓
  Clean event record:
  { type: "swap", pool, token_in, amount_in, amount_out, price }
```

Subtext: *Aggregator routes (e.g. Jupiter) = multiple DEX programs in one transaction*

---

### Slide 4: Why Shyft
Four points:

- **Pricing** — Flat-rate dedicated gRPC; most cost-competitive at evaluation
- **Documentation** — Use-case guides per DEX, multi-language code examples, web UI
- **GraphQL Indexer** — Fast account discovery at scale; replaces getProgramAccounts
- **One API key** — gRPC streaming + indexer + JSON-RPC under one credential

Subtext: *Team: responsive, hands-on support during integration*
