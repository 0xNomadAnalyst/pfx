from __future__ import annotations

import os
from datetime import datetime, timezone
from typing import Any

from app.services.pages.base import BasePageService

_TABLE_TTL = float(os.getenv("HEALTH_TABLE_TTL_SECONDS", "60"))
_CHART_TTL = float(os.getenv("HEALTH_CHART_TTL_SECONDS", "120"))
_CHART_TIMEOUT_MS = 30_000
_HEALTH_STATUS_TIMEOUT_MS = int(os.getenv("HEALTH_STATUS_TIMEOUT_MS", "2000"))

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

VALID_SCHEMAS = {"dexes", "exponent", "kamino_lend", "solstice_proprietary"}
VALID_ATTRIBUTES = {"Queue Size", "Write Rate", "Gap Size", "Failures"}


# ---------------------------------------------------------------------------
# Formatting helpers (mirror React healthFormatters.ts)
# ---------------------------------------------------------------------------

def _status_emoji(status: str) -> str:
    s = (status or "").lower()
    if any(k in s for k in ("normal", "active", "healthy", "ok", "green")):
        return "\U0001f7e2"
    if any(k in s for k in ("elevated", "delayed", "lagging", "stale")):
        return "\U0001f7e1"
    if any(k in s for k in ("high", "check", "low coverage")):
        return "\U0001f7e0"
    if any(k in s for k in ("anomaly", "broken", "not firing", "red")):
        return "\U0001f534"
    return "\u26aa"


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
    "<li><strong>Base Tables</strong> &mdash; could indicate real anomalous activity or an underlying technical issue with data ingestion</li>"
    "</ul>"
)

INFO_QUEUE = (
    "<p>Real-time status of database write queues across all protocol domains. "
    "Each queue represents an independent worker with its own database connection.</p>"
    "<p><strong>Status Indicators:</strong></p>"
    "<ul>"
    "<li>\U0001f7e2 <strong>NORMAL</strong>: Within historical norm (\u2264 2x P95)</li>"
    "<li>\U0001f7e1 <strong>ELEVATED</strong>: Minor deviation (2-4x P95)</li>"
    "<li>\U0001f7e0 <strong>HIGH</strong>: Notable deviation (4-8x P95)</li>"
    "<li>\U0001f534 <strong>ANOMALY</strong>: Extreme deviation (&gt; 8x P95)</li>"
    "</ul>"
    "<p><strong>Summary</strong> (leftmost column) reflects the worst status across Gap, Util, and Failure dimensions. "
    "Many queues use &ldquo;write on difference only&rdquo; mode &mdash; long periods without writes are normal when underlying data hasn&rsquo;t changed.</p>"
)

INFO_TRIGGER = (
    "<p>Monitors whether trigger functions (e.g., swap impact calculation, price filling) "
    "are firing correctly. Checks for gaps between base table inserts and derived table updates.</p>"
    "<p><strong>Status Indicators:</strong></p>"
    "<ul>"
    "<li>\U0001f7e2 <strong>Healthy</strong>: Trigger is firing and derived table is up to date</li>"
    "<li>\U0001f7e1 <strong>Lagging</strong>: Derived table is &gt;10 minutes behind source</li>"
    "<li>\U0001f7e0 <strong>Low coverage</strong>: Derived table has &lt;50% of source rows in the last hour</li>"
    "<li>\U0001f534 <strong>Trigger not firing</strong>: Source has data but derived table has none</li>"
    "<li>\u26aa <strong>No source data</strong>: Base table itself has no recent data</li>"
    "</ul>"
)

INFO_BASE_TABLE = (
    "<p>Monitors ingestion activity by checking row counts and latest timestamps in base tables. "
    "Compares recent activity against historical benchmarks.</p>"
    "<p><strong>Status Logic:</strong> Uses 7-day write frequency (hours with any data / 168 total hours) "
    "to derive an <em>expected gap</em> between writes. This naturally handles write-on-difference tables "
    "&mdash; if a table only writes a few times per week, gaps of hours or days are treated as normal.</p>"
    "<p><strong>Status Indicators</strong> (ratio = current gap / expected gap):</p>"
    "<ul>"
    "<li>\U0001f7e2 <strong>Active</strong>: \u2264 2x expected gap (normal)</li>"
    "<li>\U0001f7e0 <strong>Check</strong>: 2-5x expected gap (worth monitoring)</li>"
    "<li>\U0001f534 <strong>Stale</strong>: 5-10x expected gap (significant deviation)</li>"
    "<li>\U0001f534 <strong>ANOMALY</strong>: &gt; 10x expected gap (extreme deviation)</li>"
    "</ul>"
)

