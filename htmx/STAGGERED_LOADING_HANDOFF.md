# Staggered Loading Investigation Handoff

## Problem Statement

Widgets sharing the same underlying dataset were not consistently visible at the same time. Typical symptoms:

- one widget rendered while sibling remained `loading...`
- one sibling showed data while another showed `error: cannot reach API`
- wide pages had family-level skew under refresh pressure

Goal: keep shared-family widgets visually and lifecycle-consistent while preserving existing API contracts and page schemas.

---

## What Is Implemented (Current State)

This section reflects the latest implemented sequence (phases 0-7) and supersedes earlier notes.

1. Shared-family metadata propagated backend -> template -> frontend runtime.
2. Delay precedence clarified: family alignment has explicit precedence over lane alignment.
3. Shared-family reveal buffering hardened (deduped terminal flush + stale DOM guard).
4. Shared-family stale-cache hydration gating enforced (all-or-none per family).
5. Sync test harness improved (visibility prep + failure tags).
6. Startup/CI drift checks added for intentional shared-family mapping.
7. Feature-flagged unified reveal coordinator added with legacy fallback path.
8. Reveal control-flow refactored to a shared active-strategy path with reduced duplicate branching.
9. Shared-family lookup now uses a per-refresh family index cache to avoid repeated full DOM scans.
10. Startup mapping-intent warnings are now opt-in unless strict mode is enabled.
11. Safety-first fault fixes landed: startup validation always runs, coordinator batch flush is rAF-aligned, and active reveal clear resets legacy batch state.
12. SoC scaffolding landed with concern-scoped runtime modules and explicit contracts.
13. Build-backed JS bundling is in place (`esbuild`) and templates now load `charts.bundle.js`.

---

## File-Level Changes

## 1) Shared-family registry and intent contract

**File:** `htmx/app/shared_families.py`

- Existing family map remains authoritative:
  - `SHARED_DATA_FAMILY_HINTS`
- Added explicit no-family intent list:
  - `EXPLICIT_NO_SHARED_FAMILY_HINTS`
- Added helper used by validation paths:
  - `has_intentional_shared_family_mapping(api_page_id, source_widget_id)`

Purpose: distinguish “intentionally no family” from accidental omission.

---

## 2) Server context and delay policy

**File:** `htmx/app/main.py`

### A) Shared-family metadata in widget bindings

`_build_page_context(...)` resolves:

- `shared_data_family = resolve_shared_data_family(endpoint_page, endpoint_wid)`

and emits to `widget_bindings`, consumed by the template.

### B) Precedence made explicit

Lane alignment now applies only when there is **no** shared family for a widget.
Family alignment is explicitly documented as higher priority.

### C) Startup drift validation

Added startup validation:

- can warn when active widget endpoints have no explicit family intent
- warning is opt-in via:
  - `HTMX_SHARED_FAMILY_WARN_INTENT=1`
- optional strict failure via env:
  - `HTMX_SHARED_FAMILY_STRICT_INTENT=1`
- validation now runs on startup regardless of `DEFAULT_PIPELINE` value

### D) Unified reveal feature flag wiring

Added cache/runtime config key:

- `unified_reveal_coordinator_enabled`
- env override:
  - `HTMX_UNIFIED_REVEAL_COORDINATOR_ENABLED`

Default remains `False` in all cache profiles (legacy behavior by default).

---

## 3) Template HTMX behavior

**File:** `htmx/app/templates/partials/dashboard.html`

- widget loaders include:
  - `data-shared-data-family="{{ widget.shared_data_family }}"`
- sync mode uses queue semantics:
  - `hx-sync="this:queue last"`

---

## 3b) Template script loading (bundle transition)

**Files:** `htmx/app/templates/base.html`, `htmx/app/templates/export.html`

- script source migrated from:
  - `/static/js/charts.js?...`
- to:
  - `/static/js/charts.bundle.js?...`

Purpose: support phased SoC extraction through a build-backed entrypoint while preserving existing page behavior.

---

## 4) Frontend reveal/cache coordination

**File:** `htmx/app/static/js/charts.js`

### A) Hardened legacy shared-family buffering

- Added stale DOM guard in flush path:
  - skip buffered render if `sourceEl` no longer connected
- Deduped terminal flush checks through helper:
  - `_maybeFlushFamilyOnTerminal(sourceEl)`

