# Dashboard UI Kit

A React + Plotly recreation of the operational dashboard (`demo.rmckinley.net`), harmonised with the marketing tokens in `colors_and_type.css`. Source: `pfx/htmx/` (FastAPI + htmx + Plotly + custom CSS).

## Structure

```
index.html       ← composed dashboard (sidebar tab navigation, persisted in localStorage)
dashboard.css    ← scoped chrome + panel styles (imports ../../colors_and_type.css)
Chrome.jsx       ← Ico set, TopBar, Sidebar, FilterSelect
Widgets.jsx      ← Widget (panel shell), Metric, MetricStrip, DataTable, Delta, BottomBar
Charts.jsx       ← PlotlyChart wrapper + AreaChart / LineChart / BarChart /
                   StackedAreaChart / DonutChart, all pre-themed to the harmonised palette
Views.jsx        ← OverviewView, LiquidityView, ReservesView, RiskView (mock data)
```

## Tabs included

- **Overview** — TVL, protocol exposure donut, swap distribution, MM performance, recent activity table
- **Liquidity** — depth, venue share, price-impact curve
- **Reserves & Yields** — per-protocol reserves, supply/borrow table, yield curve
- **Risk & Stress** — stress scenario, tail chart, open risk events

Tabs are persisted in `localStorage` under `mkf-dash-tab`.

## Design decisions worth preserving

- **Tonal depth, not shadows.** Panels are `#0f1a2d` on `#0a1020`. One `1px` alpha-white border; radii 8px.
- **Single accent.** Amber appears only on: health-dot green→amber→red states, the active sidebar tab (left edge + text), widget-title icons, chart-1 (primary series). Every other series uses the cool palette.
- **Plotly styling is centralized.** `CHART_LAYOUT_BASE` in `Charts.jsx` is applied to every chart — transparent paper/plot, `rgba(255,255,255,0.05)` gridlines, Geist Mono axis text, HoverLabel with `#0F172A` bg.
- **Status colour discipline.** Green `#36C96A` up / red `#F65F74` down / info blue `#4BB7FF` links / amber `#F8A94A` warn. Never other greens or reds.
- **Tabular-nums everywhere numeric.** Metrics, tables, axis ticks, deltas — all via `font-variant-numeric: tabular-nums`.
- **Status pulse.** The topbar health dot pulses when red (2s ease-in-out). This is a lift from `theme.css`'s `health-pulse` keyframe.

## Caveats

- Data is deterministic mock via seeded PRNG — `makeTimeseries()` in `Charts.jsx`. Swap for real endpoints when wiring to the htmx backend.
- htmx markup (`hx-get`, `hx-target`, `hx-trigger`) is not modelled here — the real dashboard is server-driven. This is an *interactive specimen* for design review only.
- Incidents and Settings tabs are stubbed (greyed out in the sidebar).
