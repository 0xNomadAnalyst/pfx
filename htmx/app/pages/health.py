from __future__ import annotations

from app.pages.common import PageConfig, WidgetConfig


def _hdr(wid, title, css):
    return WidgetConfig(wid, title, "section-header", css)


PAGE_CONFIG = PageConfig(
    slug="system-health",
    label="System Health",
    api_page_id="health",
    show_protocol_pair_filters=False,
    video_guide_youtube_id="ky5vsKgcEK0",
    widgets=[
        # ═══════════════════════════════════════════════════════
        # Section 1: MASTER HEALTH CHECKS
        # ═══════════════════════════════════════════════════════
        _hdr("h-hdr-1", "Master Health Checks", "h-hdr-1 cv-section-header"),

        WidgetConfig(
            "health-master",
            "Master Health",
            "table",
            "panel panel-wide-table health-slot-master",
            expandable=False,
        ),

        # ═══════════════════════════════════════════════════════
        # Section 2: WRITE QUEUE HEALTH
        # ═══════════════════════════════════════════════════════
        _hdr("h-hdr-2", "Write Queue Health", "h-hdr-2 cv-section-header"),

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
            "health-queue-chart-2",
            "Queue Health",
            "chart",
            "panel panel-medium health-slot-queue-chart-2",
            expandable=True,
        ),

        # ═══════════════════════════════════════════════════════
        # Section 3: TRIGGER FUNCTION HEALTH
        # ═══════════════════════════════════════════════════════
        _hdr("h-hdr-3", "Trigger Function Health", "h-hdr-3 cv-section-header"),

        WidgetConfig(
            "health-trigger-table",
            "Trigger Function Health",
            "table",
            "panel panel-wide-table health-slot-trigger",
            expandable=False,
            tooltip="Monitors whether trigger functions are firing correctly. Status: \U0001f7e2 Healthy \u00b7 \U0001f7e1 Lagging \u00b7 \U0001f7e0 Low coverage \u00b7 \U0001f534 Not firing \u00b7 \u26aa No source",
        ),

        # ═══════════════════════════════════════════════════════
        # Section 4: BASE TABLE HEALTH
        # ═══════════════════════════════════════════════════════
        _hdr("h-hdr-4", "Base Table Health", "h-hdr-4 cv-section-header"),

        WidgetConfig(
            "health-base-table",
            "Base Table Activity",
            "table",
            "panel panel-wide-table health-slot-base-table",
            expandable=False,
            tooltip="Ingestion freshness assessed against frequency-based expected gaps. Status: \U0001f7e2 Active \u00b7 \U0001f7e1 Check \u00b7 \U0001f7e0 Stale \u00b7 \U0001f534 ANOMALY",
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

        # ═══════════════════════════════════════════════════════
        # Section 5: CONTINUOUS AGGREGATE TABLE HEALTH
        # ═══════════════════════════════════════════════════════
        _hdr("h-hdr-5", "Continuous Aggregate Table Health", "h-hdr-5 cv-section-header"),

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
