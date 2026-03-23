from __future__ import annotations

import os
from datetime import datetime, timezone
from typing import Any

from app.services.pages.base import BasePageService

_TABLE_TTL = float(os.getenv("HEALTH_TABLE_TTL_SECONDS", "60"))
_TABLE_TTL_RED = float(os.getenv("HEALTH_TABLE_TTL_RED_SECONDS", "15"))
_CHART_TTL = float(os.getenv("HEALTH_CHART_TTL_SECONDS", "120"))
_CHART_TTL_RED = float(os.getenv("HEALTH_CHART_TTL_RED_SECONDS", "30"))
_CHART_TIMEOUT_MS = 30_000
_TABLE_TIMEOUT_MS = int(os.getenv("HEALTH_TABLE_TIMEOUT_MS", "20000"))
_MASTER_TIMEOUT_MS = int(os.getenv("HEALTH_MASTER_TIMEOUT_MS", "60000"))
_HEALTH_STATUS_TIMEOUT_MS = int(os.getenv("HEALTH_STATUS_TIMEOUT_MS", "2000"))
_PIPELINE_LOCKED = os.getenv("API_PIPELINE_LOCKED", "0") == "1"

QUEUE_COLORS = [
    "#4bb7ff", "#f8a94a", "#28c987", "#06b6d4", "#ae82ff",
    "#facc15", "#ec4899", "#e8853d", "#84cc16", "#f472b6", "#2dd4bf",
]

WINDOW_MAP: dict[str, tuple[str, str]] = {
    "1h":  ("1 hour",   "2 minutes"),
    "4h":  ("4 hours",  "5 minutes"),
    "6h":  ("6 hours",  "5 minutes"),
    "24h": ("24 hours", "30 minutes"),
    "7d":  ("7 days",   "3 hours"),
    "30d": ("30 days",  "12 hours"),
    "90d": ("90 days",  "1 day"),
}

VALID_SCHEMAS = {"dexes", "exponent", "kamino_lend", "solstice_proprietary", "cross_protocol"}
VALID_ATTRIBUTES = {"Queue Size", "Write Rate", "Gap Size", "Failures"}


# ---------------------------------------------------------------------------
# Formatting helpers (mirror React healthFormatters.ts)
# ---------------------------------------------------------------------------

_EMOJI_GREEN  = "\U0001f7e2"
_EMOJI_YELLOW = "\U0001f7e1"
_EMOJI_ORANGE = "\U0001f7e0"
_EMOJI_RED    = "\U0001f534"
_EMOJI_WHITE  = "\u26aa"

_STATUS_EMOJI_MAP: dict[str, str] = {
    # CAGG Refresh Health
    "refresh ok":           _EMOJI_GREEN,
    "refresh delayed":      _EMOJI_YELLOW,
    "source stale":         _EMOJI_ORANGE,
    "refresh broken":       _EMOJI_RED,
    # Base Table Activity
    "active":               _EMOJI_GREEN,
    "quiet":                _EMOJI_GREEN,
    "check":                _EMOJI_YELLOW,
    "stale":                _EMOJI_ORANGE,
    # Queue Health
    "normal":               _EMOJI_GREEN,
    "elevated":             _EMOJI_YELLOW,
    "high":                 _EMOJI_ORANGE,
    "anomaly":              _EMOJI_RED,
    # Trigger Function Health
    "healthy":              _EMOJI_GREEN,
    "lagging":              _EMOJI_YELLOW,
    "low coverage":         _EMOJI_ORANGE,
    "trigger not firing":   _EMOJI_RED,
    "not firing":           _EMOJI_RED,
    "no source data":       _EMOJI_WHITE,
    "no source":            _EMOJI_WHITE,
    # Shared
    "no data":              _EMOJI_WHITE,
}


def _status_emoji(status: str) -> str:
    s = (status or "").lower().strip()
    hit = _STATUS_EMOJI_MAP.get(s)
    if hit:
        return hit
    # Fallback: severity-descending substring scan so that e.g. an
    # unknown red-level keyword is never eclipsed by a green one
    # ("broken" contains "ok", so green must be tested last).
    if any(k in s for k in ("anomaly", "broken", "not firing", "red")):
        return _EMOJI_RED
    if any(k in s for k in ("high", "stale", "low coverage")):
        return _EMOJI_ORANGE
    if any(k in s for k in ("elevated", "delayed", "lagging", "check")):
        return _EMOJI_YELLOW
    if any(k in s for k in ("normal", "active", "healthy", "ok", "green")):
        return _EMOJI_GREEN
    return _EMOJI_WHITE


def _bool_indicator(val: Any) -> str:
    return "\U0001f534" if _as_bool(val) else "\U0001f7e2"