### B) Family all-or-none stale-cache hydrate

`hydrateWidgetsFromCache()` blocks partial family restoration:

- if not all members have valid cache, family hydrate is skipped
- avoids stale-first split state within a family

### C) Feature-flagged unified reveal coordinator (phase 5)

Added coordinator path behind:

- `UNIFIED_REVEAL_COORDINATOR_ENABLED`

Coordinator responsibilities:

- optional batch coordination (when batched reveal is enabled)
- family-group buffering/flush under a unified flow
- terminal event settlement handling with grouped flush

Legacy shared-family + batched reveal paths remain intact and are still default.

### D) Active reveal strategy refactor (phase 6)

Refactor goals were to reduce duplicated control-flow without changing default behavior.

Implemented:

- terminal settle handling unified behind:
  - `_onTerminalRevealSettle(sourceEl, widgetId)`
- active batch handling unified behind:
  - `_beginActiveBatch(els)`
  - `_bufferActiveBatch(widgetId, payload, srcId, sourceEl)`
- active family buffering/flush unified behind:
  - `_bufferActiveFamily(...)`
  - `_flushActiveFamily(familyId)`
- active reveal state reset unified behind:
  - `_clearActiveRevealState()`

Additional hardening/simplification in this pass:

- batch settle condition simplified (flush when target set drains; removed early flush on buffer-size comparison)
- repeated `sharedFamilyWidgetElements(...)` scans replaced by cached family index:
  - `_sharedFamilyWidgetIndex`
  - invalidated on refresh/pipeline switch/soft-nav teardown

### E) Safety-first hardening pass (phase 7)

This pass addressed concrete faults while keeping rollout feature-flagged.

- coordinator batch flush scheduling now mirrors legacy visual atomicity:
  - coordinator batch flush uses `requestAnimationFrame(...)` before rendering buffered entries
- active reveal state clear now resets legacy batch state on legacy path:
  - `_batchedRevealBuffer`, `_batchedRevealTargets`, `_batchedRevealTimer`
- terminal family in-flight check deduped through shared helper:
  - `_flushFamilyWhenSettled(sourceEl, flushFamily)`
  - reused by both legacy and coordinator terminal settle paths

### F) Concern-scoped module contracts (phase 2/5 bridge)

`charts.js` now publishes explicit runtime contracts for concern-scoped modules:

- `window.__riskdashModuleFactories` (module registration)
- `window.__riskdashModules` (initialized module API surface)
- `window.__riskdashModuleContext` (shared state/constants/utils/apis)

This keeps behavior stable while enabling concern-oriented edits/reviews in separate files.

---

## 4b) Concern-scoped module files (SoC extraction path)

**Directory:** `htmx/app/static/js/modules/`

Added runtime module boundaries for:

- `core.js`
- `state.js`
- `reveal.js`
- `cache.js`
- `render.js`
- `soft-nav.js`
- `warmup.js`
- `filters.js`
- `concurrency.js`

These modules are initialized through contracts published by `charts.js`.

---

## 4c) Build-backed modularization

**Files:** `htmx/package.json`, `htmx/scripts/build-charts.mjs`, `htmx/app/static/js/src/charts-entry.js`

- build tool introduced: `esbuild`
- bundle entry imports concern modules plus existing runtime:
  - `app/static/js/src/charts-entry.js`
- output bundle:
  - `app/static/js/charts.bundle.js`
- build command:
  - `npm run build:charts` (from `htmx/`)

---

## 5) Tooling and test harness updates

## A) Mapping generator / CI-style verification

**File:** `htmx/scripts/refresh_widget_call_mappings.py`

New readonly mode:

- `--verify-intentional-families`

Behavior:

- exits non-zero if any active widget endpoint lacks explicit family intent
- prints sample missing entries

Normal mapping generation behavior is unchanged.

## B) Family sync test robustness

**File:** `htmx/scripts/test_widget_sync_groups.py`

Improvements:

- stronger pre-cycle viewport prep (`scrollIntoView` attempts + visibility capture)
- failure tagging added:
  - `backend_unavailable_or_timeout`
  - `frontend_sync_split`
  - `unclassified` fallback
- result payload now includes `visible_before_refresh` and `failure_tags`

---

## Validation Snapshot (Latest Implementation Pass)

## Code quality

