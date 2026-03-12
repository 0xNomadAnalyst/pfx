# Asset-Level Stress Testing

Extension to `kamino_lend.get_view_klend_sensitivities` that enables stressing individual assets rather than applying a uniform shock to all collateral or all borrows.

## Why

Kamino lending obligations can hold multiple assets. A single obligation might have deposits in both ONyc and USDG, or borrows in both USDC and USDS. The original sensitivity function applied the same percentage shock to the entire deposit or borrow value uniformly. This misrepresents risk for multi-asset obligations because different assets have different volatility profiles.

## How It Works

### Per-Obligation Stressed Share

Each obligation in `src_obligations_last` carries per-asset position arrays:

| Column | Description |
|---|---|
| `deposit_reserve_by_asset` | Reserve addresses for each deposit position |
| `deposit_market_value_sf_by_asset` | Market value (scaled fraction) per deposit |
| `borrow_reserve_by_asset` | Reserve addresses for each borrow position |
| `borrow_market_value_sf_by_asset` | Market value (scaled fraction) per borrow |
| `resrv_address` / `resrv_symbol` | Market-level mapping from reserve address to symbol |

When target symbols are specified (e.g., `ARRAY['ONyc']`), `compute_stressed_share()` computes the fraction of each obligation's total deposit (or borrow) value that belongs to those symbols. This fraction (`stressed_share`, 0.0 to 1.0) is then used to apply the shock only to that portion.

### Partial Sensitization Formula

At each stress step `i`:

```
value[i] = current_value * (1 + stressed_share * delta_bps * i / 10000)
```

When `stressed_share = 1.0` (all assets stressed), this is identical to the original uniform shock. When `stressed_share = 0.5`, only half the value swings; the other half stays constant.

### Data Flow

```
src_obligations_last
    |
    |-- per-asset arrays + resrv_symbol mapping
    v
compute_stressed_share()          -- fraction of value in target symbols
    |
    v
sensitize_value_partial()         -- generates deposit/borrow arrays with partial shock
    |
    v
compute_ltv_array()               -- derives LTV from actual deposit/borrow arrays
    |
    v
[existing downstream logic]       -- flag_arrays, value_arrays, market_aggregates
    |
    v
output (same schema as before)
```

## Function Reference

### `get_view_klend_sensitivities`

Main entry point. New parameters appended to existing signature:

| Parameter | Type | Default | Description |
|---|---|---|---|
| `p_query_id` | `BIGINT` | `NULL` | Deprecated. Always uses latest state. |
| `assets_delta_bps` | `INTEGER` | `-25` | Collateral price change per step (must be <= 0) |
| `assets_delta_steps` | `INTEGER` | `20` | Number of collateral drop steps |
| `liabilities_delta_bps` | `INTEGER` | `25` | Borrow value change per step (must be >= 0) |
| `liabilities_delta_steps` | `INTEGER` | `10` | Number of borrow increase steps |
| `include_zero_borrows` | `BOOLEAN` | `FALSE` | Include obligations with < $1 borrow |
| **`p_coll_assets`** | **`TEXT[]`** | **`NULL`** | **Collateral symbols to stress. NULL = all.** |
| **`p_lend_assets`** | **`TEXT[]`** | **`NULL`** | **Borrow symbols to stress. NULL = all.** |

Output schema is unchanged from the original function.

### `compute_stressed_share`

```sql
kamino_lend.compute_stressed_share(
    position_reserves  TEXT[],     -- e.g., deposit_reserve_by_asset
    position_values_sf NUMERIC[], -- e.g., deposit_market_value_sf_by_asset
    resrv_addresses    TEXT[],     -- resrv_address (all market reserves)
    resrv_symbols      TEXT[],     -- resrv_symbol (parallel with resrv_addresses)
    target_symbols     TEXT[]      -- symbols to stress
) RETURNS NUMERIC  -- 0.0 to 1.0
```

Returns 1.0 when position arrays are NULL/empty (full-stress fallback).

### `sensitize_value_partial`