def _as_bool(val: Any) -> bool:
    """Coerce DB values like 't'/'f', 1/0, and bool into a stable boolean."""
    if isinstance(val, bool):
        return val
    if val is None:
        return False
    if isinstance(val, (int, float)):
        return bool(val)
    if isinstance(val, str):
        s = val.strip().lower()
        if s in {"true", "t", "1", "yes", "y", "on"}:
            return True
        if s in {"false", "f", "0", "no", "n", "off", ""}:
            return False
    return bool(val)


def _fmt_duration(seconds: Any) -> str:
    if seconds is None:
        return "-"
    s = float(seconds)
    if s < 60:
        return f"{round(s)}s"
    if s < 3600:
        return f"{s / 60:.1f}m"
    if s < 86400:
        return f"{s / 3600:.1f}h"
    return f"{s / 86400:.1f}d"


def _fmt_ts(ts: Any) -> str:
    if not ts:
        return "-"
    try:
        if isinstance(ts, datetime):
            return ts.strftime("%H:%M:%S")
        d = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
        return d.strftime("%H:%M:%S")
    except (ValueError, TypeError):
        return str(ts)


def _fmt_float(val: Any, dp: int = 1) -> str:
    if val is None:
        return "-"
    return f"{float(val):.{dp}f}"


def _fmt_int(val: Any) -> str:
    if val is None:
        return "-"
    return f"{int(round(float(val))):,}"


def _rolling_avg(data: list[float | None], window: int) -> list[float | None]:
    result: list[float | None] = []
    for i in range(len(data)):
        start = max(0, i - window + 1)
        vals = [v for v in data[start:i + 1] if v is not None]
        result.append(sum(vals) / len(vals) if vals else None)
    return result


def _rolling_window(last_window: str) -> int:
    """Approximate 24-hour rolling window in bucket count."""
    _, interval_str = WINDOW_MAP.get(last_window, ("7 days", "3 hours"))
    parts = interval_str.split()
    num = int(parts[0])
    unit = parts[1]
    if "min" in unit:
        interval_min = num
    elif "hour" in unit:
        interval_min = num * 60
    elif "day" in unit:
        interval_min = num * 1440
    else:
        interval_min = num
    return max(1, round(24 * 60 / interval_min))


# ---------------------------------------------------------------------------
# Info-toggle content (replicates React HealthInfoToggle children)
# ---------------------------------------------------------------------------

INFO_MASTER = (
    "<p><strong>Master Status</strong> is binary: \U0001f7e2 all clear or \U0001f534 action required. "
    "Only genuinely critical conditions trigger red &mdash; designed to avoid alert fatigue.</p>"
    "<p><strong>What red alerts mean:</strong></p>"
    "<ul>"
    "<li><strong>Queues</strong> &mdash; likely a service or ingestion issue (a queue writer may have stopped or fallen behind)</li>"
    "<li><strong>Triggers / CAGG Refresh</strong> &mdash; likely a database issue (a trigger function or refresh cronjob may have stopped)</li>"
    "<li><strong>Base Tables</strong> &mdash; likely an ingestion anomaly or a write bottleneck (e.g. a slow trigger)</li>"
    "</ul>"
)

INFO_QUEUE = (
    "<p>Real-time status of database write queues across all protocol domains. "
    "Each queue represents an independent worker with its own database connection.</p>"
    "<p><strong>Status Indicators</strong> (Gap dimension &mdash; ratio of current staleness to capped P95 baseline):</p>"
    "<ul>"
    "<li>\U0001f7e2 <strong>NORMAL</strong>: \u2264 1.25\u00d7 capped P95 baseline (or queue idle with no failures)</li>"
    "<li>\U0001f7e1 <strong>ELEVATED</strong>: 1.25\u20133\u00d7</li>"
    "<li>\U0001f7e0 <strong>HIGH</strong>: 3\u201310\u00d7</li>"
    "<li>\U0001f534 <strong>ANOMALY</strong>: &gt; 10\u00d7, or absolute wall-clock floor exceeded, or queue has stopped reporting</li>"
    "</ul>"
    "<p>The P95 baseline is capped per queue type: 1 hour for state/write-on-difference queues; "
    "24 hours for event and transaction queues. This prevents a slow-recovery incident from permanently "
    "raising the baseline and masking future problems.</p>"
    "<p><strong>Summary</strong> (leftmost column) reflects the worst status across Gap, Util, and Failure dimensions. "
    "Write-on-difference queues with an empty queue and zero failures bypass the staleness check &mdash; "
    "long gaps without writes are normal when the underlying data hasn&rsquo;t changed.</p>"
)

