# Token Exclusion Rationale

The prospect search app filters out certain tokens before aggregation and scoring. These are tokens whose issuing teams are not realistic cold-outreach targets for the platform or services being sold.

The exclusion list lives in `app/config.py` as the `EXCLUDED_TOKENS` dictionary, keyed by Solana mint address. Each entry carries its symbol, category, and a short note explaining why it is excluded.

This document explains the reasoning by category.

---

## Categories

### Stablecoins

**Excluded:** USDC, USDT, PYUSD, DAI, UXD, USDY

Stablecoins appear in virtually every DEX pool, lending reserve, and yield market. Including them would dominate the output with the highest TVL, broadest presence, and most cross-venue connections — all of which reflect infrastructure ubiquity, not a project team's DeFi footprint.

The issuing entities (Circle, Tether, PayPal, MakerDAO, Ondo) are either too large to cold-outreach or operate in a fundamentally different market from the one the platform serves.

### Base-layer assets

**Excluded:** SOL, WBTC, tBTC, WETH

These are either the chain's native asset or bridge-wrapped versions of major L1 tokens. Like stablecoins, they appear as counterparts in almost every pool and would overwhelm the output without representing a reachable project team.

SOL is the native Solana token. WBTC, tBTC, and WETH are bridge-wrapped versions of Bitcoin and Ethereum — the issuing entities are either bridge infrastructure projects or the L1 ecosystems themselves.

### Liquid staking tokens (LSTs)

**Excluded:** mSOL, JitoSOL, stSOL, bSOL, INF

LSTs are derivative staking tokens. They appear heavily in DEX pairs and lending reserves because they are collateral primitives, not because they represent a distinct project with risk-monitoring needs that differ from their staking provider's core operations.

The teams behind these (Marinade, Jito, Lido, BlazeStake, Sanctum) are established infrastructure providers. They are not impossible outreach targets, but their inclusion would skew the results by adding high-TVL, high-breadth entries that reflect staking infrastructure rather than the kind of cross-protocol complexity the platform addresses.

If any of these become relevant outreach targets for specific reasons (e.g. Jito's MEV products creating monitoring needs), they can be removed from the exclusion list in `config.py`.

### Source protocol governance tokens

**Excluded:** ORCA, RAY

The prospect search queries Orca and Raydium as data sources. Including their governance tokens in the output would be circular — they would score highly because they appear on their own platform, which is where we are pulling data from.

---

## Design decisions

**Exclusion by mint address, not just symbol.** Symbols can be ambiguous or spoofed. The primary filter is the Solana mint address, which is unambiguous. The symbol-based fallback (`EXCLUDED_TOKEN_SYMBOLS`) catches cases where a token appears under a known symbol but its mint address isn't in the explicit list (e.g. a new USDC mint, a wrapped variant we haven't catalogued).

**Single dictionary as source of truth.** The `EXCLUDED_TOKENS` dictionary links mint, symbol, category, and rationale in one place. The `EXCLUDED_TOKEN_MINTS` set and `EXCLUDED_TOKEN_SYMBOLS` set are derived from it automatically, so the aggregator code doesn't need to change when entries are added or removed.

**Configurable, not hard-wired.** The exclusion list is meant to be edited as the outreach strategy evolves. For example:
- If a stablecoin project becomes a viable prospect (e.g. UXD pivots into risk tooling), remove it.
- If a new LST or wrapped asset starts appearing, add it.
- If the platform targets staking providers, remove the LST category entirely.

---

## Tokens that are _not_ excluded (and why)

Some tokens that might seem like infrastructure are deliberately kept in:

- **JTO** (Jito governance): Unlike JitoSOL (the LST), JTO represents the Jito Foundation's governance and treasury — a potentially reachable team.
- **JUP** (Jupiter governance): Jupiter is the dominant Solana aggregator. Their team has treasury, BD, and growth functions that could need cross-protocol visibility.
- **MNDE** (Marinade governance): Same reasoning as JTO — the governance token represents the team, not the staking derivative.
- **cbBTC** (Coinbase wrapped BTC): Large footprint on Solana across DEX and lending. Coinbase's Solana integration team could be reachable, though this is a judgment call. Currently included; could be excluded if outreach confirms it's not viable.
- **JLP** (Jupiter LP token): Jupiter's structured product. High TVL and cross-venue complexity. Represents a specific product that could benefit from monitoring.
- **Meme tokens** (Bonk, Fartcoin, etc.): These score lower but are not excluded because some meme tokens have active foundations, treasury operations, and BD functions. The downstream enrichment stage decides whether to pursue them.
