# Changing Target DeFi Markets

## Dexes Service

### Pointing to Different Pools

Switching the pools monitored by the dexes service requires **no code changes** -- it is entirely env-var driven.

| Env Var | Format | Purpose |
|---------|--------|---------|
| `POOLS` | `address:pair:protocol,address:pair:protocol,...` | Pool addresses to monitor. Protocol must be `raydium` or `orca`. |
| `TOKENS` | `mint_address:symbol:decimals,...` | Token metadata for any mints referenced by the pools. |

Example:

```
POOLS=EWivkw...:USX-USDC:raydium,3ucNos...:SOL-USDC:raydium
TOKENS=So11111111111111111111111111111111111111112:SOL:9,EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v:USDC:6
```

If `POOLS` is unset, the service falls back to `LOCAL_POOLS_DATA` hardcoded in `dexes/config.py`. In production, the env var takes precedence.

Everything downstream (gRPC filtering, RPC polling, tick array fetching, depth tracking, DB writes) is driven off these two registries.

### Additional Env Vars That May Need Updating

| Env Var | When to change |
|---------|----------------|
| `DEXES_GRPC_TRANSACTION_FILTER_LIST` | Only if the new pool runs on a DEX program other than Raydium CLMM or Orca Whirlpool. Add the new program ID to this comma-separated list. |
| `MARKET_MAKER_ADDRESSES` | If tracking different LP wallets on the new pool. Format: `label:address,...` |

### Tick Array Discovery and Price Range Considerations

Tick array accounts are found via **PDA derivation** (deterministic address calculation), not on-chain scanning. The range of tick arrays fetched around the current price is configurable:

| Env Var | Default | Description |
|---------|---------|-------------|
| `TICKARRAY_SET` | `fixed` | Strategy: `fixed` (percentage spread around price) or `up-to-edge` (expand until liquidity edges found). |
| `TICKARRAY_SPREAD_BELOW_PCT` | 4.0 | Fixed-mode: percentage below current price to fetch. |
| `TICKARRAY_SPREAD_ABOVE_PCT` | 4.0 | Fixed-mode: percentage above current price to fetch. |
| `TICKARRAY_EDGE_DISCOVERY_ATTEMPTS` | `10.0,25.0,50.0,100.0` | Edge-mode: progressive spread percentages tried sequentially. |
| `DEPTH_SPREAD_CALC_BELOW_PCT` | 2.0 | Depth calculation window (subset of fetched data). |
| `DEPTH_SPREAD_CALC_ABOVE_PCT` | 2.0 | Depth calculation window (subset of fetched data). |

**Stablecoin pools** (current use case): The defaults (4% fetch spread) are more than adequate.

**Volatile pairs** (e.g. SOL-USDC): The defaults will miss liquidity deployed far from the current price. Options:

- Increase `TICKARRAY_SPREAD_BELOW/ABOVE_PCT` to 30-50%, or
- Switch to `TICKARRAY_SET=up-to-edge` and widen `TICKARRAY_EDGE_DISCOVERY_ATTEMPTS` (e.g. `25.0,50.0,100.0,200.0,500.0`)

The practical limit is RPC performance: each tick array is a separate account fetch, batched 100 per RPC call. Wide-range pools with many initialised tick arrays will increase poll cycle time and RPC costs.

### Market Maker Position Monitoring

The `MARKET_MAKER_ADDRESSES` env var (format: `label:address,...`) drives the `PositionAccountPoller`. This is only active when **both** `POSITION_POLL_ENABLED=true` and addresses are configured.

The poller discovers LP positions by:

1. Querying each wallet's NFT holdings via RPC (LP positions are NFTs on Raydium CLMM / Orca Whirlpool)
2. Looking up position details (liquidity, tick range, fees) via GraphQL indexer
3. Filtering to positions in the configured `POOLS` set
4. Writing snapshots to `src_acct_position` with change detection

When changing pools, this will automatically pick up any market maker positions in the new pools -- no additional configuration needed beyond `POOLS` and `MARKET_MAKER_ADDRESSES`.

### Deployment Architecture