```sql
kamino_lend.sensitize_value_partial(
    current_value   NUMERIC,   -- total deposit or borrow value
    stressed_share  NUMERIC,   -- fraction to shock (0.0 to 1.0)
    delta_bps       INTEGER,   -- basis points per step
    steps           INTEGER    -- number of steps
) RETURNS NUMERIC[]  -- length = steps + 1
```

Generalized replacement for `sensitize_deposit_value` / `sensitize_borrow_value`.

### `compute_ltv_array`

```sql
kamino_lend.compute_ltv_array(
    deposit_array NUMERIC[],
    borrow_array  NUMERIC[]
) RETURNS NUMERIC[]  -- LTV percentages
```

Derives LTV directly from deposit/borrow arrays. Replaces `sensitize_ltv()` which assumed a uniform shock.

## Usage Examples

```sql
-- Uniform stress (original behavior, backward-compatible):
SELECT * FROM kamino_lend.get_view_klend_sensitivities(
    NULL, -100, 50, 100, 50, FALSE
);

-- Stress only ONyc collateral, all borrows:
SELECT * FROM kamino_lend.get_view_klend_sensitivities(
    NULL, -100, 50, 100, 50, FALSE,
    ARRAY['ONyc'], NULL
);

-- Stress AUSD + ONyc collateral, only USDS borrows:
SELECT * FROM kamino_lend.get_view_klend_sensitivities(
    NULL, -100, 50, 100, 50, FALSE,
    ARRAY['AUSD', 'ONyc'], ARRAY['USDS']
);

-- Explicit "all" (same as NULL):
SELECT * FROM kamino_lend.get_view_klend_sensitivities(
    NULL, -100, 50, 100, 50, FALSE,
    ARRAY['All'], ARRAY['All']
);
```

## File Locations

| File | Purpose |
|---|---|
| `pfx/dbsql/functions/kamino/compute_stressed_share.sql` | Per-obligation value fraction calculator |
| `pfx/dbsql/functions/kamino/sensitize_value_partial.sql` | Partial-shock value array generator |
| `pfx/dbsql/functions/kamino/compute_ltv_array.sql` | LTV array from deposit/borrow arrays |
| `pfx/dbsql/frontend-views/kamino/get_view_klend_sensitivities.sql` | Main sensitivity function (modified) |

---

# Liquidation Cascade Amplification

Extension that models second-order effects of collateral liquidation on DEX pool prices, creating a feedback loop that amplifies exogenous shocks.

## Why

The sensitivity curve from `get_view_klend_sensitivities` assumes the price shock is purely exogenous. In reality, when collateral is liquidated, it gets sold on DEX pools, pushing the collateral price down further. This additional price drop can trigger more liquidations, creating a cascade. Modeling this feedback loop reveals the true equilibrium shock for a given initial perturbation.

## How It Works

The simulation covers both sides of the sensitivity curve.

### Left Side: Single-Axis Cascade (Collateral Decrease)

For each exogenous collateral shock:

1. Look up `total_liquidatable_value` at the current shock level (interpolated from the sensitivity curve)
2. Convert the USD liquidatable value to token quantity using the Kamino oracle price
3. Compute the DEX price impact of selling that quantity via `dexes.impact_bps_from_qsell_latest`
4. The equilibrium shock = initial shock + cascade impact
5. Repeat until the shock converges (change < threshold) or max rounds reached

The cascade stays on the same axis: collateral drops further with each round.

### Right Side: Cross-Axis Cascade (Debt Increase)

When debt value increases, the same collateral gets liquidated and sold on the DEX. This creates a cascade on a *different* axis:

1. Debt increases by X% -> some loans become unhealthy -> `L_debt` of collateral is liquidatable
2. Selling `L_debt` on the DEX pushes collateral price down by C%
3. The induced collateral decline C% triggers additional liquidations from the left-side curve: `L_coll`
4. Combined sell pressure = `L_debt + L_coll` (conservative upper bound; may double-count obligations unhealthy from both effects)
5. Recompute DEX impact with the larger quantity -> new induced collateral decline
6. Iterate until convergence

The `L_debt + L_coll` estimate is a worst-case upper bound, consistent with the 100% sale assumption. Some obligations may appear in both `L_debt` (unhealthy due to debt increase) and `L_coll` (unhealthy due to collateral decline), which would require 2D stress testing to resolve precisely.