INFO_TRIGGER = (
    "<p>Monitors whether trigger functions (e.g., swap impact calculation, price filling) "
    "are firing correctly. Checks for gaps between base table inserts and derived table updates.</p>"
    "<p><strong>Status Indicators:</strong></p>"
    "<ul>"
    "<li>\U0001f7e2 <strong>Healthy</strong>: Trigger is firing and derived table is up to date</li>"
    "<li>\U0001f7e1 <strong>Lagging</strong>: Derived table is &gt;10 minutes behind source</li>"
    "<li>\U0001f7e0 <strong>Low coverage</strong>: Derived table has &lt;50% of source rows in the last hour</li>"
    "<li>\U0001f534 <strong>Trigger not firing</strong>: Source has recent data but derived table has none &mdash; "
    "this is the only status that triggers a master red alert</li>"
    "<li>\u26aa <strong>No source data</strong>: Base table itself has no recent data (not a trigger issue)</li>"
    "</ul>"
)

INFO_BASE_TABLE = (
    "<p>Monitors ingestion activity by checking row counts and latest timestamps in base tables. "
    "Compares recent activity against historical benchmarks.</p>"
    "<p><strong>Status Logic:</strong> Uses 7-day write frequency (hours with any data / 168 total hours) "
    "to derive an <em>expected gap</em> between writes. This naturally handles write-on-difference tables "
    "&mdash; if a table only writes a few times per week, gaps of hours or days are treated as normal. "
    "For tables with no established history yet, a time-based fallback applies: "
    "&le;12 h = Active, 12\u201324 h = Check, 24\u201372 h = Stale, &gt;72 h = ANOMALY.</p>"
    "<p><strong>Immediate escalation:</strong> Tables normally receiving \u226510 rows/hour that drop to "
    "zero rows in the last hour are flagged <strong>ANOMALY</strong> immediately (ingestion death detection).</p>"
    "<p><strong>Two indicators per row, plus a Summary:</strong></p>"
    "<ul>"
    "<li><strong>Activity</strong> \u2014 row count + gap logic:</li>"
    "<ul>"
    "<li>\U0001f7e2 <strong>Active</strong>: \u2264 2\u00d7 expected gap (normal)</li>"
    "<li>\U0001f7e1 <strong>Check</strong>: 2\u20133\u00d7 expected gap (worth monitoring)</li>"
    "<li>\U0001f7e0 <strong>Stale</strong>: 3\u20135\u00d7 expected gap (significant deviation)</li>"
    "<li>\U0001f534 <strong>ANOMALY</strong>: &gt; 5\u00d7 expected gap or zero rows on active table</li>"
    "</ul>"
    "<li><strong>Insert</strong> \u2014 mean INSERT time from pg_stat_statements (last ~30s window):</li>"
    "<ul>"
    "<li>\U0001f7e2 <strong>NORMAL</strong>: &lt; 50 ms (no bottleneck)</li>"
    "<li>\U0001f7e1 <strong>ELEVATED</strong>: 50\u2013500 ms (watch for trend)</li>"
    "<li>\U0001f7e0 <strong>HIGH</strong>: 500 ms\u20135 s (queue will back up)</li>"
    "<li>\U0001f534 <strong>ANOMALY</strong>: \u2265 5 s (trigger S3-scan territory)</li>"
    "<li>\u26aa <strong>\u2014</strong>: no recent insert activity recorded in this window</li>"
    "</ul>"
    "</ul>"
    "<p><strong>Summary</strong> = worst of Activity and Insert. Drives the master health check. "
    "A missing Insert reading (\u2014) never degrades the Summary.</p>"
)

INFO_CAGG = (
    "<p>Tests whether the CAGG refresh cronjob is running correctly by comparing CAGG bucket times "
    "to base table times. The cronjob runs every 5 seconds and refreshes all 21 CAGGs with a 2-hour lookback window.</p>"
    "<p><strong>Status Indicators:</strong></p>"
    "<ul>"
    "<li>\U0001f7e2 <strong>Refresh OK</strong>: CAGG is within 5 minutes of source data &mdash; cronjob working correctly</li>"
    "<li>\U0001f7e2 <strong>Dormant (expected)</strong>: Both CAGG and source have no data in &gt;24 h, but CAGG is within its "
    "expected lag threshold &mdash; system is dormant, not broken</li>"
    "<li>\U0001f7e1 <strong>Refresh Delayed</strong>: 5\u201315 minute lag &mdash; minor delay, monitor</li>"
    "<li>\U0001f7e0 <strong>Source Stale</strong>: Base table exceeds 2\u00d7 its expected write gap &mdash; "
    "NOT a cronjob issue, ingestion may be down</li>"
    "<li>\U0001f534 <strong>Source Stale</strong> (&gt;5\u00d7 expected gap): ingestion is likely dead</li>"
    "<li>\U0001f534 <strong>Refresh Broken</strong>: CAGG &gt;15 minutes behind an active source &mdash; cronjob may have stopped</li>"
    "<li>\U0001f534 <strong>Dormant (lagging)</strong>: Both CAGG and source inactive &gt;24 h, but CAGG is significantly "
    "behind &mdash; refresh was not keeping up before the source went quiet</li>"
    "<li>\u26aa <strong>No data ever</strong>: Neither CAGG nor base table have any data at all</li>"
    "</ul>"
    "<p><strong>Key Insight:</strong> &ldquo;Source Stale&rdquo; uses the same frequency-based expected gap as Base Table Activity. "
    "Write-on-difference tables (controllers, depositories) have long expected gaps and won&rsquo;t false-flag. "
    "If a CAGG shows &ldquo;Source Stale&rdquo;, the refresh is working fine &mdash; the underlying base table has stopped receiving data.</p>"
)