INFO_CAGG = (
    "<p>Tests whether the CAGG refresh cronjob is running correctly by comparing CAGG bucket times "
    "to base table times. The cronjob runs every 5 seconds and refreshes all 21 CAGGs with a 2-hour lookback window.</p>"
    "<p><strong>Status Indicators:</strong></p>"
    "<ul>"
    "<li>\U0001f7e2 <strong>Refresh OK</strong>: CAGG is within 5 minutes of source data &mdash; cronjob working correctly</li>"
    "<li>\U0001f7e1 <strong>Refresh Delayed</strong>: 5-15 minute lag &mdash; minor delay, monitor</li>"
    "<li>\U0001f7e1 <strong>Source Stale</strong>: Base table exceeds 2x its expected write gap (frequency-based) &mdash; NOT a cronjob issue</li>"
    "<li>\U0001f534 <strong>Refresh Broken</strong>: CAGG &gt;15 minutes behind source &mdash; cronjob may have stopped</li>"
    "<li>\u26aa <strong>No data</strong>: Neither CAGG nor base table have any data</li>"
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
            "health-trigger-table": self._health_trigger_table,
            "health-base-table": self._health_base_table,
            "health-base-chart-events": self._health_base_chart_events,
            "health-base-chart-accounts": self._health_base_chart_accounts,
            "health-cagg-table": self._health_cagg_table,
        }

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
            status = self._cached("health::master_status", _load_status, ttl_seconds=_TABLE_TTL)
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

    def _fetch_master(self) -> list[dict[str, Any]]:
        return self._cached(
            "health::master",
            lambda: self.sql.fetch_rows("SELECT * FROM health.v_health_master_table"),
            ttl_seconds=_TABLE_TTL,
        )

    def _fetch_queues(self) -> list[dict[str, Any]]:
        return self._cached(
            "health::queues",
            lambda: self.sql.fetch_rows("SELECT * FROM health.v_health_queue_table"),
            ttl_seconds=_TABLE_TTL,
        )

    def _fetch_triggers(self) -> list[dict[str, Any]]:
        return self._cached(
            "health::triggers",
            lambda: self.sql.fetch_rows("SELECT * FROM health.v_health_trigger_table"),
            ttl_seconds=_TABLE_TTL,
        )

    def _fetch_base_tables(self) -> list[dict[str, Any]]:
        return self._cached(
            "health::base_tables",
            lambda: self.sql.fetch_rows("SELECT * FROM health.v_health_base_table"),
            ttl_seconds=_TABLE_TTL,
        )

    def _fetch_caggs(self) -> list[dict[str, Any]]:
        return self._cached(
            "health::caggs",
            lambda: self.sql.fetch_rows("SELECT * FROM health.v_health_cagg_table"),
            ttl_seconds=_TABLE_TTL,
        )

    # ------------------------------------------------------------------
    # 1. Master Health table
    # ------------------------------------------------------------------

    def _health_master(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._fetch_master()
        master_row = next((r for r in rows if str(r.get("domain", "")).upper() == "MASTER"), None)
        domain_rows = [r for r in rows if str(r.get("domain", "")).upper() != "MASTER"]

        is_green = bool(master_row) and not _as_bool(master_row.get("is_red"))
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
        rows = self._fetch_queues()
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
        cache_key = f"health::queue_chart::{schema}::{attribute}::{last_window}"

        def _load() -> list[dict[str, Any]]:
            return self.sql.fetch_rows(
                "SELECT * FROM health.v_health_queue_chart(%s, %s, %s, %s)",
                (schema, attribute, lookback, interval),
                statement_timeout_ms=_CHART_TIMEOUT_MS,
            )

        raw = self._cached(cache_key, _load, ttl_seconds=_CHART_TTL)

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
        rows = self._fetch_triggers()
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
        rows = self._fetch_base_tables()
        formatted = []
        for r in rows:
            status = r.get("status", "")
            formatted.append({
                "status": f"{_status_emoji(status)} {status}",
                "schema_name": r.get("schema_name", ""),
                "table_name": r.get("table_name", ""),
                "latest_time": _fmt_ts(r.get("latest_time")),
                "min_ago": _fmt_float(r.get("minutes_since_latest")),
                "rows_1h": _fmt_int(r.get("rows_last_hour")),
                "rows_24h": _fmt_int(r.get("rows_last_24h")),
                "avg_per_hour": _fmt_int(r.get("avg_rows_per_hour")),
                "is_red": r.get("is_red", False),
            })

        return {
            "kind": "table",
            "info": {"key": "health-base-table", "content": INFO_BASE_TABLE},
            "columns": [
                {"key": "status", "label": "Status"},
                {"key": "schema_name", "label": "Schema"},
                {"key": "table_name", "label": "Table"},
                {"key": "latest_time", "label": "Latest"},
                {"key": "min_ago", "label": "Min Ago"},
                {"key": "rows_1h", "label": "Rows 1h"},
                {"key": "rows_24h", "label": "Rows 24h"},
                {"key": "avg_per_hour", "label": "Avg/Hour"},
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
        cache_key = f"health::base_chart::{schema}::{last_window}"

        def _load() -> list[dict[str, Any]]:
            return self.sql.fetch_rows(
                "SELECT * FROM health.v_health_base_chart(%s, %s, %s)",
                (schema, lookback, interval),
                statement_timeout_ms=_CHART_TIMEOUT_MS,
            )

        return self._cached(cache_key, _load, ttl_seconds=_CHART_TTL)

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

    # ------------------------------------------------------------------
    # 8. CAGG Refresh Health table
    # ------------------------------------------------------------------

    def _health_cagg_table(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._fetch_caggs()
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
