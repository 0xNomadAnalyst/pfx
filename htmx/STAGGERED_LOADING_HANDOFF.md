# Staggered Loading Investigation Handoff

## Problem Statement

Widgets sharing the same underlying dataset were not consistently visible at the same time. Typical symptoms:

- one widget rendered while sibling remained `loading...`
- one sibling showed data while another showed `error: cannot reach API`
- wide pages had family-level skew under refresh pressure

Goal: keep shared-family widgets visually and lifecycle-consistent while preserving existing API contracts and page schemas.

---

## What Is Implemented (Current State)

This section reflects the latest implemented sequence (phases 1-5) and supersedes earlier notes.

1. Shared-family metadata propagated backend -> template -> frontend runtime.
2. Delay precedence clarified: family alignment has explicit precedence over lane alignment.
3. Shared-family reveal buffering hardened (deduped terminal flush + stale DOM guard).
4. Shared-family stale-cache hydration gating enforced (all-or-none per family).
5. Sync test harness improved (visibility prep + failure tags).
6. Startup/CI drift checks added for intentional shared-family mapping.
7. Feature-flagged unified reveal coordinator added with legacy fallback path.

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

- warns when active widget endpoints have no explicit family intent
- optional strict failure via env:
  - `HTMX_SHARED_FAMILY_STRICT_INTENT=1`

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
- Lints for changed files reported no new issues.

## Sync parity checks across profiles (dex swaps family)

Test target: `dexes` + `dex_swaps_timeseries`

Profiles tested:

- conservative
- balanced
- aggressive
- aggressive + `HTMX_UNIFIED_REVEAL_COORDINATOR_ENABLED=1`

Observed outcome:

- same failure pattern/tags across all four runs
- failures classified as backend-side availability/timeout
- indicates no additional regression from unified coordinator flag path under current backend conditions

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
- `htmx/scripts/refresh_widget_call_mappings.py`
- `htmx/config/widget_call_mappings.json`
- `htmx/scripts/test_widget_sync_groups.py`

