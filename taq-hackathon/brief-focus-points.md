# Daily Brief — Focus Points

Companion to [concept-daily-brief.md](concept-daily-brief.md). This doc defines **what the brief actually contains** — section by section, item by item — and why each item earns a spot.

The existing dashboard is deliberately broad: it lets an analyst look at everything. The brief is deliberately narrow: it tells an operator *what actually shifted in the last 24 hours*. Most items on most days will not fire, and the brief will be short. That is the product.

---

## Selection principles

1. **A useful item must be absent most days.** If an item fires every day, it is not a shift — it is a metric, and it belongs on the dashboard, not in the brief.
2. **An item must answer an owner's question, not describe a dataset.** "Utilization is 72%" is a metric. "USDC reserve crossed from normal into stressed overnight" is an event. The brief traffics only in events.
3. **Materiality is principled, not hand-chosen.** Where possible, thresholds derive from `risk_pvalues` (empirical percentile distributions already maintained in the substrate) or from configured zone boundaries (already in `risk_policies`). No magic numbers.
4. **No duplicate reporting across sections.** A large swap shows up once — under DEXes — not again in the ecosystem section. The ecosystem section does not repeat what protocol sections already cover; it reports only what is visible at the ecosystem level and not elsewhere.
5. **Owner-centric framing.** Every item names what changed, by how much, and optionally why it matters. It does not name the underlying CAGG or SQL function.
6. **Each section has a "quiet day" form.** When nothing material fires, the section collapses to one line (e.g. "Kamino — quiet, no zone transitions, no liquidations, utilisation within normal band"). The owner still sees the section and knows it was checked.

---

## Time comparison discipline

The brief reports **changes**, not levels. Every item fires on one of three comparison shapes:

1. **Overnight delta** — today's value vs. ~24 hours ago. Example: *"Borrow APY moved +42 bps since yesterday."*
2. **24h event** — a discrete event or transition inside the 24h window. Example: *"USDC reserve crossed into stressed zone at 06:12 UTC."* / *"Swap above p99 executed overnight."*
3. **Baseline breach** — the 24h aggregate (value, flow, or distribution) falls outside a historical band (7-day trailing, or an empirical percentile from `risk_pvalues`). Example: *"24h net sell pressure exceeded the p95 of trailing distribution."*

**What the bullet shows is the change itself, never the current level alone.** "Pool depth down 18% overnight" is a brief item; "Pool depth 1.2M" is not. If the answer to "did this change?" is "no," the item does not fire.

Every item's "Fires when" column below names its comparison explicitly. Shape (1) uses "vs. 24h ago"; shape (2) describes the discrete transition or event; shape (3) uses "vs. 7d baseline" or a percentile reference.

---

## Section 1 — Ecosystem (cross-protocol)

This section reports only things that are *not* visible by looking at any single protocol. Its job is to detect rotation, composition shifts, and systemic signals.

| # | Item | Fires when | What it signals | Source |
|---|---|---|---|---|
| E1 | **Supply composition shift** | Share of ONyc held as unwrapped vs. wrapped (SY) vs. tokenised (PT+YT) moved > configured band vs. 7d trailing | Tokenisation activity — capital moving into or out of wrapped/maturity-bearing forms | Exponent supply CAGGs (`cagg_sy_token_account_5s`, `cagg_market_twos_5s`) |
| E2 | **Venue TVL migration** | ONyc TVL share held by any venue (DEXes / Kamino / Exponent) moved > threshold vs. 7d baseline | Capital rotation between lending, LP, and yield — leading indicator of sentiment | Cross-schema TVL aggregation |
| E3 | **Availability shift** | Share of ONyc classified as *liquid DeFi* / *illiquid DeFi* / *free-undeployed* moved > pp vs. 7d baseline | Stress signal — rising *illiquid* share can mean trapped capital; falling *free* share means deployment is increasing | Cover-page availability view |
| E4 | **Activity rotation** | 24h activity share by venue deviates from 7d average by > threshold, or total 24h activity outside the 7d normal band | Which venue is doing the work today vs. historically; detects unusual surges | Activity-by-protocol CAGGs |
| E5 | **Cross-venue yield spread** | Spread between highest and lowest ONyc-earning venue widens or compresses by > bps vs. 7d baseline | Arb dynamics — compression means the ecosystem is at equilibrium; dispersion means opportunity or dislocation | Yield comparison view |

Five items, max. If all are quiet: "Ecosystem — structure unchanged, no notable rotation."

---

## Section 2 — DEXes (Orca + Raydium, combined)

The two DEX venues are reported together because a project owner thinks about "DEX exposure," not "Orca exposure" and "Raydium exposure" separately. Per-venue breakdowns live in the click-through, not the brief.

| # | Item | Fires when | What it signals | Source |
|---|---|---|---|---|
| D1 | **Peg spread event** | 24h VWAP deviates from 1.00 peg by > bps threshold, or 24h VWAP moved > bps vs. prior 24h VWAP | Pricing dislocation — the headline DeFi-peg signal, catching both off-peg state and overnight drift | `cagg_events_5s` (VWAP), pool price |
| D2 | **Extreme sell event** | Any individual sell event at or above p99 of its 24h magnitude distribution | Stress event — already pre-computed in `risk_pvalues`, high-signal | `src_tx_events` vs. `risk_pvalues` |
| D3 | **Liquidity depth change** | Cumulative depth within peg-neighbourhood moved > % vs. 7d baseline (either direction) | LP behaviour — depth shrinkage elevates tail risk; depth growth signals confidence | `cagg_tickarrays_5s`, `src_acct_tickarray_tokendist_latest` |
| D4 | **Net flow imbalance** | 24h net sell (or net buy) pressure exceeds p95 of trailing 7d distribution | Directional conviction — distinguishes a balanced day from one-sided flow | `cagg_events_5s` |
| D5 | **Large single swap** | Any swap above size threshold (configured in ONyc terms) | Counterparty event — a single actor making a material move | `src_tx_events` |
| D6 | **Large LP event** | Any single LP add or remove above % of pool threshold | Structural liquidity change by a single LP | `src_acct_position` |