class HealthPageService(BasePageService):
    page_id = "health"
    default_protocol = ""
    default_pair = ""

    def __init__(self, *args: Any, **kwargs: Any):
        super().__init__(*args, **kwargs)
        self._last_master_status: bool | None = None
        self._handlers = {
            "health-master": self._health_master,
            "health-queue-table": self._health_queue_table,
            "health-queue-chart": self._health_queue_chart,
            "health-queue-chart-2": self._health_queue_chart,
            "health-trigger-table": self._health_trigger_table,
            "health-base-table": self._health_base_table,
            "health-base-chart-events": self._health_base_chart_events,
            "health-base-chart-accounts": self._health_base_chart_accounts,
            "health-base-chart-insert-timing": self._health_base_chart_insert_timing,
            "health-cagg-table": self._health_cagg_table,
        }

    @property
    def _is_red(self) -> bool:
        return self._last_master_status is False

    @property
    def _table_ttl(self) -> float:
        return _TABLE_TTL_RED if self._is_red else _TABLE_TTL

    @property
    def _chart_ttl(self) -> float:
        return _CHART_TTL_RED if self._is_red else _CHART_TTL

    @staticmethod
    def _pl(params: dict[str, Any] | None) -> str:
        if _PIPELINE_LOCKED:
            return ""
        return str((params or {}).get("_pipeline") or "")

    # ------------------------------------------------------------------
    # Shared data loaders
    # ------------------------------------------------------------------

    def fetch_master_rows(self) -> list[dict[str, Any]]:
        """Public accessor used by the global health-status endpoint."""
        return self._fetch_master()

    def fetch_master_is_green(self) -> bool | None:
        """Fast path for always-on header health polling."""
        def _load_status() -> bool | None:
            rows = self.sql.fetch_rows(
                "SELECT domain, is_red FROM health.v_health_master_table",
                statement_timeout_ms=_HEALTH_STATUS_TIMEOUT_MS,
            )
            if not rows:
                return None

            master_row = next((r for r in rows if str(r.get("domain", "")).upper() == "MASTER"), None)
            if master_row is not None:
                return not _as_bool(master_row.get("is_red"))

            # Fallback for environments where the view omits/renames the MASTER row.
            return not any(_as_bool(r.get("is_red")) for r in rows)

        try:
            status = self._cached(f"health:{self._pl(None)}:master_status", _load_status, ttl_seconds=self._table_ttl)
            if status is not None:
                self._last_master_status = status
            return status
        except Exception:
            # If the fast probe times out, derive from the regular cached loader.
            # This lets the always-on header still report green/red when data exists.
            try:
                rows = self._fetch_master()
                if rows:
                    master_row = next((r for r in rows if str(r.get("domain", "")).upper() == "MASTER"), None)
                    if master_row is not None:
                        status = not _as_bool(master_row.get("is_red"))
                    else:
                        status = not any(_as_bool(r.get("is_red")) for r in rows)
                    self._last_master_status = status
                    return status
            except Exception:
                pass
            # Preserve last known state during transient DB slowness/errors.
            return self._last_master_status

    def _fetch_master(self, pl: str = "") -> list[dict[str, Any]]:
        return self._cached(
            f"health:{pl}:master",
            lambda: self.sql.fetch_rows(
                "SELECT "
                "  domain, domain_label, is_red, "
                "  queue_red, trigger_red, base_red, cagg_red "
                "FROM health.v_health_master_table",
                statement_timeout_ms=_MASTER_TIMEOUT_MS,
            ),
            ttl_seconds=self._table_ttl,
        )

    def _fetch_queues(self, pl: str = "") -> list[dict[str, Any]]:
        return self._cached(
            f"health:{pl}:queues",
            lambda: self.sql.fetch_rows(
                "SELECT "
                "  summary_status, domain, queue_name, "
                "  queue_size, max_queue_size, queue_utilization_pct, util_status, "
                "  write_rate_per_min, seconds_since_last_write, p95_staleness_7d, "
                "  gap_status, consecutive_failures, fail_status, is_red "
                "FROM health.v_health_queue_table",
                statement_timeout_ms=_TABLE_TIMEOUT_MS,
            ),
            ttl_seconds=self._table_ttl,
        )

    def _fetch_triggers(self, pl: str = "") -> list[dict[str, Any]]:
        return self._cached(
            f"health:{pl}:triggers",
            lambda: self.sql.fetch_rows(
                "SELECT "
                "  status, trigger_name, description, "
                "  source_latest, derived_latest, lag_mins, "
                "  source_rows_1h, derived_rows_1h, is_red "
                "FROM health.v_health_trigger_table",
                statement_timeout_ms=_TABLE_TIMEOUT_MS,
            ),
            ttl_seconds=self._table_ttl,
        )

    def _fetch_base_tables(self, pl: str = "") -> list[dict[str, Any]]:
        return self._cached(
            f"health:{pl}:base_tables",
            lambda: self.sql.fetch_rows(
                "SELECT "
                "  schema_name, table_name, latest_time, "
                "  minutes_since_latest, rows_last_hour, rows_last_24h, avg_rows_per_hour, "
                "  activity_status, insert_mean_ms, insert_status, "
                "  summary_status, is_red "
                "FROM health.v_health_base_table",
                statement_timeout_ms=_TABLE_TIMEOUT_MS,
            ),
            ttl_seconds=self._table_ttl,
        )

    def _fetch_caggs(self, pl: str = "") -> list[dict[str, Any]]:
        return self._cached(
            f"health:{pl}:caggs",
            lambda: self.sql.fetch_rows(
                "SELECT "
                "  status, view_schema, view_name, source_table, "
                "  cagg_latest, source_latest, refresh_lag_mins, is_red "
                "FROM health.v_health_cagg_table",
                statement_timeout_ms=_TABLE_TIMEOUT_MS,
            ),
            ttl_seconds=self._table_ttl,
        )

    # ------------------------------------------------------------------
    # 1. Master Health table
    # ------------------------------------------------------------------

    def _health_master(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._fetch_master(self._pl(params))
        master_row = next((r for r in rows if str(r.get("domain", "")).upper() == "MASTER"), None)
        domain_rows = [r for r in rows if str(r.get("domain", "")).upper() != "MASTER"]

        is_green = bool(master_row) and not _as_bool(master_row.get("is_red"))
        self._last_master_status = is_green
        title_emoji = "\U0001f7e2" if is_green else "\U0001f534"
        title_text = "ALL SYSTEMS NOMINAL" if is_green else "ACTION REQUIRED"

        formatted = []
        for r in domain_rows:
            formatted.append({
                "status": _bool_indicator(r.get("is_red")),
                "domain_label": r.get("domain_label", ""),
                "queues": _bool_indicator(r.get("queue_red")),
                "triggers": _bool_indicator(r.get("trigger_red")),
                "base_tables": _bool_indicator(r.get("base_red")),
                "cagg_refresh": _bool_indicator(r.get("cagg_red")),
                "is_red": _as_bool(r.get("is_red")),
            })

        return {
            "kind": "table",
            "title_override": f"{title_emoji} Master Health: {title_text}",
            "subtitle": "\U0001f7e2 = no red-level alerts \u00b7 \U0001f534 = at least one critical indicator",
            "info": {"key": "health-master", "content": INFO_MASTER},
            "columns": [
                {"key": "status", "label": "Status"},
                {"key": "domain_label", "label": "Domain"},
                {"key": "queues", "label": "Queues"},
                {"key": "triggers", "label": "Triggers"},
                {"key": "base_tables", "label": "Base Tables"},
                {"key": "cagg_refresh", "label": "CAGG Refresh"},
            ],
            "rows": formatted,
        }

    # ------------------------------------------------------------------
    # 2. Queue Health table
    # ------------------------------------------------------------------

    def _health_queue_table(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._fetch_queues(self._pl(params))
        formatted = []
        for r in rows:
            summary = r.get("summary_status", "")
            formatted.append({
                "summary": f"{_status_emoji(summary)} {summary}",
                "domain": r.get("domain", ""),
                "queue_name": r.get("queue_name", ""),
                "size_util": (
                    f"{r.get('queue_size', 0)}/{r.get('max_queue_size', 0)} "
                    f"({_fmt_float(r.get('queue_utilization_pct'))}%)"
                ),
                "util_status": f"{_status_emoji(r.get('util_status', ''))} {r.get('util_status', '')}",
                "write_rate": f"{_fmt_float(r.get('write_rate_per_min'))}/min",
                "last_write": _fmt_duration(r.get("seconds_since_last_write")),
                "p95_gap": _fmt_duration(r.get("p95_staleness_7d")),
                "gap_status": f"{_status_emoji(r.get('gap_status', ''))} {r.get('gap_status', '')}",
                "failures": str(r.get("consecutive_failures", 0)),
                "fail_status": f"{_status_emoji(r.get('fail_status', ''))} {r.get('fail_status', '')}",
                "is_red": r.get("is_red", False),
            })

        return {
            "kind": "table",
            "info": {"key": "health-queue", "content": INFO_QUEUE},
            "columns": [
                {"key": "summary", "label": "Summary"},
                {"key": "domain", "label": "Schema"},
                {"key": "queue_name", "label": "Queue"},
                {"key": "size_util", "label": "Size (Util%)"},
                {"key": "util_status", "label": "Util Status"},
                {"key": "write_rate", "label": "Write Rate"},
                {"key": "last_write", "label": "Last Write"},
                {"key": "p95_gap", "label": "P95 Gap"},
                {"key": "gap_status", "label": "Gap Status"},
                {"key": "failures", "label": "Failures"},
                {"key": "fail_status", "label": "Fail Status"},
            ],
            "rows": formatted,
        }

    # ------------------------------------------------------------------
    # 3. Queue Health chart
    # ------------------------------------------------------------------

    def _health_queue_chart(self, params: dict[str, Any]) -> dict[str, Any]:
        schema = str(params.get("health_schema") or "dexes")
        attribute = str(params.get("health_attribute") or "Write Rate")
        last_window = str(params.get("last_window") or "7d")

        if schema not in VALID_SCHEMAS:
            schema = "dexes"
        if attribute not in VALID_ATTRIBUTES:
            attribute = "Write Rate"

        lookback, interval = WINDOW_MAP.get(last_window, ("7 days", "3 hours"))
        pl = self._pl(params)
        cache_key = f"health:{pl}:queue_chart::{schema}::{attribute}::{last_window}"

        def _load() -> list[dict[str, Any]]:
            return self.sql.fetch_rows(
                "SELECT bucket, queue_name, avg_value "
                "FROM health.v_health_queue_chart(%s, %s, %s, %s)",
                (schema, attribute, lookback, interval),
                statement_timeout_ms=_CHART_TIMEOUT_MS,
            )

        raw = self._cached(cache_key, _load, ttl_seconds=self._chart_ttl)

        queue_names: list[str] = list(dict.fromkeys(r["queue_name"] for r in raw))
        bucket_map: dict[str, dict[str, Any]] = {}
        for row in raw:
            b = str(row["bucket"])
            if b not in bucket_map:
                bucket_map[b] = {"bucket_time": b}
            bucket_map[b][row["queue_name"]] = row.get("avg_value") or 0

        pivoted = sorted(bucket_map.values(), key=lambda r: r["bucket_time"])

        y_config: dict[str, dict[str, str]] = {
            "Queue Size":  {"label": "% Capacity", "format": "pct0"},
            "Write Rate":  {"label": "Rows/min",   "format": "compact"},
            "Gap Size":    {"label": "Seconds",     "format": "compact"},
            "Failures":    {"label": "Avg. Failures", "format": "compact"},
        }
        cfg = y_config.get(attribute, {"label": attribute, "format": "compact"})

        series = []
        for i, name in enumerate(queue_names):
            series.append({
                "name": name,
                "type": "line",
                "color": QUEUE_COLORS[i % len(QUEUE_COLORS)],
                "data": [r.get(name) for r in pivoted],
            })

        return {
            "kind": "chart",
            "chart": "line",
            "x": [r["bucket_time"] for r in pivoted],
            "yAxisLabel": cfg["label"],
            "yAxisFormat": cfg["format"],
            "series": series,
        }

    # ------------------------------------------------------------------
    # 4. Trigger Health table
    # ------------------------------------------------------------------

    def _health_trigger_table(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._fetch_triggers(self._pl(params))
        formatted = []
        for r in rows:
            status = r.get("status", "")
            formatted.append({
                "status": f"{_status_emoji(status)} {status}",
                "trigger_name": r.get("trigger_name", ""),
                "description": r.get("description", ""),
                "source_latest": _fmt_ts(r.get("source_latest")),
                "derived_latest": _fmt_ts(r.get("derived_latest")),
                "lag_mins": _fmt_float(r.get("lag_mins")),
                "source_rows_1h": _fmt_int(r.get("source_rows_1h")),
                "derived_rows_1h": _fmt_int(r.get("derived_rows_1h")),
                "is_red": r.get("is_red", False),
            })

        return {
            "kind": "table",
            "info": {"key": "health-trigger", "content": INFO_TRIGGER},
            "columns": [
                {"key": "status", "label": "Status"},
                {"key": "trigger_name", "label": "Trigger"},
                {"key": "description", "label": "Description"},
                {"key": "source_latest", "label": "Source Latest"},
                {"key": "derived_latest", "label": "Calc Latest"},
                {"key": "lag_mins", "label": "Lag (min)"},
                {"key": "source_rows_1h", "label": "Source 1h"},
                {"key": "derived_rows_1h", "label": "Calc 1h"},
            ],
            "rows": formatted,
        }

    # ------------------------------------------------------------------
    # 5. Base Table Activity table
    # ------------------------------------------------------------------

    def _health_base_table(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._fetch_base_tables(self._pl(params))
        formatted = []
        for r in rows:
            act    = r.get("activity_status", "")
            ins    = r.get("insert_status") or ""
            summ   = r.get("summary_status", "")
            ins_ms = r.get("insert_mean_ms")
            if ins_ms is None:
                ins_ms_fmt = "\u2014"
                ins_fmt    = "\u2014"
            else:
                ms = float(ins_ms)
                ins_ms_fmt = f"{ms:.0f}ms" if ms >= 1 else f"{ms:.2f}ms"
                ins_fmt    = f"{_status_emoji(ins)} {ins}"
            formatted.append({
                "summary":      f"{_status_emoji(summ)} {summ}",
                "schema_name":  r.get("schema_name", ""),
                "table_name":   r.get("table_name", ""),
                "latest_time":  _fmt_ts(r.get("latest_time")),
                "min_ago":      _fmt_float(r.get("minutes_since_latest")),
                "rows_1h":      _fmt_int(r.get("rows_last_hour")),
                "rows_24h":     _fmt_int(r.get("rows_last_24h")),
                "avg_per_hour": _fmt_int(r.get("avg_rows_per_hour")),
                "activity":     f"{_status_emoji(act)} {act}",
                "insert_ms":    ins_ms_fmt,
                "insert":       ins_fmt,
                "is_red":       r.get("is_red", False),
            })

        return {
            "kind": "table",
            "info": {"key": "health-base-table", "content": INFO_BASE_TABLE},
            "columns": [
                {"key": "summary",      "label": "Summary"},
                {"key": "schema_name",  "label": "Schema"},
                {"key": "table_name",   "label": "Table"},
                {"key": "latest_time",  "label": "Latest"},
                {"key": "min_ago",      "label": "Min Ago"},
                {"key": "rows_1h",      "label": "Rows 1h"},
                {"key": "rows_24h",     "label": "Rows 24h"},
                {"key": "avg_per_hour", "label": "Avg/Hour"},
                {"key": "activity",     "label": "Activity"},
                {"key": "insert_ms",    "label": "Insert ms"},
                {"key": "insert",       "label": "Insert"},
            ],
            "rows": formatted,
        }

    # ------------------------------------------------------------------
    # 6 & 7. Base Table Activity charts (events / accounts)
    # ------------------------------------------------------------------

    def _base_chart_data(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        schema = str(params.get("health_base_schema") or "dexes")
        last_window = str(params.get("last_window") or "7d")
        if schema not in VALID_SCHEMAS:
            schema = "dexes"
        lookback, interval = WINDOW_MAP.get(last_window, ("7 days", "3 hours"))
        pl = self._pl(params)
        cache_key = f"health:{pl}:base_chart::{schema}::{last_window}"

        def _load() -> list[dict[str, Any]]:
            return self.sql.fetch_rows(
                "SELECT bucket, category, avg_row_count "
                "FROM health.v_health_base_chart(%s, %s, %s)",
                (schema, lookback, interval),
                statement_timeout_ms=_CHART_TIMEOUT_MS,
            )

        return self._cached(cache_key, _load, ttl_seconds=self._chart_ttl)

    def _build_base_chart(self, params: dict[str, Any], category: str) -> dict[str, Any]:
        raw = self._base_chart_data(params)
        last_window = str(params.get("last_window") or "7d")
        window = _rolling_window(last_window)

        filtered = sorted(
            [r for r in raw if r.get("category") == category],
            key=lambda r: str(r.get("bucket", "")),
        )

        x = [str(r["bucket"]) for r in filtered]
        values = [r.get("avg_row_count") for r in filtered]
        rolling = _rolling_avg(values, window)

        _, interval_str = WINDOW_MAP.get(last_window, ("7 days", "3 hours"))
        parts = interval_str.split()
        num = int(parts[0])
        unit = parts[1]
        if "min" in unit:
            interval_min = num
        elif "hour" in unit:
            interval_min = num * 60
        else:
            interval_min = num * 1440
        total_hours = (window * interval_min) / 60
        if total_hours < 24:
            rolling_label = f"{total_hours:.0f}h Rolling Avg"
        elif total_hours % 24 == 0:
            rolling_label = f"{int(total_hours // 24)}d Rolling Avg"
        else:
            rolling_label = f"{total_hours:.0f}h Rolling Avg"

        return {
            "kind": "chart",
            "chart": "line",
            "x": x,
            "yAxisLabel": "Rows/Hour",
            "yAxisFormat": "compact",
            "series": [
                {
                    "name": "Rows/Hour",
                    "type": "line",
                    "color": "#4bb7ff",
                    "data": values,
                },
                {
                    "name": rolling_label,
                    "type": "line",
                    "color": "#f8a94a",
                    "lineStyle": "dashed",
                    "data": rolling,
                },
            ],
        }

    def _health_base_chart_events(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._build_base_chart(params, "Transaction Events")

    def _health_base_chart_accounts(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._build_base_chart(params, "Account Updates")

    def _health_base_chart_insert_timing(self, params: dict[str, Any]) -> dict[str, Any]:
        schema = str(params.get("health_base_schema") or "dexes")
        last_window = str(params.get("last_window") or "7d")
        if schema not in VALID_SCHEMAS:
            schema = "dexes"
        lookback, interval = WINDOW_MAP.get(last_window, ("7 days", "3 hours"))
        pl = self._pl(params)
        cache_key = f"health:{pl}:insert_timing_chart::{schema}::{last_window}"

        def _load() -> list[dict[str, Any]]:
            return self.sql.fetch_rows(
                "SELECT bucket, table_name, avg_value "
                "FROM health.v_health_insert_timing_chart(%s, %s, %s, %s)",
                (schema, "Mean Insert ms", lookback, interval),
                statement_timeout_ms=_CHART_TIMEOUT_MS,
            )

        raw = self._cached(cache_key, _load, ttl_seconds=self._chart_ttl)

        # Build aligned series — each table gets one value per bucket (None if absent)
        lookup: dict[tuple[str, str], Any] = {}
        all_tables: set[str] = set()
        buckets: list[str] = []
        seen_buckets: set[str] = set()
        for r in sorted(raw, key=lambda r: str(r.get("bucket", ""))):
            b = str(r["bucket"])
            tbl = str(r.get("table_name", ""))
            if b not in seen_buckets:
                buckets.append(b)
                seen_buckets.add(b)
            all_tables.add(tbl)
            lookup[(b, tbl)] = r.get("avg_value")

        series = [
            {
                "name": tbl,
                "type": "line",
                "color": QUEUE_COLORS[i % len(QUEUE_COLORS)],
                "data": [lookup.get((b, tbl)) for b in buckets],
            }
            for i, tbl in enumerate(sorted(all_tables))
        ]

        return {
            "kind": "chart",
            "chart": "line",
            "x": buckets,
            "yAxisLabel": "Mean Insert ms",
            "yAxisFormat": "decimal",
            "series": series,
        }

    # ------------------------------------------------------------------
    # 8. CAGG Refresh Health table
    # ------------------------------------------------------------------

    def _health_cagg_table(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._fetch_caggs(self._pl(params))
        formatted = []
        for r in rows:
            status = r.get("status", "")
            formatted.append({
                "status": f"{_status_emoji(status)} {status}",
                "view_schema": r.get("view_schema", ""),
                "view_name": r.get("view_name", ""),
                "source_table": r.get("source_table", ""),
                "cagg_latest": _fmt_ts(r.get("cagg_latest")),
                "source_latest": _fmt_ts(r.get("source_latest")),
                "lag_mins": _fmt_float(r.get("refresh_lag_mins")),
                "is_red": r.get("is_red", False),
            })

        return {
            "kind": "table",
            "info": {"key": "health-cagg", "content": INFO_CAGG},
            "columns": [
                {"key": "status", "label": "Status"},
                {"key": "view_schema", "label": "Schema"},
                {"key": "view_name", "label": "CAGG"},
                {"key": "source_table", "label": "Base Table"},
                {"key": "cagg_latest", "label": "CAGG Latest"},
                {"key": "source_latest", "label": "Source Latest"},
                {"key": "lag_mins", "label": "Lag (min)"},
            ],
            "rows": formatted,
        }