The production setup runs **two instances** of the same codebase against the same pool set, split by concern:

| Instance | Env File | `POOL_STATE_UPDATE_MODE` | `SERVICE_ID` | Writes |
|----------|----------|--------------------------|--------------|--------|
| Transactions | `.env.prod.dexes.txns` | `hybrid` (gRPC-only via `ACCOUNT_RPC_POLL_ENABLED=false`) | `grpc_txns_only` | `src_transactions`, `src_tx_events` |
| Accounts | `.env.prod.dexes.accts` | `polling` (pure RPC) | `rpc_accounts_only` | `src_acct_pool`, `src_acct_vaults`, tick arrays, positions |

When adding new pools, **both** env files need the updated `POOLS` and `TOKENS` values.

---

## Exponent Service

### Pointing to Different Markets

The exponent service can be retargeted to track different underlying tokens via a **single env var**. The dynamic market discovery pipeline then handles the rest.

| Env Var | Format | Purpose |
|---------|--------|---------|
| `EXPONENT_BASE_TOKENS` | `address:symbol:decimals,...` | Underlying tokens to track. Discovery finds all Exponent markets for these tokens. |

Example -- tracking a hypothetical mSOL yield market:

```
EXPONENT_BASE_TOKENS=mSoLzYCxHdYgdzU16g5QSh3i5K3z3KZK7ytfqcJm7So:mSOL:9
```

When `EXPONENT_BASE_TOKENS` is set, the following happens automatically:

1. `EXP_MARKET_TRACKED_BASE_TOKENS` is populated from the env var
2. `EXPONENT_MARKETS` (the seed list) is cleared to `[]`
3. `TOKEN_METADATA` (static token metadata) is cleared to `{}`
4. At startup, dynamic market discovery hits the Exponent API, finds all markets whose underlying token matches the configured addresses, and populates `EXPONENT_MARKETS` in-memory
5. Full account discovery runs (vaults, MarketTwo, YT escrows, SY metas, underlying escrows) via PDA derivation and RPC
6. Token metadata is fetched from on-chain and cached at runtime
7. gRPC subscriptions are configured for the discovered accounts

If `EXPONENT_BASE_TOKENS` is **not set**, the service uses the hardcoded defaults (eUSX, USX) -- no change to existing behaviour.

### Additional Env Vars

| Env Var | Default | Purpose |
|---------|---------|---------|
| `EXPONENT_MARKETS` | (hardcoded seed list) | Override with `""` or `"[]"` to clear seed list and rely on discovery. Or provide comma-separated MarketTwo addresses. Auto-cleared when `EXPONENT_BASE_TOKENS` is set. |
| `EXPONENT_ENABLE_DYNAMIC_MARKET_DISCOVERY` | `true` | Must be `true` for discovery to work (default). If `false`, only seed markets in `EXPONENT_MARKETS` are used. |
| `EXPONENT_TEST_MARKET_MIN_DEPTH_RAW` | `50000000000` (50B raw = $50K for 6-decimal tokens) | Minimum market depth to filter out test deployments. Adjust for different token decimals. |
| `DB_EXPONENT_SCHEMA` | `exponent` | Database schema. Use a different schema when testing new markets to avoid polluting production data. |

### How Discovery Works

The discovery pipeline is fully automated once `EXPONENT_BASE_TOKENS` provides the targeting:

1. **Market discovery**: Calls `https://web-api.exponent.finance/api/markets`, filters by underlying token addresses from `EXP_MARKET_TRACKED_BASE_TOKENS`, filters out test markets below depth threshold
2. **Account discovery**: For each discovered market, extracts vault from MarketTwo account data, derives PDAs for PT/YT mints, finds YT escrows, SY metas, and underlying escrows
3. **Token metadata**: Fetched from on-chain (Metaplex/Shyft API) for all discovered mints -- no static config needed
4. **gRPC subscriptions**: Account filter list populated from discovered accounts; transaction filter always uses the Exponent program ID

Discovery runs once at startup and periodically thereafter (every `EXPONENT_MARKET_DISCOVERY_CHECK_INTERVAL` poll cycles, default 10). New markets deployed on-chain are picked up automatically.

