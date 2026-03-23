from __future__ import annotations

from app.pages.common import PageConfig, WidgetConfig


def _hdr(wid, title, css):
    return WidgetConfig(wid, title, "section-header", css)


PAGE_CONFIG = PageConfig(
    slug="system-health",
    label="System Health",
    api_page_id="health",
    show_protocol_pair_filters=False,
    video_guide_youtube_id="tuuF4efh3NM",
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
        # Section 3: BASE TABLE HEALTH
        # ═══════════════════════════════════════════════════════
        _hdr("h-hdr-3", "Base Table Health", "h-hdr-3 cv-section-header"),

        WidgetConfig(
            "health-base-table",
            "Base Table Activity",
            "table",
            "panel panel-wide-table health-slot-base-table",
            expandable=False,
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
            "health-base-chart-insert-timing",
            "Insert Timing",
            "chart",
            "panel panel-medium health-slot-base-insert",
            expandable=True,
        ),

        # ═══════════════════════════════════════════════════════
        # Section 4: TRIGGER FUNCTION HEALTH
        # ═══════════════════════════════════════════════════════
        _hdr("h-hdr-4", "Trigger Function Health", "h-hdr-4 cv-section-header"),

        WidgetConfig(
            "health-trigger-table",
            "Trigger Function Health",
            "table",
            "panel panel-wide-table health-slot-trigger",
            expandable=False,
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
        ),
    ],
)
