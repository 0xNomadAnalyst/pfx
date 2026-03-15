# Kamino 2nd-Order Analysis

This document describes the production implementation of asset-level stress testing, liquidation cascade simulation, protocol-mode liquidation mechanics, and validation/promotion gating.

## Asset-Level Sensitivity

`kamino_lend.get_view_klend_sensitivities` supports targeted stress on subsets of collateral and/or borrow symbols.

### Core idea

For each obligation, stress is applied only to the value fraction belonging to target symbols:

```text
value[i] = current_value * (1 + stressed_share * delta_bps * i / 10000)
```

`stressed_share` is computed with `kamino_lend.compute_stressed_share(...)` from per-asset arrays on `src_obligations_last`.

### Key inputs

- `p_coll_assets`: collateral symbols to stress (`NULL` or `ARRAY['All']` means all)
- `p_lend_assets`: borrow symbols to stress (`NULL` or `ARRAY['All']` means all)

### Notes

- `p_query_id` is deprecated and ignored in latest-snapshot mode.
- Output includes debt-side liquidation values and collateral-side equivalents:
  - `unhealthy_liq_value_coll_side`
  - `bad_liq_value_coll_side`
  - `total_liq_value_coll_side`

## Cascade Amplification

`kamino_lend.simulate_cascade_amplification` models DEX-induced feedback loops on top of the stress curve.

### Modes

- `p_model_mode = 'heuristic'`  
  Uses `get_view_klend_sensitivities` curve and aggregate bonus logic.
- `p_model_mode = 'protocol'`  
  Uses `simulate_protocol_liquidation` curve (precomputed once) with per-obligation liquidation mechanics.

### Bonus modes

- `p_bonus_mode = 'blended'` (default): weighted by bad-debt share
- `p_bonus_mode = 'max_conservative'`: max bonus for all
- `p_bonus_mode = 'none'`: no bonus

In protocol mode, the function consumes collateral-side liquidation directly from protocol outputs, avoiding recomputation of bonus in-loop.

### Pool routing

- `p_pool_mode = 'weighted'`: distributes sell flow across all resolved pools by counter-asset liquidity share
- `p_pool_mode = <pool_address>`: routes all flow to one pool

### Left and right sides

- Left side (collateral shock): fixed-point on collateral axis
- Right side (debt shock): cross-axis feedback using induced collateral decline and left-curve interpolation

### USD -> token conversion (current behavior)

- **Heuristic mode:** uses market share proxy `coll_tokens_deposited / total_deposits`
- **Protocol mode:** uses reserve oracle conversion `tokens_per_usd = 1 / market_price`

This removes the prior market-level token-share approximation in protocol mode and materially reduces model mismatch.

### Current function signature

```sql
kamino_lend.simulate_cascade_amplification(
    p_query_id BIGINT DEFAULT NULL,
    p_assets_delta_bps INTEGER DEFAULT -100,
    p_assets_delta_steps INTEGER DEFAULT 50,
    p_liabilities_delta_bps INTEGER DEFAULT 100,
    p_liabilities_delta_steps INTEGER DEFAULT 50,
    p_include_zero_borrows BOOLEAN DEFAULT FALSE,
    p_coll_assets TEXT[] DEFAULT NULL,
    p_lend_assets TEXT[] DEFAULT NULL,
    p_coll_symbol TEXT DEFAULT NULL,
    p_pool_mode TEXT DEFAULT 'weighted',
    p_bonus_mode TEXT DEFAULT 'blended',
    p_model_mode TEXT DEFAULT 'heuristic',
    p_max_rounds INTEGER DEFAULT 10,
    p_convergence_threshold_pct NUMERIC DEFAULT 0.1
)
```

## Protocol Liquidation Engine

`kamino_lend.simulate_protocol_liquidation` generates the stress curve for protocol mode.

### Implemented mechanics

- per-obligation unhealthy / bad-debt classification
- close-factor liquidation vs full-liquidation override (`min_full_liquidation_value_threshold`)
- collateral leg selection (lowest liquidation threshold first)
- debt leg selection (highest borrow leg first)
- reserve-level bonus interpolation for unhealthy obligations
- flat bad-debt bonus for bad debt branch
- collateral-side cap by available selected collateral
- optional filtering to target collateral symbol via `p_coll_symbol`

