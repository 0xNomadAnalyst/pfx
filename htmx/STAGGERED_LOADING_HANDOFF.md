# Staggered Loading Investigation Handoff

## Problem Statement

Widgets sharing the same underlying dataset were not consistently visible at the same time. Typical symptoms:

- one widget rendered while sibling remained `loading...`
- one sibling showed data while another showed `error: cannot reach API`
- wide pages had family-level skew under refresh pressure

Goal: keep shared-family widgets visually and lifecycle-consistent while preserving existing API contracts and page schemas.

---

## What Is Implemented (Current State)

This section reflects the latest implemented sequence (phases 0-9) and supersedes earlier notes.

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
12. Critical reveal correctness fixes landed: terminal settle on application-level error paths, two-pass family delay backfill, and legacy batch flush parity with coordinator render path.
13. Batch-vs-family split risk was reduced by excluding shared-family widgets from viewport batch targets.
14. Real SoC extraction expanded beyond reveal: live runtime logic has been split into domain engines consumed by `charts.js` orchestration wrappers.
15. Bundle end-state introduced with rollback-safe template loading: bundle-first (`charts.bundle.js`) with auto-fallback to legacy multi-script loading if bundle load/boot fails.

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
Shared-family delay assignment now uses a second-pass backfill so all family members receive the final family minimum delay (removing order dependence from the first pass).

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

## 3b) Template script loading (current)

**Files:** `htmx/app/templates/base.html`, `htmx/app/templates/export.html`

- templates now load bundle-first:
  - `/static/js/charts.bundle.js?v=1`
- rollback-safe fallback is in place:
  - on bundle load error, or if runtime marker is missing after timeout, templates dynamically load legacy scripts (`core/state/cache/render/concurrency/filters/soft-nav/warmup/reveal + charts.js`)
- this keeps rollback path available while enabling the optimized bundled runtime by default.

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

### F) Post-review corrective pass (phase 8)

Follow-up fixes based on implementation review:

- terminal-settle coverage fixed on application-level error paths in `htmx:afterRequest`:
  - empty payload (`!raw`)
  - non-success API payload (`payload.status !== "success"`)
  - JSON/processing `catch` path
- legacy batch flush now uses `_renderWidgetResponse(...)` with `isConnected` guard for parity with coordinator semantics
- family in-flight helper now excludes `sourceEl` consistently:
  - `_flushFamilyWhenSettled(...).some((el) => el !== sourceEl && el.classList.contains("htmx-request"))`
- viewport batch targets now exclude shared-family widgets so family members follow one reveal mechanism

### G) Correctness hardening pass (phase 8)

Addressed three defects in default-path behavior:

- application-level error terminal settle:
  - `htmx:afterRequest` now calls `_onTerminalRevealSettle(sourceEl, widgetId)` on
    - empty response payload
    - `payload.status !== "success"`
    - JSON parse/processing `catch` path
- legacy batch flush parity:
  - `_flushBatchedReveal` now calls `_renderWidgetResponse(...)` (with `isConnected` guard) instead of direct `renderPayload(...)`
- family delay backfill support in server context:
  - widget bindings now include `source_page_id`
  - final family minimum delay is backfilled across all family members after binding construction

### H) SoC extraction status (real)

Live runtime logic is now extracted into:

- `htmx/app/static/js/reveal-engine.js`
- `htmx/app/static/js/core-engine.js`
- `htmx/app/static/js/state-engine.js`
- `htmx/app/static/js/cache-engine.js`
- `htmx/app/static/js/render-engine.js`
- `htmx/app/static/js/concurrency-engine.js`
- `htmx/app/static/js/filters-engine.js`
- `htmx/app/static/js/soft-nav-engine.js`
- `htmx/app/static/js/warmup-engine.js`

Scope moved out of `charts.js` includes:

- reveal buffering/coordinator/settle state machine
- runtime readers + shared-family widget index caching helpers
- protocol-pair shared state holder
- family-aware cache-hydration gate + cache-availability checks
- guarded widget response render pipeline
- concurrency queue orchestration + in-flight accounting hooks
- persisted/global-filter read/write/apply flow
- soft-nav helper path normalization + UI path discovery/highlight sync
- warmup and rewarmup scheduler orchestration

`charts.js` remains the composition/orchestration layer with thin delegations into domain engines.

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

- JavaScript syntax checks passed for `charts.js` and extracted engine modules (`node --check`).
- Bundle build passes via `npm run build:charts` (esbuild).
- Lints for changed files reported no new issues.

## Size metrics (post-extraction)

- `charts.js` bytes: `339,001`
- `charts.js` lines: `8,464`
- `charts.js` gzip bytes: `72,332`
- `charts.bundle.js` bytes: `175,022`
- `charts.bundle.js` gzip bytes: `53,253`

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

## Post-phase-9 targeted verification (latest)

After phase-9 extraction/bundle wiring, targeted runs were repeated against updated local server code (`:8007`):

- target: `dexes:dex_swaps_timeseries`
- mode: default
- result: failed with `backend_unavailable_or_timeout` tags (widgets did not start request in cycle)

- target: `risk-analysis:risk_liq_curves_orca:default`
- mode: default
- result: failed with `frontend_sync_split` tag (stuck loading + missing request starts in cycle)

Interpretation:

- extraction/bundle changes did not eliminate pre-existing parity instability in these sample runs
- coordinator remains **default-off** pending broader parity stability

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

1. **Mapping intent completion**
   - either populate missing entries in `SHARED_DATA_FAMILY_HINTS`
   - or explicitly place intentional exclusions into `EXPLICIT_NO_SHARED_FAMILY_HINTS`

1. **Coordinator rollout strategy**
   - run additional parity checks on risk/system-health families
   - if stable, consider enabling unified coordinator by profile

1. **Bundle rollout follow-through**
   - keep bundle-first + legacy fallback for one stabilization window
   - remove fallback block after parity and backend stability gates pass

1. **Optional UX policy**
   - family-level unified error surface when any sibling fails

---

## Quick File List

- `htmx/app/shared_families.py`
- `htmx/app/main.py`
- `htmx/app/templates/partials/dashboard.html`
- `htmx/app/templates/base.html`
- `htmx/app/templates/export.html`
- `htmx/app/static/js/core-engine.js`
- `htmx/app/static/js/state-engine.js`
- `htmx/app/static/js/cache-engine.js`
- `htmx/app/static/js/render-engine.js`
- `htmx/app/static/js/concurrency-engine.js`
- `htmx/app/static/js/filters-engine.js`
- `htmx/app/static/js/soft-nav-engine.js`
- `htmx/app/static/js/warmup-engine.js`
- `htmx/app/static/js/reveal-engine.js`
- `htmx/app/static/js/charts.js`
- `htmx/app/static/js/charts.bundle.js`
- `htmx/app/static/js/src/charts-bundle-entry.mjs`
- `htmx/scripts/build-charts.mjs`
- `htmx/package.json`
- `htmx/package-lock.json`
- `htmx/scripts/refresh_widget_call_mappings.py`
- `htmx/config/widget_call_mappings.json`
- `htmx/scripts/test_widget_sync_groups.py`