### Sign Convention

The DEX impact function returns BPS on a `token1/token0` price basis:
- If collateral = `t0`: selling pushes BPS negative (collateral depreciates) -- use directly
- If collateral = `t1`: selling pushes BPS positive (ratio rises) -- negate for collateral depreciation

The `resolve_dex_pool` function dynamically determines which side the collateral token occupies.

### Asset-Level Stress Alignment

For physically meaningful cascade results, the sensitivity curve's x-axis should represent the price change of the **specific** collateral being modeled. Pass `p_coll_assets = ARRAY['ONyc']` (matching `p_coll_symbol`) so the stress axis aligns with the cascade axis. Using uniform stress (all assets) with a single-asset cascade will understate the amplification.

### Data Flow

```
get_view_klend_sensitivities(p_coll_assets=ARRAY['ONyc'])
    |
    |-- LEFT side: pct_change[] vs total_liquidatable_value[] (collateral decrease)
    |-- RIGHT side: pct_change[] vs total_liquidatable_value[] (debt increase)
    v
resolve_dex_pool('ONyc')
    |
    |-- pool_address, token_side ('t0' or 't1')
    v
cagg_reserves_5s (latest market_price for 'ONyc')
    |
    v
[LEFT: single-axis cascade per shock level]
    |-- interpolate liquidatable value at current shock
    |-- qty = liquidatable_usd / token_price
    |-- bps = impact_bps_from_qsell_latest(pool, side, qty)
    |-- cascade_pct = bps / 100 * sign_multiplier
    |-- new_shock = initial + cascade_pct -> converge
    |
[RIGHT: cross-axis cascade per shock level]
    |-- L_debt = liquidatable from debt increase (fixed)
    |-- L_coll = interpolate from left-side curve at induced_coll_decline
    |-- L_total = L_debt + L_coll (conservative)
    |-- qty = L_total / token_price -> DEX impact -> new coll_decline -> converge
    v
output: initial_shock_pct, equilibrium_shock_pct, induced_coll_decline_pct, ...
```

## Function Reference

### `resolve_dex_pool`

```sql
kamino_lend.resolve_dex_pool(
    p_symbol TEXT    -- Kamino reserve token symbol (e.g., 'ONyc')
) RETURNS TABLE (
    pool_address  TEXT,   -- DEX pool address
    token_side    TEXT,   -- 't0' or 't1'
    token0_symbol TEXT,
    token1_symbol TEXT
)
```

Resolves a token symbol to its DEX pool via `dexes.pool_tokens_reference`. Assumes each symbol maps to exactly one pool.

### `simulate_cascade_amplification`

```sql
kamino_lend.simulate_cascade_amplification(
    -- Sensitivity pass-through (same as get_view_klend_sensitivities)
    p_query_id              BIGINT   DEFAULT NULL,
    p_assets_delta_bps      INTEGER  DEFAULT -100,
    p_assets_delta_steps    INTEGER  DEFAULT 50,
    p_liabilities_delta_bps INTEGER  DEFAULT 100,
    p_liabilities_delta_steps INTEGER DEFAULT 50,
    p_include_zero_borrows  BOOLEAN  DEFAULT FALSE,
    p_coll_assets           TEXT[]   DEFAULT NULL,
    p_lend_assets           TEXT[]   DEFAULT NULL,
    -- Cascade-specific
    p_coll_symbol                TEXT    DEFAULT NULL,   -- collateral to model
    p_max_rounds                 INTEGER DEFAULT 10,     -- max iterations
    p_convergence_threshold_pct  NUMERIC DEFAULT 0.1     -- stop threshold (%)
) RETURNS TABLE (
    initial_shock_pct         NUMERIC,  -- exogenous shock from curve x-axis
    equilibrium_shock_pct     NUMERIC,  -- left: after cascade; right: same as initial
    amplification_factor      NUMERIC,  -- left: equilibrium / initial; right: 1.0
    cascade_rounds            INTEGER,  -- iterations to converge
    cascade_impact_pct        NUMERIC,  -- left: additional collateral %; right: 0
    total_liquidated_usd      NUMERIC,  -- total collateral sold at equilibrium
    induced_coll_decline_pct  NUMERIC,  -- induced collateral price decline (both sides)
    debt_triggered_liq_usd    NUMERIC,  -- right: from debt increase; left: 0
    cascade_triggered_liq_usd NUMERIC,  -- additional from cascade effect
    sell_qty_tokens           NUMERIC,  -- token quantity dumped on DEX
    pool_depth_used_pct       NUMERIC,  -- % of pool downside depth consumed
    liq_pct_of_deposits       NUMERIC   -- liquidated value as % of total deposits
)
```