### Diagnostics exposed per shock

- `obligations_evaluated`
- `obligations_pruned`
- `obligations_unhealthy`
- `obligations_bad_debt`
- `obligations_full_liq_override`
- `full_liq_override_value`
- `full_liq_override_share`
- `bad_debt_share`

These diagnostics are intended for calibration and drift analysis.

## Validation and Promotion

### Validation scripts

- `preflight_phase3_contract.sql`: helper presence, array alignment, snapshot semantics, overlap checks
- `compare_heuristic_vs_protocol.sql`: mode diff metrics (MAE, per-shock paired outputs)
- `compare_model_vs_observed.sql`: model-vs-observed proxy check (when observed liquidation data exists)
- `diagnose_heuristic_protocol_delta.sql`: per-shock divergence decomposition and protocol composition diagnostics
- `gate_protocol_promotion.sql`: readiness decision + reasons

### Gate semantics (current)

`gate_protocol_promotion.sql` now separates blockers from warnings:

- `failure_reasons`: hard failures (invariants, monotonicity, convergence, missing function, observed accuracy threshold when applicable)
- `validation_warnings`: non-blocking warnings

If there is no observed liquidation data in window, gate returns:

- `protocol_default_ready = true` (assuming hard checks pass)
- `validation_warnings = {no_observed_liquidation_data_in_window}`

When observed data becomes available, observed MAPE threshold is applied automatically with no code changes.

## Usage examples

```sql
-- Asset-level sensitivity
SELECT * FROM kamino_lend.get_view_klend_sensitivities(
    NULL, -100, 50, 100, 50, FALSE,
    ARRAY['ONyc'], NULL
);

-- Cascade (heuristic mode)
SELECT * FROM kamino_lend.simulate_cascade_amplification(
    NULL, -100, 50, 100, 50, FALSE,
    ARRAY['ONyc'], NULL,
    'ONyc', 'weighted', 'blended', 'heuristic', 10, 0.1
);

-- Cascade (protocol mode)
SELECT * FROM kamino_lend.simulate_cascade_amplification(
    NULL, -100, 50, 100, 50, FALSE,
    ARRAY['ONyc'], NULL,
    'ONyc', 'weighted', 'blended', 'protocol', 10, 0.1
);

-- Promotion gate
SELECT * FROM (
    -- run file: pfx/dbsql/validation/kamino/gate_protocol_promotion.sql
) x;
```

## File map

| File | Purpose |
| --- | --- |
| `pfx/dbsql/frontend-views/kamino/get_view_klend_sensitivities.sql` | Asset-level sensitivity curve |
| `pfx/dbsql/functions/kamino/simulate_protocol_liquidation.sql` | Protocol liquidation curve engine |
| `pfx/dbsql/frontend-views/kamino/simulate_cascade_amplification.sql` | Cascade simulation using heuristic or protocol curve |
| `pfx/dbsql/functions/kamino/compute_stressed_share.sql` | Per-obligation stressed-share helper |
| `pfx/dbsql/functions/kamino/sensitize_value_partial.sql` | Partial shock helper |
| `pfx/dbsql/functions/kamino/compute_ltv_array.sql` | LTV helper |
| `pfx/dbsql/functions/kamino/resolve_dex_pool.sql` | Pool resolution helper |
| `pfx/dbsql/validation/kamino/preflight_phase3_contract.sql` | Preflight checks |
| `pfx/dbsql/validation/kamino/compare_heuristic_vs_protocol.sql` | Mode comparison |
| `pfx/dbsql/validation/kamino/compare_model_vs_observed.sql` | Observed comparison (if data exists) |
| `pfx/dbsql/validation/kamino/diagnose_heuristic_protocol_delta.sql` | Shock-level divergence diagnostics |
| `pfx/dbsql/validation/kamino/gate_protocol_promotion.sql` | Promotion gate |

## Deployment status

Deployed and validated on the ONyc environment (`pfx/.env.pfx.core`).