### Key Difference from Dexes

The dexes service requires explicit pool addresses. The exponent service discovers markets automatically from underlying token addresses -- you specify *what tokens* to track, not *which specific markets*. This means new Exponent markets for the same underlying token are picked up without any configuration change.

### Prerequisite: `EXPONENT_ENABLE_DYNAMIC_MARKET_DISCOVERY`

When using `EXPONENT_BASE_TOKENS` with an empty seed list, dynamic discovery **must** be enabled (it is by default). If discovery is disabled and `EXPONENT_MARKETS` is empty, the service will have nothing to monitor.

---

## Kamino Service

### Pointing to a Different Lending Market

The kamino service can be retargeted to a different Kamino lending market via a **single env var**. Reserve discovery then handles the rest.

| Env Var | Format | Purpose |
|---------|--------|---------|
| `KAMINO_LENDING_MARKET_ADDRESS` | Solana address | The Kamino lending market account to monitor. |

Example:

```
KAMINO_LENDING_MARKET_ADDRESS=7u3HeHxYDLhnCoErrtycNokbQYbWGzLs6JSDqGAv5PfF
```

When `KAMINO_LENDING_MARKET_ADDRESS` is set:

1. `LENDING_MARKET_ADDRESS` is set to the provided address
2. `RESERVE_ATTRIBUTES` (the seed reserve list) is auto-cleared to `[]`
3. On the first poll, `load_kamino_market` falls back to RPC `getProgramAccounts` discovery -- finds all reserves for the given lending market on-chain
4. Obligations are fetched via GraphQL (keyed on `LENDING_MARKET_ADDRESS`, independent of reserves)
5. After obligation data is written, DB-driven reserve discovery enriches the reserve list with symbol, decimals, type, and vault addresses
6. Subsequent polls use the fully enriched reserve list

If `KAMINO_LENDING_MARKET_ADDRESS` is **not set**, the service uses the hardcoded default -- no change to existing behaviour.

### Bootstrap Behaviour

With an empty seed reserve list, the **first poll cycle** (~90s) operates in a slightly degraded mode:

- **Obligations**: Fetched normally via GraphQL (does not need reserves)
- **Market data**: Loaded via RPC, reserves discovered via `getProgramAccounts` (1 extra RPC call, ~400-800ms)
- **Reserve data**: Available from the `getProgramAccounts` discovery, but without enriched metadata (symbol, type)

From **poll 2 onwards**: DB-driven discovery has obligation data to work with, enriches reserves fully, and the service runs normally.

### Additional Env Vars

| Env Var | Default | Purpose |
|---------|---------|---------|
| `KAMINO_RESERVE_ADDRESSES` | (hardcoded seed list) | Override with `""` or `"[]"` to clear seed list. Or provide comma-separated reserve addresses for minimal seed metadata. Auto-cleared when `KAMINO_LENDING_MARKET_ADDRESS` is set. |
| `KAMINO_PROGRAM_ID` | `KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD` | Kamino Lend program ID. Only change if monitoring a different program deployment (unlikely). |
| `DB_KAMINO_SCHEMA` | `kamino_lend` | Database schema. Use a different schema when testing new markets. |

### How Discovery Works

Reserve discovery has two mechanisms:

1. **RPC `getProgramAccounts`** (first poll fallback): Queries the Solana RPC for all reserve accounts belonging to the lending market. Expensive but comprehensive -- works without any prior data.

2. **DB-driven discovery** (ongoing): After obligation data flows into `src_obligations_agg`, the `ReserveDiscovery` class extracts reserve addresses from the borrow/deposit arrays, enriches via RPC (symbol, decimals, token_mint, vault addresses), and updates `RESERVE_ATTRIBUTES` in-place. Runs at init and after each obligation write cycle.

### Key Difference from Dexes and Exponent

Kamino is **market-address driven** -- you provide the lending market, and reserves are discovered from on-chain program data and obligation analysis. No API calls to external services are needed (unlike Exponent's API-based market discovery).