- Python syntax checks passed for updated Python files.
- JavaScript syntax check passed for `charts.js` (`node --check`).
- JavaScript syntax checks passed for new module files.
- Lints for changed files reported no new issues.

## Baseline size metrics (Phase 0)

- `charts.js` bytes: `353,806`
- `charts.js` lines: `8,866`
- `charts.js` gzip bytes: `74,756`
- generated `charts.bundle.js` size (non-minified): ~`352.7kb`

## Sync parity checks across flag modes (dex swaps family)

Test target: `dexes` + `dex_swaps_timeseries`

Modes tested:

- default mode (`HTMX_UNIFIED_REVEAL_COORDINATOR_ENABLED=0`) on `:8002`
- flagged mode (`HTMX_UNIFIED_REVEAL_COORDINATOR_ENABLED=1`) on temporary `:8003`

Observed outcome:

- same failure pattern/tags across both flag modes
- failures classified as backend-side availability/timeout
- indicates no additional frontend sync regression from coordinator flag path under current backend conditions

## Additional targeted parity check (risk family)

Test target: `risk-analysis` + `risk_liq_curves_orca` (`risk-analysis:risk_liq_curves_orca:default`)

Modes tested:

- default mode (`HTMX_UNIFIED_REVEAL_COORDINATOR_ENABLED=0`) on `:8002`
- flagged mode (`HTMX_UNIFIED_REVEAL_COORDINATOR_ENABLED=1`) on temporary `:8003`

Observed outcome:

- both runs failed with `frontend_sync_split` classification
- default mode failure: timed out with missing cycle starts for `ra-liq-depth-orca` and `ra-prob-orca`
- flagged mode failure: no missing starts, but completion skew (`~6181ms`) and loading-stuck signals across family widgets

Interpretation:

- this targeted run does **not** support enabling coordinator mode by default yet
- keep coordinator rollout feature-flagged and investigate risk-family settle/render timing before promotion

## Post-bundle parity snapshot (default vs flagged)

Tested via temporary servers loading `charts.bundle.js`:

- default mode (`:8004`)
- flagged mode (`:8003`, `HTMX_UNIFIED_REVEAL_COORDINATOR_ENABLED=1`)

Targets and outcomes:

- `dexes` + `dex_swaps_timeseries`
  - both modes: `backend_unavailable_or_timeout` (same as prior baseline)
- `risk-analysis` + `risk_liq_curves_orca`
  - default mode: `frontend_sync_split` (skew/loading-stuck)
  - flagged mode: `backend_unavailable_or_timeout` in this run

Readiness decision:

- coordinator remains **default-off**
- further parity rounds required before any default-on promotion

---

## Known Remaining Issue

`dex-swaps` family still intermittently fails due to endpoint instability, especially:

- `/api/v1/dex-swaps/swaps-flows-toggle`

This is currently diagnosed as a backend availability/latency concern rather than purely frontend reveal-ordering logic.

---

## Backed-Out Attempt

A stricter bootstrap request suppression approach was previously tested and removed because it over-constrained initial load. Current direction favors:

- family-based cache gating
- family-aware reveal buffering/coordinator
- clearer diagnostics in sync tests

---

## Recommended Next Review Focus

1. **Backend stabilization for swaps flows endpoint**
   - query timing instrumentation and timeout path analysis
   - DB contention / pool behavior under concurrent page loads

2. **Mapping intent completion**
   - either populate missing entries in `SHARED_DATA_FAMILY_HINTS`
   - or explicitly place intentional exclusions into `EXPLICIT_NO_SHARED_FAMILY_HINTS`

3. **Coordinator rollout strategy**
   - run additional parity checks on risk/system-health families
   - if stable, consider enabling unified coordinator by profile

4. **Optional UX policy**
   - family-level unified error surface when any sibling fails

---

## Quick File List

- `htmx/app/shared_families.py`
- `htmx/app/main.py`
- `htmx/app/templates/partials/dashboard.html`
- `htmx/app/static/js/charts.js`
- `htmx/app/static/js/charts.bundle.js`
- `htmx/app/static/js/src/charts-entry.js`
- `htmx/app/static/js/modules/`
- `htmx/scripts/refresh_widget_call_mappings.py`
- `htmx/config/widget_call_mappings.json`
- `htmx/scripts/test_widget_sync_groups.py`
- `htmx/package.json`
- `htmx/scripts/build-charts.mjs`