| Output column | Left side meaning | Right side meaning |
|---|---|---|
| `initial_shock_pct` | Exogenous collateral decline | Exogenous debt increase |
| `equilibrium_shock_pct` | Collateral decline after cascade | Same as initial (debt axis unchanged) |
| `amplification_factor` | equilibrium / initial (> 1.0) | 1.0 (no debt-axis amplification) |
| `cascade_impact_pct` | Additional collateral decline from cascade | 0 (cascade is on collateral axis, not debt) |
| `total_liquidated_usd` | Collateral sold at equilibrium | Combined L_debt + L_coll at convergence |
| `induced_coll_decline_pct` | Same as `cascade_impact_pct` | Collateral price decline from sell pressure |
| `debt_triggered_liq_usd` | 0 | Liquidated value from initial debt trigger |
| `cascade_triggered_liq_usd` | All of `total_liquidated_usd` | Additional from cascade-induced collateral decline |
| `sell_qty_tokens` | Token quantity sold on DEX | Token quantity sold on DEX |
| `pool_depth_used_pct` | Sell qty as % of pool's total downside depth | Same |
| `liq_pct_of_deposits` | Liquidated value as % of baseline total deposits | Same |

## Usage Examples

```sql
-- Cascade simulation for ONyc collateral stress:
SELECT * FROM kamino_lend.simulate_cascade_amplification(
    NULL, -100, 50, 100, 50, FALSE,
    ARRAY['ONyc'], NULL,         -- stress only ONyc collateral
    'ONyc'                       -- model cascade on ONyc DEX pool
);

-- With tighter convergence and more rounds:
SELECT * FROM kamino_lend.simulate_cascade_amplification(
    NULL, -100, 50, 100, 50, FALSE,
    ARRAY['ONyc'], NULL,
    'ONyc', 20, 0.01
);

-- Without cascade (p_coll_symbol = NULL): returns raw sensitivity curve
SELECT * FROM kamino_lend.simulate_cascade_amplification(
    NULL, -100, 50, 100, 50, FALSE
);
```

## Prerequisites

The cascade simulation requires:
- DEX liquidity data in `dexes.src_acct_tickarray_tokendist_latest` for the relevant pool
- Token symbol present in `dexes.pool_tokens_reference`
- Recent price data in `kamino_lend.cagg_reserves_5s` for the collateral symbol
- Pool depth context columns (`pool_depth_used_pct`) derive from `MAX(token0_sold_cumul)` / `MAX(token1_sold_cumul)` depending on which side of the pool the collateral token sits on
- Deposit baseline for `liq_pct_of_deposits` is taken from the sensitivity curve at `pct_change = 0`

## File Locations

| File | Purpose |
|---|---|
| `pfx/dbsql/functions/kamino/compute_stressed_share.sql` | Per-obligation value fraction calculator |
| `pfx/dbsql/functions/kamino/sensitize_value_partial.sql` | Partial-shock value array generator |
| `pfx/dbsql/functions/kamino/compute_ltv_array.sql` | LTV array from deposit/borrow arrays |
| `pfx/dbsql/functions/kamino/resolve_dex_pool.sql` | Symbol to DEX pool resolver |
| `pfx/dbsql/functions/kamino/simulate_cascade_amplification.sql` | Cascade amplification simulation |
| `pfx/dbsql/frontend-views/kamino/get_view_klend_sensitivities.sql` | Main sensitivity function (modified) |

## Deployment

Currently deployed on the **Onyc database only** (`pfx/.env.pfx.core`). The Solstice database retains the original 6-parameter function. The new function is backward-compatible: existing callers that pass 6 arguments continue to work unchanged via the default NULL values for the new parameters.
