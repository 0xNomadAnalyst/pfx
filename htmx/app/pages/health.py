from __future__ import annotations

from app.pages.common import PageConfig, WidgetConfig


PAGE_CONFIG = PageConfig(
    slug="system-health",
    label="System Health",
    api_page_id="health",
    show_protocol_pair_filters=False,
    widgets=[
        WidgetConfig(
            "health-master",
            "Master Health",
            "table",
            "panel panel-wide-table health-slot-master",
            expandable=False,
        ),
        WidgetConfig(
            "health-queue-table",
            "Queue Health Monitoring",
            "table",
            "panel panel-wide-table health-slot-queue-table",
            expandable=False,
            tooltip="Real-time status of database write queues. Status levels: \U0001f7e2 NORMAL \u00b7 \U0001f7e1 ELEVATED \u00b7 \U0001f7e0 HIGH \u00b7 \U0001f534 ANOMALY",
        ),
        WidgetConfig(
            "health-queue-chart",
            "Queue Health",
            "chart",
            "panel panel-medium health-slot-queue-chart",
            expandable=True,
        ),
        WidgetConfig(
            "health-trigger-table",
            "Trigger Function Health",
            "table",
            "panel panel-wide-table health-slot-trigger",
            expandable=False,
            tooltip="Monitors whether trigger functions are firing correctly. Status: \U0001f7e2 Healthy \u00b7 \U0001f7e1 Lagging \u00b7 \U0001f7e0 Low coverage \u00b7 \U0001f534 Not firing \u00b7 \u26aa No source",
        ),
        WidgetConfig(
            "health-base-table",
            "Base Table Activity",
            "table",
            "panel panel-wide-table health-slot-base-table",
            expandable=False,
            tooltip="Ingestion freshness assessed against frequency-based expected gaps. Status: \U0001f7e2 Active \u00b7 \U0001f7e0 Check \u00b7 \U0001f534 Stale / ANOMALY",
        ),
        WidgetConfig(
            "health-base-chart-events",
            "Transaction Events",
            "chart",
            "panel panel-medium health-slot-base-events",
            expandable=True,
        ),
        WidgetConfig(
            "health-base-chart-accounts",
            "Account Updates",
            "chart",
            "panel panel-medium health-slot-base-accts",
            expandable=True,
        ),
        WidgetConfig(
            "health-cagg-table",
            "CAGG Refresh Health",
            "table",
            "panel panel-wide-table health-slot-cagg",
            expandable=False,
            tooltip="Continuous aggregate refresh status. Status: \U0001f7e2 Refresh OK \u00b7 \U0001f7e1 Delayed / Source Stale \u00b7 \U0001f534 Refresh Broken \u00b7 \u26aa No data",
        ),
    ],
)