Six items. In a quiet market, most days show D3 at most.

---

## Section 3 — Kamino Lending

| # | Item | Fires when | What it signals | Source |
|---|---|---|---|---|
| K1 | **Utilisation zone transition** | Any tracked reserve crossed a zone boundary (normal / stressed / critical) in the 24h window | Most important Kamino signal — zone breaches change the risk character of lending | `cagg_reserves_5s`, zone thresholds |
| K2 | **Liquidations occurred** | Any liquidation event in the 24h window | Headline event — liquidations are rare, and when they happen they lead the brief | `cagg_activities_5s` |
| K3 | **Borrow APY move** | Any tracked reserve's borrow APY moved > bps vs. 24h ago | Rate regime shift — relevant for both borrowers (cost) and depositors (yield) | `cagg_reserves_5s` |
| K4 | **TVL shift** | Reserve supply or borrow TVL moved > % vs. 7d baseline on any tracked reserve | Capital flows in/out of the market at reserve level | `cagg_reserves_5s` |
| K5 | **Top obligation health change** | Any top-N obligation's health factor dropped below a configured threshold, or moved > % vs. its own 7d value | Concentrated risk — small-N borrowers that carry large-value debt | `src_obligations_last` |
| K6 | **Debt-at-risk trajectory** | Aggregate debt-at-risk under standard (±1σ) stress moved > % vs. 7d baseline | System-level lending stress measure, already computed for the risk dashboard | `v_last`, sensitivity functions |

Six items. Most days, K1 and K2 do not fire; K3 and K4 are the routine high-signal items.

---

## Section 4 — Exponent Yield

| # | Item | Fires when | What it signals | Source |
|---|---|---|---|---|
| X1 | **Fixed rate movement** | Implied PT fixed APY on a market moved > bps vs. 24h ago | Yield-market pricing — the primary Exponent signal | `cagg_market_twos_5s`, PT price functions |
| X2 | **Fixed–variable rate spread** | Spread between PT implied fixed rate and realised underlying variable rate widened or narrowed > bps vs. 24h ago | Yield-curve steepening/flattening — information about market conviction | `cagg_vaults_5s` + `cagg_market_twos_5s` |
| X3 | **AMM depth / deployment change** | SY-in-pool or deployment ratio moved > % vs. 24h ago on any tracked market | Market-maker capital decisions — AMM liquidity is active, not passive | `cagg_market_twos_5s` |
| X4 | **Large PT trade** | Any PT buy or sell above size threshold | Counterparty event — similar to DEX-D5 but on yield-market side | `cagg_tx_events_5s` (Exponent) |
| X5 | **Maturity / discovery event** | A new market was discovered in the last 24h, or an existing market crosses into its final N days before expiry | Structural change — new market adds surface area; near-expiry changes position behaviour | `aux_key_relations`, vault maturity timestamps |

Five items. X5 is rare; the core of Exponent reporting is X1–X3.

---

## Explicitly excluded (and why)

These items were considered and deliberately left out. Including them would dilute the brief.

- **Routine yield accrual** on Kamino deposits and Exponent SY. Expected behaviour. Only *deviations* are material.
- **Individual tick-level concentration shifts** on DEX pools. Too granular for a brief; already visible on the Risk page.
- **Individual obligation health factor changes** below the top-N watchlist. Long tail of noise.
- **Sub-threshold price movements**. If a move is inside the configured noise band, it is not reported — reporting it would train the reader to ignore the brief.
- **Individual LP position snapshots** that do not cross the "large LP event" threshold.
- **Base-table and CAGG freshness indicators**. Operational concerns belong to System Health, not to an owner's brief.
- **New Exponent market discovery** below a liquidity-depth threshold. Test markets and dummy deployments must not fire the brief.
- **Intraday bucket-level noise**. The brief aggregates at the 24h horizon; intra-day is a separate, optional alert channel.

---

## Summary matrix

| Section | # items | Firing frequency | Quiet-day form |
|---|---|---|---|
| Ecosystem | 5 | Low–medium | "Structure unchanged, no notable rotation" |
| DEXes (Orca + Raydium) | 6 | Medium | "Markets balanced, depth stable, no extreme events" |
| Kamino | 6 | Low–medium | "Utilisation within band, no liquidations, rates stable" |
| Exponent | 5 | Medium | "Rates unchanged, AMM depth stable" |

**Total maximum surface area: 22 items.** On a typical day, probably 0–3 fire. On an interesting day, 3–7. Only during a significant event should the brief be long.

---

## Open questions for the build pass

1. **Who configures the thresholds?** Shipped defaults vs. a small config surface. Hackathon scope suggests shipped defaults with the values traceable in the codebase.
2. **Is the "top-N obligation watchlist" fixed, or does it shift?** If it shifts, the brief must note when someone enters or leaves the watchlist — a small but real item.
3. **How does the brief handle the "no data" degenerate case** (pipeline outage overnight)? Must degrade gracefully — the brief must never silently omit sections due to missing data.
4. **Do we version the brief's item schema?** Each day's brief is a JSON document of fired facts; if the schema evolves, old briefs must still render.
5. **Is there a "week in review" rollup** that aggregates 7 daily briefs? Probably out of scope for hackathon, but worth a single-line roadmap mention.
