// Dashboard UI Kit — Plotly-based charts, harmonised palette

const CHART_PALETTE = [
  "#FF6B00", // amber/orange  — primary series (chart-1)
  "#4BB7FF", // info blue
  "#36C96A", // positive green
  "#B085F5", // violet
  "#F65F74", // rose
  "#8EA1C7", // steel neutral
];

const CHART_LAYOUT_BASE = {
  paper_bgcolor: "rgba(0,0,0,0)",
  plot_bgcolor: "rgba(0,0,0,0)",
  font: {
    family: 'Geist Mono, "IBM Plex Mono", ui-monospace, monospace',
    size: 11,
    color: "#FFFFFF",
  },
  margin: { l: 44, r: 16, t: 8, b: 36 },
  xaxis: {
    gridcolor: "rgba(255,255,255,0.05)",
    zerolinecolor: "rgba(255,255,255,0.09)",
    linecolor: "rgba(255,255,255,0.11)",
    tickcolor: "rgba(255,255,255,0.11)",
    tickfont: { color: "#A6B4C8" },
  },
  yaxis: {
    gridcolor: "rgba(255,255,255,0.05)",
    zerolinecolor: "rgba(255,255,255,0.09)",
    linecolor: "rgba(255,255,255,0.11)",
    tickcolor: "rgba(255,255,255,0.11)",
    tickfont: { color: "#A6B4C8" },
    tickformat: "~s",
  },
  hoverlabel: {
    bgcolor: "#0F172A",
    bordercolor: "rgba(255,255,255,0.11)",
    font: { family: 'Geist Mono, monospace', color: "#EDF1F7" },
  },
  showlegend: false,
};

const CHART_CONFIG = {
  displayModeBar: false,
  responsive: true,
};

/* PlotlyChart — thin wrapper. Works with or without Plotly loaded. */
function PlotlyChart({ traces, layout = {}, height = 220, style }) {
  const ref = useRef(null);
  useEffect(() => {
    if (!ref.current) return;
    if (typeof window.Plotly === "undefined") {
      // Fallback: ASCII-ish info
      ref.current.innerHTML = "<div style='color:#6B7794;font-family:var(--font-mono);font-size:11px;padding:20px;text-align:center'>Plotly not loaded</div>";
      return;
    }
    const l = { ...CHART_LAYOUT_BASE, ...layout };
    l.xaxis = { ...CHART_LAYOUT_BASE.xaxis, ...(layout.xaxis || {}) };
    l.yaxis = { ...CHART_LAYOUT_BASE.yaxis, ...(layout.yaxis || {}) };
    window.Plotly.newPlot(ref.current, traces, l, CHART_CONFIG);
    return () => {
      if (ref.current && window.Plotly) window.Plotly.purge(ref.current);
    };
  }, [traces, layout, height]);
  return <div ref={ref} className="db-chart" style={{ height, ...style }} />;
}

/* ── Data generators (deterministic) ───────────────────────────────── */
function seedRand(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

function makeTimeseries(n = 60, startY = 100, vol = 0.015, seed = 42, drift = 0.001) {
  const rnd = seedRand(seed);
  const today = new Date();
  const xs = [], ys = [];
  let y = startY;
  for (let i = n - 1; i >= 0; i--) {
    const d = new Date(today); d.setDate(d.getDate() - i);
    xs.push(d.toISOString().slice(0, 10));
    y = y * (1 + drift + vol * (rnd() - 0.5) * 2);
    ys.push(y);
  }
  return { x: xs, y: ys };
}

/* ── Preconfigured charts ───────────────────────────────────────────── */
function AreaChart({ series = [{ name: "Series 1", seed: 7, start: 100 }], height = 220, yFormat }) {
  const traces = series.map((s, i) => {
    const d = makeTimeseries(60, s.start, s.vol || 0.012, s.seed, s.drift || 0.002);
    const color = CHART_PALETTE[i % CHART_PALETTE.length];
    return {
      x: d.x, y: d.y,
      name: s.name, type: "scatter", mode: "lines",
      line: { color, width: 1.6 },
      fill: "tozeroy",
      fillcolor: `${color}20`,
      hovertemplate: "%{x}<br><b>%{y:,.0f}</b><extra></extra>",
    };
  });
  const layout = yFormat ? { yaxis: { tickformat: yFormat } } : {};
  return <PlotlyChart traces={traces} layout={layout} height={height} />;
}

function LineChart({ series, height = 220 }) {
  const traces = series.map((s, i) => {
    const d = makeTimeseries(60, s.start, s.vol || 0.012, s.seed, s.drift || 0.001);
    const color = CHART_PALETTE[i % CHART_PALETTE.length];
    return {
      x: d.x, y: d.y,
      name: s.name, type: "scatter", mode: "lines",
      line: { color, width: 1.6 },
      hovertemplate: `<b>${s.name}</b><br>%{x}<br>%{y:,.2f}<extra></extra>`,
    };
  });
  return <PlotlyChart
    traces={traces}
    layout={{ showlegend: true, legend: { x: 0, y: 1.1, orientation: "h", font: { size: 10.5, color: "#A6B4C8" } }, margin: { l: 44, r: 16, t: 28, b: 36 } }}
    height={height}
  />;
}

function BarChart({ categories, values, color = CHART_PALETTE[0], height = 220, horizontal = false }) {
  const trace = horizontal
    ? { type: "bar", orientation: "h", x: values, y: categories, marker: { color }, hovertemplate: "<b>%{y}</b><br>%{x:,.2f}<extra></extra>" }
    : { type: "bar", x: categories, y: values, marker: { color }, hovertemplate: "<b>%{x}</b><br>%{y:,.2f}<extra></extra>" };
  return <PlotlyChart traces={[trace]} height={height} />;
}

function StackedAreaChart({ series, height = 220 }) {
  const traces = series.map((s, i) => {
    const d = makeTimeseries(60, s.start, s.vol || 0.01, s.seed, 0.0008);
    const color = CHART_PALETTE[i % CHART_PALETTE.length];
    return {
      x: d.x, y: d.y,
      name: s.name, type: "scatter", mode: "lines",
      line: { width: 0, color },
      stackgroup: "one",
      fillcolor: `${color}55`,
      hovertemplate: `<b>${s.name}</b><br>%{x}<br>%{y:,.0f}<extra></extra>`,
    };
  });
  return <PlotlyChart
    traces={traces}
    layout={{ showlegend: true, legend: { x: 0, y: 1.12, orientation: "h", font: { size: 10.5, color: "#A6B4C8" } }, margin: { l: 44, r: 16, t: 30, b: 36 } }}
    height={height}
  />;
}

function DonutChart({ segments, height = 200 }) {
  const trace = {
    type: "pie",
    hole: 0.62,
    labels: segments.map(s => s.label),
    values: segments.map(s => s.value),
    marker: { colors: segments.map((_, i) => CHART_PALETTE[i % CHART_PALETTE.length]) },
    textinfo: "none",
    hovertemplate: "<b>%{label}</b><br>%{percent}<br>%{value:,.0f}<extra></extra>",
    sort: false,
  };
  return <PlotlyChart
    traces={[trace]}
    layout={{ margin: { l: 8, r: 8, t: 8, b: 8 }, showlegend: true, legend: { orientation: "v", x: 1, y: 0.5, font: { size: 10.5, color: "#A6B4C8" } } }}
    height={height}
  />;
}

Object.assign(window, {
  PlotlyChart, AreaChart, LineChart, BarChart, StackedAreaChart, DonutChart,
  CHART_PALETTE, CHART_LAYOUT_BASE,
});
