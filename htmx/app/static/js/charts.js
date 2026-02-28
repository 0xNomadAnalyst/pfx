(() => {
  const chartState = new Map();
  let protocolPairs = [];
  const FILTER_STORAGE_KEY = "dashboard.globalFilters.v1";
  const DETAIL_TABLE_CACHE_TTL_MS = 30_000;
  const PAGE_ACTION_CACHE_TTL_MS = 60_000;
  const detailTableCache = new Map();
  const pageActionCache = new Map();
  const comparableLiquidityWidgets = new Set([
    "liquidity-distribution",
    "liquidity-depth",
    "liquidity-change-heatmap",
  ]);
  const leftLinkedZoomWidgets = new Set([
    "liquidity-distribution",
    "liquidity-depth",
    "liquidity-change-heatmap",
  ]);
  const linkedTimeseriesGroups = new Map([
    ["linked-ts-right", new Set([
      "usdc-lp-flows",
      "usdc-pool-share-concentration",
      "trade-impact-toggle",
      "swaps-flows-toggle",
      "swaps-price-impacts",
      "swaps-spread-volatility",
      "swaps-ohlcv",
    ])],
    ["linked-ts-kamino", new Set([
      "kamino-utilization-timeseries",
      "kamino-ltv-hf-timeseries",
      "kamino-liability-flows",
      "kamino-liquidations",
    ])],
    ["linked-ts-exp-mkt1", new Set([
      "exponent-pt-swap-flows-mkt1",
      "exponent-token-strip-flows-mkt1",
      "exponent-vault-sy-balance-mkt1",
      "exponent-yt-staked-mkt1",
      "exponent-yield-trading-liq-mkt1",
      "exponent-realized-rates-mkt1",
      "exponent-divergence-mkt1",
    ])],
    ["linked-ts-exp-mkt2", new Set([
      "exponent-pt-swap-flows-mkt2",
      "exponent-token-strip-flows-mkt2",
      "exponent-vault-sy-balance-mkt2",
      "exponent-yt-staked-mkt2",
      "exponent-yield-trading-liq-mkt2",
      "exponent-realized-rates-mkt2",
      "exponent-divergence-mkt2",
    ])],
    ["linked-ts-health-base", new Set([
      "health-base-chart-events",
      "health-base-chart-accounts",
    ])],
  ]);

  function getTimeseriesGroupId(widgetId) {
    for (const [groupId, widgets] of linkedTimeseriesGroups) {
      if (widgets.has(widgetId)) return groupId;
    }
    return null;
  }
  const tickReferenceWidgets = new Set([
    "liquidity-distribution",
    "liquidity-depth",
    "liquidity-change-heatmap",
  ]);
  const linkedGroups = {
    left: "linked-zoom-left",
  };
  let leftDefaultZoomWindow = null;
  let leftDefaultZoomSignature = "";
  let modalInstance = null;
  let modalWidgetId = "";

  function palette() {
    const theme = document.documentElement.getAttribute("data-theme");
    if (theme === "light") {
      return ["#0a78f0", "#f39a2d", "#12a57a", "#9a54ff", "#e24c4c"];
    }
    return ["#4bb7ff", "#f8a94a", "#28c987", "#ae82ff", "#ff6e7a"];
  }

  function chartTextColor() {
    return getComputedStyle(document.documentElement).getPropertyValue("--text").trim() || "#d7def0";
  }

  function chartGridColor() {
    return getComputedStyle(document.documentElement).getPropertyValue("--border").trim() || "#20314d";
  }

  function chartLabelBadgeStyle() {
    const theme = document.documentElement.getAttribute("data-theme");
    if (theme === "light") {
      return {
        backgroundColor: "rgba(255, 255, 255, 0.9)",
        borderColor: "rgba(95, 115, 150, 0.55)",
      };
    }
    return {
      backgroundColor: "rgba(10, 16, 32, 0.65)",
      borderColor: "rgba(142, 161, 199, 0.45)",
    };
  }

  function currentPriceReferenceColor() {
    const theme = document.documentElement.getAttribute("data-theme");
    // Violet reads distinctly against blue series in both themes.
    return theme === "light" ? "#8f3dff" : "#c186ff";
  }

  function formatNumber(value) {
    if (value === null || value === undefined) {
      return "--";
    }
    const number = Number(value);
    if (!Number.isFinite(number)) {
      return String(value) || "--";
    }
    return number.toLocaleString(undefined, { maximumFractionDigits: 2 });
  }

  function formatSigned(value, suffix = "") {
    if (value === null || value === undefined || Number.isNaN(value)) {
      return "--";
    }
    const number = Number(value);
    const prefix = number > 0 ? "+" : "";
    return `${prefix}${number.toFixed(3)}${suffix}`;
  }

  function formatPrice4dp(value) {
    const numeric = Number(value);
    if (!Number.isFinite(numeric)) {
      return value;
    }
    return numeric.toFixed(4);
  }

  function formatBps2dp(value) {
    const numeric = Number(value);
    if (!Number.isFinite(numeric)) {
      return "--";
    }
    return `${numeric.toFixed(2)} bps`;
  }

  function formatCompactTimestamp(value) {
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      return String(value);
    }
    const month = String(date.getMonth() + 1).padStart(2, "0");
    const day = String(date.getDate()).padStart(2, "0");
    const hours = String(date.getHours()).padStart(2, "0");
    const minutes = String(date.getMinutes()).padStart(2, "0");
    return `${month}-${day} ${hours}:${minutes}`;
  }

  function parseIsoDate(value) {
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? null : date;
  }

  function applyLinkedTimeseriesFormat(option) {
    const hasRightAxis = Array.isArray(option.yAxis) && option.yAxis.length > 1;
    const hasRightLabel = hasRightAxis && !!option.yAxis[1].name;
    option.grid = { ...(option.grid || {}), left: 82, right: hasRightAxis ? (hasRightLabel ? 76 : 64) : 24, bottom: 60, containLabel: false };

    if (option.xAxis && !Array.isArray(option.xAxis)) {
      option.xAxis.axisLabel = {
        ...(option.xAxis.axisLabel || {}),
        formatter: (value) => formatCompactTimestamp(value),
      };
    }

    if (Array.isArray(option.yAxis)) {
      option.yAxis[0] = {
        ...option.yAxis[0],
        axisLabel: {
          ...(option.yAxis[0].axisLabel || {}),
          width: 62,
          align: "right",
          padding: [0, 8, 0, 0],
        },
      };
    } else if (option.yAxis) {
      option.yAxis = {
        ...option.yAxis,
        axisLabel: {
          ...(option.yAxis.axisLabel || {}),
          width: 62,
          align: "right",
          padding: [0, 8, 0, 0],
        },
      };
    }

    option.dataZoom = [
      { type: "inside", xAxisIndex: 0, filterMode: "none" },
      {
        type: "slider",
        xAxisIndex: 0,
        height: 12,
        bottom: 28,
        borderColor: chartGridColor(),
        brushSelect: false,
      },
    ];

    option.tooltip = {
      trigger: "axis",
      formatter: (params) => {
        const items = Array.isArray(params) ? params : [params];
        if (items.length === 0) return "";
        const header = formatCompactTimestamp(items[0].axisValue);
        const rows = items
          .map((item) => `${item.marker} ${item.seriesName}: ${formatNumber(item.value)}`)
          .join("<br/>");
        return `${header}<br/>${rows}`;
      },
    };
  }

  function trimIncompleteTailForTimeSeries(data) {
    if (!Array.isArray(data?.x) || data.x.length < 3 || !Array.isArray(data?.series)) {
      return data;
    }
    const xValues = data.x;
    const last = parseIsoDate(xValues[xValues.length - 1]);
    const prev = parseIsoDate(xValues[xValues.length - 2]);
    if (!last || !prev) {
      return data;
    }
    const intervalMs = last.getTime() - prev.getTime();
    if (!Number.isFinite(intervalMs) || intervalMs <= 0) {
      return data;
    }
    const nowMs = Date.now();
    // If the latest bucket is still within the currently-forming interval, drop it.
    if (nowMs - last.getTime() >= intervalMs) {
      return data;
    }
    return {
      ...data,
      x: xValues.slice(0, -1),
      series: data.series.map((series) => ({
        ...series,
        data: Array.isArray(series.data) ? series.data.slice(0, -1) : series.data,
      })),
    };
  }

  function windowMsFromLastWindow(lastWindow) {
    const key = String(lastWindow || "").toLowerCase();
    const mapping = {
      "1h": 60 * 60 * 1000,
      "4h": 4 * 60 * 60 * 1000,
      "6h": 6 * 60 * 60 * 1000,
      "24h": 24 * 60 * 60 * 1000,
      "7d": 7 * 24 * 60 * 60 * 1000,
      "30d": 30 * 24 * 60 * 60 * 1000,
      "90d": 90 * 24 * 60 * 60 * 1000,
    };
    return mapping[key] || mapping["24h"];
  }

  function trimOhlcvToLastWindow(data, lastWindow) {
    if (!Array.isArray(data?.x) || data.x.length === 0) {
      return data;
    }
    const xValues = data.x;
    const lastDate = parseIsoDate(xValues[xValues.length - 1]);
    if (!lastDate) {
      return data;
    }
    const cutoffMs = lastDate.getTime() - windowMsFromLastWindow(lastWindow);
    let startIdx = 0;
    for (let i = 0; i < xValues.length; i += 1) {
      const date = parseIsoDate(xValues[i]);
      if (date && date.getTime() >= cutoffMs) {
        startIdx = i;
        break;
      }
    }
    return {
      ...data,
      x: xValues.slice(startIdx),
      candles: Array.isArray(data.candles) ? data.candles.slice(startIdx) : data.candles,
      volume: Array.isArray(data.volume) ? data.volume.slice(startIdx) : data.volume,
    };
  }

  function formatCompactMagnitude(value) {
    const numeric = Number(value);
    if (!Number.isFinite(numeric)) {
      return "";
    }
    const absValue = Math.abs(numeric);
    if (absValue >= 1_000_000_000) {
      return `${(numeric / 1_000_000_000).toFixed(1)}b`;
    }
    if (absValue >= 1_000_000) {
      return `${(numeric / 1_000_000).toFixed(1)}m`;
    }
    if (absValue >= 1_000) {
      return `${(numeric / 1_000).toFixed(0)}k`;
    }
    return Math.round(numeric).toString();
  }

  function currentPairTokens() {
    const pair = currentPair();
    const parts = String(pair || "").split("-");
    return {
      token0: (parts[0] || "T0").trim(),
      token1: (parts[1] || "T1").trim(),
    };
  }

  function pairAwareLabel(text) {
    if (text === null || text === undefined) {
      return text;
    }
    const { token0, token1 } = currentPairTokens();
    return String(text).replace(/\bUSX\b/g, token0).replace(/\bUSDC\b/g, token1);
  }

  function xAxisSignature(data) {
    const xValues = Array.isArray(data?.x) ? data.x : [];
    if (xValues.length === 0) {
      return "";
    }
    return `${xValues.length}|${String(xValues[0])}|${String(xValues[xValues.length - 1])}`;
  }

  function computeFocusedZoomWindow(widgetId, data) {
    const xValues = data?.x || [];
    const n = Array.isArray(xValues) ? xValues.length : 0;
    if (n < 8) {
      return null;
    }

    const intensity = Array.from({ length: n }, () => 0);
    if (widgetId === "liquidity-change-heatmap" && Array.isArray(data?.points)) {
      data.points.forEach((point) => {
        const idx = Number(point?.[0]);
        const value = Math.abs(Number(point?.[2]));
        if (Number.isFinite(idx) && idx >= 0 && idx < n && Number.isFinite(value)) {
          intensity[idx] += value;
        }
      });
    } else if (Array.isArray(data?.series)) {
      data.series.forEach((series) => {
        const values = Array.isArray(series?.data) ? series.data : [];
        for (let i = 0; i < Math.min(values.length, n); i += 1) {
          const numeric = Math.abs(Number(values[i]));
          if (Number.isFinite(numeric)) {
            intensity[i] += numeric;
          }
        }
      });
    }

    const total = intensity.reduce((sum, value) => sum + value, 0);
    if (total <= 0) {
      return { start: 20, end: 80 };
    }

    const lowerTarget = total * 0.02;
    const upperTarget = total * 0.98;
    let cumulative = 0;
    let lowIdx = 0;
    let highIdx = n - 1;

    for (let i = 0; i < n; i += 1) {
      cumulative += intensity[i];
      if (cumulative >= lowerTarget) {
        lowIdx = i;
        break;
      }
    }

    cumulative = 0;
    for (let i = 0; i < n; i += 1) {
      cumulative += intensity[i];
      if (cumulative >= upperTarget) {
        highIdx = i;
        break;
      }
    }

    const indexPad = Math.max(2, Math.round(n * 0.04));
    lowIdx = Math.max(0, lowIdx - indexPad);
    highIdx = Math.min(n - 1, highIdx + indexPad);

    let start = (lowIdx / (n - 1)) * 100;
    let end = (highIdx / (n - 1)) * 100;
    const width = end - start;
    const minWidth = 22;
    if (width < minWidth) {
      const extra = (minWidth - width) / 2;
      start = Math.max(0, start - extra);
      end = Math.min(100, end + extra);
    }
    if (end - start > 92) {
      return { start: 4, end: 96 };
    }
    return { start, end };
  }

  function nearestCategoryIndex(xValues, target) {
    const numericTarget = Number(target);
    if (!Number.isFinite(numericTarget) || !Array.isArray(xValues) || xValues.length === 0) {
      return null;
    }
    let bestIndex = 0;
    let bestDistance = Number.POSITIVE_INFINITY;
    for (let i = 0; i < xValues.length; i += 1) {
      const numeric = Number(xValues[i]);
      if (!Number.isFinite(numeric)) {
        continue;
      }
      const distance = Math.abs(numeric - numericTarget);
      if (distance < bestDistance) {
        bestDistance = distance;
        bestIndex = i;
      }
    }
    return bestIndex;
  }

  function buildTickReferenceMarkLine(data) {
    const refs = data?.reference_lines || {};
    const xValues = Array.isArray(data?.x) ? data.x : [];
    if (xValues.length === 0) {
      return null;
    }

    const lines = [];
    const pegValue = Number(refs.peg);
    let pegIndex = null;
    if (Number.isFinite(pegValue)) {
      pegIndex = nearestCategoryIndex(xValues, pegValue);
      if (pegIndex !== null) {
        lines.push({
          kind: "peg",
          name: "Peg",
          xAxis: pegIndex,
          lineStyle: { color: "#ffe45c", type: "dotted", width: 2, opacity: 0.98 },
        });
      }
    }

    const currentPrice = Number(refs.current_price);
    let currentIndex = null;
    if (Number.isFinite(currentPrice)) {
      currentIndex = nearestCategoryIndex(xValues, currentPrice);
      if (currentIndex !== null) {
        lines.push({
          kind: "current",
          name: formatPrice4dp(currentPrice),
          xAxis: currentIndex,
          lineStyle: { color: currentPriceReferenceColor(), type: "dotted", width: 2, opacity: 0.95 },
        });
      }
    }

    if (lines.length === 0) {
      return null;
    }

    const labelsAreClose =
      Number.isInteger(pegIndex) && Number.isInteger(currentIndex) && Math.abs(pegIndex - currentIndex) <= 4;
    if (labelsAreClose) {
      const pegOnRight = pegIndex > currentIndex;
      const badgeStyle = chartLabelBadgeStyle();
      lines.forEach((line) => {
        const isPeg = line.kind === "peg";
        const placeRight = isPeg ? pegOnRight : !pegOnRight;
        line.label = {
          show: true,
          position: "end",
          rotate: 0,
          align: placeRight ? "left" : "right",
          verticalAlign: "top",
          offset: placeRight ? [8, 2] : [-8, 2],
          color: chartTextColor(),
          fontSize: 11,
          backgroundColor: badgeStyle.backgroundColor,
          borderColor: badgeStyle.borderColor,
          borderWidth: 1,
          padding: [1, 4],
          borderRadius: 3,
        };
      });
    }

    const defaultBadgeStyle = chartLabelBadgeStyle();
    return {
      silent: true,
      animation: false,
      symbol: ["none", "none"],
      label: {
        show: true,
        formatter: (params) => params.name || "",
        position: "end",
        rotate: 0,
        align: "center",
        verticalAlign: "top",
        offset: [0, 2],
        color: chartTextColor(),
        fontSize: 11,
        backgroundColor: defaultBadgeStyle.backgroundColor,
        borderColor: defaultBadgeStyle.borderColor,
        borderWidth: 1,
        padding: [1, 4],
        borderRadius: 3,
      },
      z: 20,
      data: lines,
    };
  }

  function autoSizeKpi(el) {
    if (!el) return;
    const text = el.textContent || "";
    const valueCount = text.split(" / ").length;
    if (valueCount <= 1) el.style.fontSize = "28px";
    else if (valueCount <= 2) el.style.fontSize = "22px";
    else el.style.fontSize = "16px";
  }

  function renderKpi(widgetId, data) {
    const primary = document.getElementById(`kpi-primary-${widgetId}`);
    const secondary = document.getElementById(`kpi-secondary-${widgetId}`);
    if (!primary || !secondary) {
      return;
    }

    if (widgetId === "kpi-impact-500k" || widgetId === "kpi-largest-impact" || widgetId === "kpi-average-impact") {
      primary.textContent = `${formatSigned(data.primary, " bps")}`;
      secondary.textContent = data.secondary ? `Size: ${formatNumber(data.secondary)}` : "";
    } else if (widgetId === "kpi-pool-balance") {
      primary.textContent = `${formatNumber(data.primary)}%`;
      secondary.textContent = `${formatNumber(data.secondary)}%`;
    } else if (widgetId === "kpi-reserves") {
      primary.textContent = `${formatNumber(data.primary)}m`;
      secondary.textContent = `${formatNumber(data.secondary)}m`;
    } else if (widgetId === "kpi-price-min-max") {
      const minValue = Number(data.primary);
      const maxValue = Number(data.secondary);
      primary.textContent = `${Number.isFinite(minValue) ? minValue.toFixed(4) : "--"} / ${Number.isFinite(maxValue) ? maxValue.toFixed(4) : "--"}`;
      secondary.textContent = "min / max";
    } else if (widgetId === "kpi-vwap-buy-sell") {
      const buy = Number(data.primary);
      const sell = Number(data.secondary);
      primary.textContent = `${Number.isFinite(buy) ? buy.toFixed(4) : "--"} / ${Number.isFinite(sell) ? sell.toFixed(4) : "--"}`;
      secondary.textContent = "buy / sell";
    } else if (widgetId === "kpi-vwap-spread") {
      primary.textContent = formatBps2dp(data.primary);
      secondary.textContent = "";
    } else if (
      widgetId === "kpi-largest-usx-sell" ||
      widgetId === "kpi-largest-usx-buy" ||
      widgetId === "kpi-max-1h-sell-pressure" ||
      widgetId === "kpi-max-1h-buy-pressure"
    ) {
      primary.textContent = formatNumber(data.primary);
      secondary.textContent = `Est impact: ${formatBps2dp(data.secondary)}`;
    } else {
      primary.textContent = formatNumber(data.primary);
      secondary.textContent = data.secondary ? formatNumber(data.secondary) : "";
    }

    autoSizeKpi(primary);
  }

  function normalizeColumns(widgetId, columns) {
    if (widgetId !== "liquidity-depth-table") {
      return columns;
    }
    return columns.map((column) => {
      if (column.key === "bps_target") {
        return { ...column, label: "Δ (bps)" };
      }
      if (column.key === "price_change_pct") {
        return { ...column, label: "Δ (%)" };
      }
      return column;
    });
  }

  function formatDepthTableValue(columnKey, value) {
    if (value === null || value === undefined || value === "") {
      return "";
    }
    const numeric = Number(value);
    if (!Number.isFinite(numeric)) {
      return String(value);
    }
    if (columnKey === "liquidity_in_band" || columnKey === "swap_size_equivalent") {
      return numeric.toLocaleString(undefined, { maximumFractionDigits: 0 });
    }
    if (columnKey === "pct_of_reserve") {
      return numeric.toLocaleString(undefined, { maximumFractionDigits: 0 });
    }
    return String(value);
  }

  function renderTable(widgetId, targetId, columns, rows) {
    const target = document.getElementById(targetId);
    if (!target) {
      return;
    }
    if (!Array.isArray(rows) || rows.length === 0) {
      target.innerHTML = "<div class='kpi-secondary'>No rows returned</div>";
      return;
    }

    const isHealthTable = widgetId.startsWith("health-");
    const normalizedColumns = normalizeColumns(widgetId, columns);
    const visibleColumns = normalizedColumns.filter((c) => c.key !== "is_red");
    const header = visibleColumns.map((column) => `<th>${pairAwareLabel(column.label)}</th>`).join("");
    const body = rows
      .map((row) => {
        const rowClass = isHealthTable && row.is_red ? ' class="health-row-red"' : "";
        const cells = visibleColumns
          .map((column) => {
            const raw = row[column.key];
            const value = widgetId === "liquidity-depth-table" ? formatDepthTableValue(column.key, raw) : (raw ?? "");
            const displayValue = typeof value === "string" ? pairAwareLabel(value) : value;
            return `<td>${displayValue}</td>`;
          })
          .join("");
        return `<tr${rowClass}>${cells}</tr>`;
      })
      .join("");
    target.innerHTML = `<table><thead><tr>${header}</tr></thead><tbody>${body}</tbody></table>`;
  }

  function renderHealthInfoToggle(widgetId, info) {
    const container = document.getElementById(`info-toggle-${widgetId}`);
    if (!container || !info || !info.content) return;
    const storageKey = `health-info-${info.key}`;
    const stored = localStorage.getItem(storageKey);
    const isOpen = stored === null ? true : stored === "true";
    container.innerHTML =
      `<button class="health-info-toggle-btn" type="button" aria-label="Toggle information">` +
      `<svg width="14" height="14" viewBox="0 0 16 16" fill="none"><circle cx="8" cy="8" r="7" stroke="currentColor" stroke-width="1.3"/><text x="8" y="12" text-anchor="middle" fill="currentColor" font-size="11" font-weight="600">i</text></svg>` +
      `<span>${isOpen ? "Hide" : "Show"} information</span>` +
      `<svg class="chevron ${isOpen ? "open" : ""}" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="6 9 12 15 18 9"/></svg>` +
      `</button>` +
      `<div class="health-info-content"${isOpen ? "" : " hidden"}>${info.content}</div>`;
    const btn = container.querySelector(".health-info-toggle-btn");
    btn.addEventListener("click", () => {
      const content = container.querySelector(".health-info-content");
      const chevron = container.querySelector(".chevron");
      const label = btn.querySelector("span");
      const nowOpen = content.hidden;
      content.hidden = !nowOpen;
      chevron.classList.toggle("open", nowOpen);
      label.textContent = nowOpen ? "Hide information" : "Show information";
      localStorage.setItem(storageKey, String(nowOpen));
    });
  }

  function modalElements() {
    return {
      backdrop: document.getElementById("chart-modal-backdrop"),
      title: document.getElementById("chart-modal-title"),
      canvas: document.getElementById("chart-modal-canvas"),
    };
  }

  function ensureModalMarkup() {
    if (document.getElementById("chart-modal-backdrop")) {
      return;
    }
    const host = document.createElement("div");
    host.id = "chart-modal-backdrop";
    host.className = "chart-modal-backdrop";
    host.hidden = true;
    host.innerHTML = `
      <section class="chart-modal" role="dialog" aria-modal="true" aria-labelledby="chart-modal-title">
        <div class="chart-modal-header">
          <h3 id="chart-modal-title">Chart</h3>
          <button id="chart-modal-close" class="action-button" type="button" aria-label="Close expanded chart">Close</button>
        </div>
        <div class="chart-modal-body">
          <div id="chart-modal-canvas" class="chart-modal-canvas"></div>
        </div>
      </section>
    `;
    document.body.appendChild(host);
  }

  function ensureModalChart() {
    const { canvas } = modalElements();
    if (!canvas) {
      return null;
    }
    if (!modalInstance) {
      modalInstance = echarts.init(canvas);
    }
    return modalInstance;
  }

  function closeChartModal() {
    const { backdrop } = modalElements();
    if (!backdrop) {
      return;
    }
    backdrop.hidden = true;
    modalWidgetId = "";
    document.body.style.overflow = "";
  }

  function syncModalChart() {
    if (!modalWidgetId || !modalInstance) {
      return;
    }
    const source = chartState.get(modalWidgetId);
    if (!source?.instance) {
      return;
    }
    const sourceOption = source.instance.getOption();
    modalInstance.setOption(sourceOption, true);
    modalInstance.resize();
  }

  function openChartModal(widgetId) {
    if (!widgetId) {
      return;
    }
    ensureModalMarkup();
    const source = chartState.get(widgetId);
    if (!source?.instance) {
      return;
    }
    const { backdrop, title } = modalElements();
    const chart = ensureModalChart();
    if (!backdrop || !chart) {
      return;
    }
    const titleEl = document.querySelector(`#widget-${widgetId} .panel-header h3`);
    if (title && titleEl) {
      title.textContent = titleEl.textContent || "Chart";
    }
    modalWidgetId = widgetId;
    backdrop.hidden = false;
    document.body.style.overflow = "hidden";
    syncModalChart();
  }

  /* ── Detail-table modal (fetches table data and renders inside a modal) ── */

  function ensureTableModalMarkup() {
    if (document.getElementById("table-modal-backdrop")) return;
    const host = document.createElement("div");
    host.id = "table-modal-backdrop";
    host.className = "table-modal-backdrop";
    host.hidden = true;
    host.innerHTML = `
      <section class="table-modal" role="dialog" aria-modal="true" aria-labelledby="table-modal-title">
        <div class="table-modal-header">
          <h3 id="table-modal-title">Detail</h3>
          <button id="table-modal-close" class="action-button" type="button" aria-label="Close detail table">Close</button>
        </div>
        <div class="table-modal-body">
          <div id="table-modal-content" class="table-wrap"></div>
        </div>
      </section>
    `;
    document.body.appendChild(host);
    host.addEventListener("click", (e) => {
      if (e.target === host) closeTableModal();
    });
    document.getElementById("table-modal-close").addEventListener("click", closeTableModal);
  }

  function closeTableModal() {
    const backdrop = document.getElementById("table-modal-backdrop");
    if (backdrop) {
      backdrop.hidden = true;
      document.body.style.overflow = "";
    }
  }

  function openDetailTable(widgetId) {
    const widget = document.getElementById(`widget-${widgetId}`);
    if (!widget) return;
    const endpoint = widget.dataset.detailTableEndpoint;
    if (!endpoint) return;

    ensureTableModalMarkup();
    const backdrop = document.getElementById("table-modal-backdrop");
    const titleEl = document.getElementById("table-modal-title");
    const contentEl = document.getElementById("table-modal-content");
    const chartTitle = widget.querySelector(".panel-header h3");
    if (titleEl) titleEl.textContent = (chartTitle?.textContent || "Detail") + " — Full Detail";
    if (contentEl) contentEl.innerHTML = "<div class='kpi-secondary'>Loading…</div>";
    backdrop.hidden = false;
    document.body.style.overflow = "hidden";

    const url = new URL(endpoint, window.location.origin);
    url.searchParams.set("protocol", currentProtocol());
    url.searchParams.set("pair", currentPair());
    url.searchParams.set("last_window", currentLastWindow());
    const m1 = currentMkt1();
    const m2 = currentMkt2();
    if (m1) url.searchParams.set("mkt1", m1);
    if (m2) url.searchParams.set("mkt2", m2);
    const cacheKey = url.toString();
    const cached = detailTableCache.get(cacheKey);
    if (cached && cached.expiresAt > Date.now()) {
      renderTable("detail-modal", "table-modal-content", cached.columns || [], cached.rows || []);
      return;
    }

    fetch(url)
      .then((r) => r.json())
      .then((payload) => {
        if (payload.status !== "success" || payload.data?.kind !== "table") {
          contentEl.innerHTML = "<div class='kpi-secondary'>Failed to load table</div>";
          return;
        }
        detailTableCache.set(cacheKey, {
          expiresAt: Date.now() + DETAIL_TABLE_CACHE_TTL_MS,
          columns: payload.data.columns || [],
          rows: payload.data.rows || [],
        });
        renderTable("detail-modal", "table-modal-content", payload.data.columns || [], payload.data.rows || []);
      })
      .catch(() => {
        contentEl.innerHTML = "<div class='kpi-secondary'>Failed to load table</div>";
      });
  }

  function hasDualAxis(data) {
    return (data.series || []).some((s) => s.yAxisIndex === 1);
  }

  function axisFormatter(fmt) {
    if (fmt === "pct0") return (v) => { const n = Number(v); return Number.isFinite(n) ? Math.round(n) + "%" : v; };
    if (fmt === "pct1") return (v) => { const n = Number(v); return Number.isFinite(n) ? n.toFixed(1) + "%" : v; };
    if (fmt === "compact") return (v) => {
      const n = Number(v);
      if (!Number.isFinite(n)) return v;
      if (Math.abs(n) >= 1e9) return (n / 1e9).toFixed(1) + "B";
      if (Math.abs(n) >= 1e6) return (n / 1e6).toFixed(1) + "M";
      if (Math.abs(n) >= 1e3) return (n / 1e3).toFixed(1) + "k";
      return n.toFixed(0);
    };
    return null;
  }

  function baseChartOption(data) {
    const xFmt = axisFormatter(data.xAxisFormat);
    const yFmt = axisFormatter(data.yAxisFormat);
    const xLabel = pairAwareLabel(data.xAxisLabel) || "";
    const yLabel = pairAwareLabel(data.yAxisLabel) || "";
    const yRightLabel = pairAwareLabel(data.yRightAxisLabel) || "";
    const hasXLabel = !!xLabel;
    const hasYLabel = !!yLabel;
    const hasYRightLabel = !!yRightLabel;
    const dual = hasDualAxis(data);
    const rightPad = dual ? (hasYRightLabel ? 60 : 50) : 18;
    const option = {
      color: palette(),
      tooltip: { trigger: "axis" },
      legend: { bottom: 2, textStyle: { color: chartTextColor() } },
      grid: { left: hasYLabel ? 55 : 40, right: rightPad, top: 22, bottom: hasXLabel ? 72 : 60, containLabel: true },
      xAxis: {
        type: "category",
        data: data.x || [],
        name: xLabel || undefined,
        nameLocation: "middle",
        nameGap: hasXLabel ? 36 : undefined,
        nameTextStyle: hasXLabel ? { color: chartTextColor(), fontSize: 12 } : undefined,
        axisLine: { lineStyle: { color: chartGridColor() } },
        axisLabel: {
          color: chartTextColor(),
          fontSize: 11,
          margin: 8,
          formatter: xFmt || ((value) => formatPrice4dp(value)),
          hideOverlap: true,
        },
      },
      yAxis: hasDualAxis(data) ? [
        {
          type: "value",
          name: yLabel || undefined,
          nameLocation: "middle",
          nameGap: hasYLabel ? 42 : undefined,
          nameTextStyle: hasYLabel ? { color: chartTextColor(), fontSize: 12 } : undefined,
          axisLine: { lineStyle: { color: chartGridColor() } },
          splitLine: { lineStyle: { color: chartGridColor() } },
          axisLabel: { color: chartTextColor(), fontSize: 11, formatter: yFmt || undefined },
        },
        {
          type: "value",
          name: yRightLabel || undefined,
          nameLocation: "middle",
          nameGap: hasYRightLabel ? 36 : undefined,
          nameTextStyle: hasYRightLabel ? { color: chartTextColor(), fontSize: 12 } : undefined,
          axisLine: { lineStyle: { color: chartGridColor() } },
          splitLine: { show: false },
          axisLabel: { color: chartTextColor(), fontSize: 11, formatter: axisFormatter(data.yRightAxisFormat) || undefined },
        },
      ] : {
        type: "value",
        name: yLabel || undefined,
        nameLocation: "middle",
        nameGap: hasYLabel ? 42 : undefined,
        nameTextStyle: hasYLabel ? { color: chartTextColor(), fontSize: 12 } : undefined,
        axisLine: { lineStyle: { color: chartGridColor() } },
        splitLine: { lineStyle: { color: chartGridColor() } },
        axisLabel: {
          color: chartTextColor(),
          fontSize: 11,
          formatter: yFmt || undefined,
        },
      },
      series: (data.series || []).map((series) => {
        const mapped = {
          name: pairAwareLabel(series.name),
          type: series.type || "line",
          data: series.data || [],
          showSymbol: series.showSymbol ?? false,
          smooth: series.smooth ?? false,
        };
        if (series.symbolSize !== undefined) {
          mapped.symbolSize = series.symbolSize;
        }
        if (series.yAxisIndex !== undefined) {
          mapped.yAxisIndex = series.yAxisIndex;
        }
        if (series.stack !== undefined) {
          mapped.stack = series.stack;
        }
        if (series.barWidth !== undefined) {
          mapped.barWidth = series.barWidth;
        }
        if (series.barMaxWidth !== undefined) {
          mapped.barMaxWidth = series.barMaxWidth;
        }
        if (series.connectNulls !== undefined) {
          mapped.connectNulls = Boolean(series.connectNulls);
        }
        if (series.color) {
          mapped.itemStyle = { color: series.color };
          mapped.lineStyle = { color: series.color };
        }
        if (series.lineStyle === "dashed") {
          mapped.lineStyle = { ...(mapped.lineStyle || {}), type: "dashed" };
        }
        if (series.area) {
          mapped.areaStyle = { opacity: 0.2 };
        }
        return mapped;
      })
    };
    if (data.yAxisMin !== undefined || data.yAxisMax !== undefined) {
      const target = Array.isArray(option.yAxis) ? option.yAxis[0] : option.yAxis;
      if (data.yAxisMin !== undefined) target.min = data.yAxisMin;
      if (data.yAxisMax !== undefined) target.max = data.yAxisMax;
    }
    if (Array.isArray(data.mark_lines) && data.mark_lines.length > 0 && option.series.length > 0) {
      const xLabels = (data.x || []).map(String);
      const isDark = document.documentElement.getAttribute("data-theme") !== "light";
      const labelBg = isDark ? "rgba(0,0,0,0.65)" : "rgba(255,255,255,0.85)";
      option.series[0].markLine = {
        silent: true,
        symbol: "none",
        data: data.mark_lines.map((ml) => {
          const closest = xLabels.reduce((best, lbl, idx) => {
            const diff = Math.abs(parseFloat(lbl) - ml.value);
            return diff < best.diff ? { idx, diff } : best;
          }, { idx: 0, diff: Infinity });
          return {
            xAxis: closest.idx,
            lineStyle: { type: "dashed", color: ml.color || "#aaa", width: 2 },
            label: {
              show: true,
              formatter: ml.label,
              position: "end",
              color: ml.color || "#aaa",
              fontSize: 12,
              fontWeight: "bold",
              backgroundColor: labelBg,
              padding: [3, 6],
              borderRadius: 3,
            },
          };
        }),
      };
    }
    return option;
  }

  function renderChart(widgetId, data) {
    const el = document.getElementById(`chart-${widgetId}`);
    if (!el) {
      return;
    }

    let instance = chartState.get(widgetId)?.instance;
    if (!instance) {
      instance = echarts.init(el);
    }

    if (!el.dataset.modalClickBound) {
      el.addEventListener(
        "click",
        () => {
          const widgetEl = document.getElementById(`widget-${widgetId}`);
          if (!widgetEl || widgetEl.dataset.expandable !== "true") {
            return;
          }
          openChartModal(widgetId);
        },
        true
      );
      el.dataset.modalClickBound = "1";
    }

    const isLeftLinked = leftLinkedZoomWidgets.has(widgetId);
    if (isLeftLinked) {
      const signature = xAxisSignature(data);
      if (signature && signature !== leftDefaultZoomSignature) {
        leftDefaultZoomWindow = computeFocusedZoomWindow(widgetId, data);
        leftDefaultZoomSignature = signature;
      } else if (!leftDefaultZoomWindow) {
        leftDefaultZoomWindow = computeFocusedZoomWindow(widgetId, data);
      }
    }

    let chartData = data;
    if (widgetId === "swaps-flows-toggle") {
      chartData = trimIncompleteTailForTimeSeries(chartData);
    }
    if (widgetId === "swaps-ohlcv") {
      chartData = trimOhlcvToLastWindow(chartData, currentLastWindow());
    }

    let option;
    const focusedTickZoom = isLeftLinked ? leftDefaultZoomWindow : null;
    if (chartData.chart === "candlestick-volume") {
      const xValues = chartData.x || [];
      const candleData = chartData.candles || [];
      const volumeData = chartData.volume || [];
      const liquidityProfileRaw = Array.isArray(chartData.liquidity_profile) ? chartData.liquidity_profile : [];
      const liquidityProfile = liquidityProfileRaw
        .map((row) => ({
          price: Number(row?.price),
          liquidity: Number(row?.liquidity),
          // Keep linear scaling so profile shape matches source distribution.
          scaledLiquidity: Math.max(Number(row?.liquidity) || 0, 0),
        }))
        .filter(
          (row) =>
            Number.isFinite(row.price) &&
            Number.isFinite(row.liquidity) &&
            row.liquidity > 0
        );
      const profilePrices = Array.from(new Set(liquidityProfile.map((row) => row.price))).sort((a, b) => a - b);
      let profilePriceStep = 0;
      if (profilePrices.length > 1) {
        const diffs = [];
        for (let i = 1; i < profilePrices.length; i += 1) {
          const diff = profilePrices[i] - profilePrices[i - 1];
          if (Number.isFinite(diff) && diff > 0) {
            diffs.push(diff);
          }
        }
        if (diffs.length > 0) {
          diffs.sort((a, b) => a - b);
          profilePriceStep = diffs[Math.floor(diffs.length / 2)];
        }
      }
      const profileMax = liquidityProfile.reduce((maxValue, row) => Math.max(maxValue, row.scaledLiquidity), 0);
      const profileColor = "rgba(142, 161, 199, 0.16)";
      option = {
        color: palette(),
        legend: {
          data: ["OHLC", "Volume"],
          bottom: 2,
          textStyle: { color: chartTextColor() },
        },
        tooltip: {
          trigger: "axis",
          axisPointer: { type: "cross" },
          formatter: (params) => {
            const items = Array.isArray(params) ? params : [params];
            if (items.length === 0) {
              return "";
            }
            const header = formatCompactTimestamp(items[0].axisValue);
            const rows = items
              .map((item) => {
                if (Array.isArray(item.value) && item.value.length >= 4) {
                  const [open, close, low, high] = item.value;
                  return `${item.marker} ${item.seriesName}: O ${formatNumber(open)} C ${formatNumber(close)} L ${formatNumber(low)} H ${formatNumber(high)}`;
                }
                return `${item.marker} ${item.seriesName}: ${formatNumber(item.value)}`;
              })
              .join("<br/>");
            return `${header}<br/>${rows}`;
          },
        },
        grid: [
          { left: 82, right: 88, top: 14, height: "56%", containLabel: false },
          { left: 82, right: 88, top: "74%", height: "12%", containLabel: false },
        ],
        xAxis: [
          {
            type: "category",
            data: xValues,
            boundaryGap: false,
            axisLine: { lineStyle: { color: chartGridColor() } },
            axisLabel: { show: false },
            axisTick: { show: false },
          },
          {
            type: "category",
            gridIndex: 1,
            data: xValues,
            boundaryGap: false,
            axisLine: { lineStyle: { color: chartGridColor() } },
            axisLabel: {
              color: chartTextColor(),
              fontSize: 11,
              formatter: (value) => formatCompactTimestamp(value),
              hideOverlap: true,
            },
            axisTick: { show: false },
          },
          {
            type: "value",
            gridIndex: 0,
            min: 0,
            max: profileMax > 0 ? profileMax * 1.05 : 1,
            inverse: true,
            show: false,
          },
        ],
        yAxis: [
          {
            type: "value",
            scale: true,
            position: "right",
            axisLine: { lineStyle: { color: chartGridColor() } },
            splitLine: { lineStyle: { color: chartGridColor() } },
            axisLabel: {
              color: chartTextColor(),
              width: 62,
              align: "left",
              padding: [0, 0, 0, 8],
              margin: 10,
              inside: false,
              formatter: (v) => Number(v).toFixed(4),
            },
          },
          {
            type: "value",
            gridIndex: 1,
            scale: true,
            position: "right",
            splitNumber: 3,
            axisLine: { lineStyle: { color: chartGridColor() } },
            splitLine: { show: false },
            axisTick: { show: false },
            axisLabel: {
              color: chartTextColor(),
              width: 62,
              align: "left",
              padding: [0, 0, 0, 8],
              margin: 10,
              inside: false,
              formatter: (v) => formatCompactMagnitude(v),
            },
          },
        ],
        dataZoom: [
          {
            type: "inside",
            xAxisIndex: [0, 1],
            filterMode: "none",
          },
          {
            type: "slider",
            xAxisIndex: [0, 1],
            height: 12,
            bottom: 28,
            borderColor: chartGridColor(),
            brushSelect: false,
          },
          {
            type: "inside",
            yAxisIndex: 0,
            filterMode: "none",
          },
        ],
        series: [
          ...(liquidityProfile.length > 0
            ? [
                {
                  name: "Liquidity Profile",
                  type: "custom",
                  xAxisIndex: 2,
                  yAxisIndex: 0,
                  silent: true,
                  z: 1,
                  tooltip: { show: false },
                  renderItem: (params, api) => {
                    const scaledLiquidity = Number(api.value(0));
                    const price = Number(api.value(1));
                    if (!Number.isFinite(scaledLiquidity) || !Number.isFinite(price) || scaledLiquidity <= 0) {
                      return null;
                    }
                    const rightEdge = api.coord([0, price]);
                    const leftEdge = api.coord([scaledLiquidity, price]);
                    const x = Math.min(leftEdge[0], rightEdge[0]);
                    const width = Math.abs(rightEdge[0] - leftEdge[0]);
                    if (!Number.isFinite(x) || !Number.isFinite(width) || width <= 0) {
                      return null;
                    }
                    let barHeight = 2.5;
                    if (profilePriceStep > 0) {
                      const y0 = api.coord([0, price])[1];
                      const y1 = api.coord([0, price + profilePriceStep])[1];
                      const stepPx = Math.abs(y1 - y0);
                      if (Number.isFinite(stepPx) && stepPx > 0) {
                        barHeight = Math.max(2.5, Math.min(12, stepPx * 0.72));
                      }
                    }
                    return {
                      type: "rect",
                      shape: {
                        x,
                        y: rightEdge[1] - barHeight / 2,
                        width,
                        height: barHeight,
                      },
                      style: {
                        fill: profileColor,
                      },
                      silent: true,
                    };
                  },
                  data: liquidityProfile.map((row) => [row.scaledLiquidity, row.price]),
                },
              ]
            : []),
          {
            name: "OHLC",
            type: "candlestick",
            data: candleData,
            z: 3,
            itemStyle: {
              color: "#2fbf71",
              color0: "#e24c4c",
              borderColor: "#2fbf71",
              borderColor0: "#e24c4c",
            },
          },
          {
            name: "Volume",
            type: "bar",
            xAxisIndex: 1,
            yAxisIndex: 1,
            data: volumeData,
            itemStyle: { color: "#4bb7ff" },
            barMaxWidth: 8,
            z: 2,
          },
        ],
      };
    } else if (chartData.chart === "bar-line-dual") {
      option = {
        color: palette(),
        tooltip: { trigger: "axis" },
        legend: { bottom: 2, textStyle: { color: chartTextColor() } },
        grid: { left: 60, right: 40, top: 22, bottom: 60, containLabel: true },
        xAxis: {
          type: "category",
          data: chartData.x || [],
          axisLine: { lineStyle: { color: chartGridColor() } },
          axisLabel: { show: false },
        },
        yAxis: [
          {
            type: "value",
            name: pairAwareLabel(chartData.yLeftLabel) || "",
            nameLocation: "middle",
            nameGap: 50,
            nameTextStyle: { color: chartTextColor(), fontSize: 11 },
            axisLine: { lineStyle: { color: chartGridColor() } },
            splitLine: { lineStyle: { color: chartGridColor() } },
            axisLabel: {
              color: chartTextColor(),
              fontSize: 11,
              formatter: (v) => {
                if (Math.abs(v) >= 1e6) return "$" + (v / 1e6).toFixed(1) + "M";
                if (Math.abs(v) >= 1e3) return "$" + (v / 1e3).toFixed(0) + "k";
                return "$" + v;
              },
            },
          },
          {
            type: "value",
            name: pairAwareLabel(chartData.yRightLabel) || "",
            nameLocation: "middle",
            nameGap: 30,
            nameTextStyle: { color: chartTextColor(), fontSize: 11 },
            axisLine: { lineStyle: { color: chartGridColor() } },
            splitLine: { show: false },
            axisLabel: {
              color: chartTextColor(),
              fontSize: 11,
              formatter: (v) => Number(v).toFixed(1),
            },
          },
        ],
        series: (chartData.series || []).map((s) => {
          const mapped = {
            name: s.name,
            type: s.type || "bar",
            yAxisIndex: s.yAxisIndex || 0,
            data: s.data || [],
            showSymbol: s.showSymbol ?? false,
            smooth: s.smooth ?? false,
          };
          if (s.color) {
            mapped.itemStyle = { color: s.color };
            if (s.type === "line") mapped.lineStyle = { color: s.color, width: 2 };
          }
          return mapped;
        }),
      };
      if (Array.isArray(chartData.reference_lines_y)) {
        const rightMax = Math.max(...(chartData.series || []).filter((s) => s.yAxisIndex === 1).flatMap((s) => s.data || []).map(Number).filter(Number.isFinite), 2);
        option.yAxis[1].max = Math.max(rightMax * 1.05, 2);
        const refSeries = chartData.reference_lines_y.map((rl) => ({
          name: rl.label,
          type: "line",
          yAxisIndex: rl.yAxisIndex ?? 1,
          data: (chartData.x || []).map(() => rl.value),
          lineStyle: { type: "dashed", color: rl.color || "#ef4444", width: 2 },
          itemStyle: { color: rl.color || "#ef4444" },
          symbol: "none",
          tooltip: { show: false },
        }));
        option.series.push(...refSeries);
      }
    } else if (chartData.chart === "bar-horizontal") {
      const legendGroups = Array.isArray(chartData.legend_groups) ? chartData.legend_groups : [];
      const seriesColorMap = {};
      (chartData.series || []).forEach((s) => { if (s.color) seriesColorMap[s.name] = s.color; });
      const legendData = [];
      if (legendGroups.length > 0) {
        legendGroups.forEach((group, idx) => {
          if (idx > 0) {
            legendData.push("");
          }
          legendData.push({ name: group.title, icon: "none", textStyle: { fontWeight: "bold", color: chartTextColor() } });
          (group.items || []).forEach((item) => {
            const entry = { name: item };
            if (seriesColorMap[item]) {
              entry.itemStyle = { color: seriesColorMap[item] };
            }
            legendData.push(entry);
          });
        });
      }
      const bottomPad = legendGroups.length > 0 ? 80 : 60;
      const barWidth = chartData.barWidth || undefined;
      option = baseChartOption(chartData);
      option.grid = { left: 10, right: 24, top: 18, bottom: bottomPad, containLabel: true };
      option.xAxis = {
        type: "value",
        axisLine: { lineStyle: { color: chartGridColor() } },
        splitLine: { lineStyle: { color: chartGridColor() } },
        axisLabel: {
          color: chartTextColor(),
          fontSize: 11,
          formatter: (v) => {
            if (Math.abs(v) >= 1e9) return "$" + (v / 1e9).toFixed(1) + "B";
            if (Math.abs(v) >= 1e6) return "$" + (v / 1e6).toFixed(1) + "M";
            if (Math.abs(v) >= 1e3) return "$" + (v / 1e3).toFixed(0) + "k";
            return "$" + v;
          },
        },
      };
      option.yAxis = {
        type: "category",
        data: chartData.x || [],
        axisLine: { lineStyle: { color: chartGridColor() } },
        axisLabel: { color: chartTextColor(), fontSize: 12, fontWeight: "bold" },
      };
      if (legendData.length > 0) {
        option.legend = { bottom: 2, textStyle: { color: chartTextColor() }, data: legendData };
      }
      option.series = (chartData.series || []).map((series) => {
        const mapped = {
          name: pairAwareLabel(series.name),
          type: "bar",
          data: series.data || [],
          stack: series.stack,
        };
        if (barWidth) {
          mapped.barWidth = barWidth;
        }
        if (series.color) {
          mapped.itemStyle = { color: series.color };
        }
        return mapped;
      });
      if (legendGroups.length > 0) {
        legendGroups.forEach((group) => {
          option.series.push({
            name: group.title,
            type: "bar",
            data: [],
            stack: "__legend_placeholder__",
            silent: true,
            itemStyle: { color: "transparent" },
            tooltip: { show: false },
          });
        });
      }
    } else if (data.chart === "heatmap") {
      const minValue = Number(chartData.min ?? -1);
      const maxValue = Number(chartData.max ?? 1);
      const leftLegend = `${minValue.toFixed(2)}%`;
      const rightLegend = `${maxValue >= 0 ? "+" : ""}${maxValue.toFixed(2)}%`;
      const heatmapSeries = { type: "heatmap", data: chartData.points || [] };
      if (tickReferenceWidgets.has(widgetId)) {
        const markLine = buildTickReferenceMarkLine(chartData);
        if (markLine) {
          heatmapSeries.markLine = markLine;
        }
      }
      const hmXLabel = pairAwareLabel(chartData.xAxisLabel) || "";
      option = {
        color: palette(),
        tooltip: { position: "top" },
        grid: { left: 82, right: 18, top: 16, bottom: hmXLabel ? 68 : 58, containLabel: false },
        xAxis: {
          type: "category",
          data: chartData.x || [],
          boundaryGap: false,
          name: hmXLabel || undefined,
          nameLocation: "middle",
          nameGap: hmXLabel ? 36 : undefined,
          nameTextStyle: hmXLabel ? { color: chartTextColor(), fontSize: 11 } : undefined,
          axisLine: { lineStyle: { color: chartGridColor() } },
          axisLabel: {
            color: chartTextColor(),
            fontSize: 11,
            margin: 8,
            formatter: (value) => formatPrice4dp(value),
            hideOverlap: true,
          },
        },
        yAxis: {
          type: "category",
          data: ["Liquidity Delta"],
          axisLabel: { color: chartTextColor(), width: 62, align: "right", padding: [0, 8, 0, 0] },
        },
        visualMap: {
          min: minValue,
          max: maxValue,
          orient: "horizontal",
          left: "center",
          bottom: 8,
          precision: 3,
          text: [rightLegend, leftLegend],
          textStyle: { color: chartTextColor() },
          inRange: {
            // Strong negatives: deep red, strong positives: deep green, near-zero: transparent.
            color: [
              "rgba(143, 0, 14, 0.95)",
              "rgba(226, 76, 76, 0.7)",
              "rgba(255, 255, 255, 0.02)",
              "rgba(36, 179, 107, 0.7)",
              "rgba(4, 109, 67, 0.95)",
            ],
          },
        },
        series: [heatmapSeries],
      };
      if (leftLinkedZoomWidgets.has(widgetId)) {
        option.dataZoom = [
          {
            type: "inside",
            xAxisIndex: 0,
            filterMode: "none",
            start: focusedTickZoom?.start,
            end: focusedTickZoom?.end,
          },
        ];
      }
    } else if (chartData.chart === "line-area" && chartData.direction_arrows) {
      const arrows = chartData.direction_arrows;
      const topPad = arrows ? 40 : 22;
      const areaYLabel = pairAwareLabel(chartData.yAxisLabel) || (arrows ? "Debt Value ($)" : "");
      const areaXLabel = pairAwareLabel(chartData.xAxisLabel) || "";
      const areaYFmt = axisFormatter(chartData.yAxisFormat);
      const defaultYFmt = arrows
        ? (v) => { if (Math.abs(v) >= 1e6) return "$" + (v / 1e6).toFixed(1) + "M"; if (Math.abs(v) >= 1e3) return "$" + (v / 1e3).toFixed(0) + "k"; return "$" + v; }
        : undefined;
      const defaultXFmt = arrows
        ? (v) => { const n = Number(v); return Number.isFinite(n) ? (n >= 0 ? "+" : "") + n.toFixed(1) : v; }
        : (v) => formatPrice4dp(v);
      option = {
        color: palette(),
        tooltip: { trigger: "axis" },
        legend: { bottom: 2, textStyle: { color: chartTextColor() } },
        grid: { left: areaYLabel ? 55 : 50, right: 18, top: topPad, bottom: areaXLabel ? 72 : 60, containLabel: true },
        xAxis: {
          type: "category",
          data: chartData.x || [],
          boundaryGap: false,
          name: areaXLabel || undefined,
          nameLocation: "middle",
          nameGap: areaXLabel ? 36 : undefined,
          nameTextStyle: areaXLabel ? { color: chartTextColor(), fontSize: 12 } : undefined,
          axisLine: { lineStyle: { color: chartGridColor() } },
          axisLabel: {
            color: chartTextColor(),
            fontSize: 11,
            formatter: defaultXFmt,
            hideOverlap: true,
          },
        },
        yAxis: {
          type: "value",
          name: areaYLabel || undefined,
          nameLocation: "middle",
          nameGap: areaYLabel ? 45 : undefined,
          nameTextStyle: areaYLabel ? { color: chartTextColor(), fontSize: 11 } : undefined,
          axisLine: { lineStyle: { color: chartGridColor() } },
          splitLine: { lineStyle: { color: chartGridColor() } },
          axisLabel: {
            color: chartTextColor(),
            fontSize: 11,
            formatter: areaYFmt || defaultYFmt || undefined,
          },
        },
        series: (chartData.series || []).map((s) => {
          const mapped = {
            name: s.name,
            type: s.type || "line",
            data: s.data || [],
            showSymbol: false,
            smooth: s.smooth ?? false,
          };
          if (s.stack) mapped.stack = s.stack;
          if (s.area) mapped.areaStyle = { opacity: 0.85 };
          if (s.color) {
            mapped.itemStyle = { color: s.color };
            mapped.lineStyle = { color: s.color, width: 1 };
            if (s.area) mapped.areaStyle = { opacity: 0.85, color: s.color };
          }
          return mapped;
        }),
      };
      if (arrows) {
        const xLabels = (chartData.x || []).map(Number);
        const zeroIdx = xLabels.indexOf(0);
        const zeroFrac = zeroIdx >= 0 ? ((zeroIdx / Math.max(xLabels.length - 1, 1)) * 100) : 50;
        const tc = chartTextColor();
        option.graphic = [
          { type: "text", left: "8%", top: 8, style: { text: arrows.left, fill: tc, fontSize: 12 } },
          { type: "text", left: (zeroFrac - 4) + "%", top: 8, style: { text: "\u2190\u2190", fill: tc, fontSize: 13, fontWeight: "bold" } },
          { type: "text", left: zeroFrac + "%", top: 6, style: { text: "0", fill: tc, fontSize: 14, fontWeight: "bold", textAlign: "center" } },
          { type: "text", left: (zeroFrac + 3) + "%", top: 8, style: { text: "\u2192\u2192", fill: tc, fontSize: 13, fontWeight: "bold" } },
          { type: "text", right: "4%", top: 8, style: { text: arrows.right, fill: tc, fontSize: 12 } },
        ];
      }
      if (Array.isArray(chartData.volatility_lines) && chartData.volatility_lines.length > 0) {
        const xLabels = (chartData.x || []).map(String);
        const volSeries = option.series.find((s) => s.data && s.data.length > 0) || option.series[0];
        if (volSeries) {
          volSeries.markLine = {
            silent: true,
            symbol: "none",
            data: chartData.volatility_lines.map((vl) => {
              const closest = xLabels.reduce((best, lbl, idx) => {
                const diff = Math.abs(parseFloat(lbl) - vl.value);
                return diff < best.diff ? { idx, diff } : best;
              }, { idx: 0, diff: Infinity });
              return {
                xAxis: closest.idx,
                lineStyle: { type: "dashed", color: vl.color || "#28c987", width: 2 },
                label: { show: false },
              };
            }),
          };
        }
      }
    } else if (chartData.chart === "pie") {
      const slices = chartData.slices || [];
      option = {
        tooltip: {
          trigger: "item",
          formatter: (params) => {
            const pct = params.percent != null ? params.percent.toFixed(1) : "?";
            return `${params.marker} ${params.name}: ${formatNumber(params.value)} (${pct}%)`;
          },
        },
        legend: {
          bottom: 2,
          textStyle: { color: chartTextColor() },
          data: slices.map((s) => s.name),
        },
        series: [
          {
            type: "pie",
            radius: ["25%", "65%"],
            center: ["50%", "45%"],
            avoidLabelOverlap: true,
            label: {
              show: true,
              formatter: "{d}%",
              color: "#fff",
              fontSize: 13,
              fontWeight: "bold",
              position: "inside",
            },
            emphasis: { itemStyle: { shadowBlur: 10, shadowOffsetX: 0, shadowColor: "rgba(0,0,0,0.5)" } },
            data: slices.map((s) => ({
              name: s.name,
              value: s.value,
              itemStyle: s.color ? { color: s.color } : undefined,
            })),
          },
        ],
      };
      if (chartData.title_extra) {
        option.graphic = [
          {
            type: "text",
            left: "center",
            bottom: 30,
            style: {
              text: chartData.title_extra,
              fill: chartTextColor(),
              fontSize: 11,
              opacity: 0.7,
            },
          },
        ];
      }
    } else if (chartData.chart === "timeline") {
      const bars = chartData.bars || [];
      const nowStr = chartData.now;
      const categories = bars.map((b) => b.label);
      const allTimes = bars.flatMap((b) => [new Date(b.start).getTime(), new Date(b.end).getTime()]);
      const minT = Math.min(...allTimes);
      const maxT = Math.max(...allTimes);
      const pad = (maxT - minT) * 0.05 || 86400000;
      const renderItems = bars.map((b, idx) => ({
        value: [idx, new Date(b.start).getTime(), new Date(b.end).getTime()],
        itemStyle: { color: b.color || "#4bb7ff" },
      }));
      const markLineData = [];
      if (nowStr) {
        const nowMs = new Date(nowStr).getTime();
        if (nowMs >= minT - pad && nowMs <= maxT + pad) {
          markLineData.push({
            xAxis: nowMs,
            lineStyle: { type: "dashed", color: "#ef4444", width: 2 },
            label: { show: true, formatter: "Now", color: "#ef4444", fontSize: 12, fontWeight: "bold", position: "start" },
          });
        }
      }
      option = {
        tooltip: {
          trigger: "item",
          formatter: (params) => {
            if (!params.value) return "";
            const s = new Date(params.value[1]);
            const e = new Date(params.value[2]);
            const fmt = (d) => d.toLocaleDateString("en-GB", { day: "2-digit", month: "short", year: "numeric" });
            return `${categories[params.value[0]]}<br/>${fmt(s)} \u2192 ${fmt(e)}`;
          },
        },
        grid: { left: 140, right: 24, top: 28, bottom: 32 },
        xAxis: {
          type: "time",
          min: minT - pad,
          max: maxT + pad,
          axisLine: { lineStyle: { color: chartGridColor() } },
          axisLabel: { color: chartTextColor(), fontSize: 11, hideOverlap: true },
          splitLine: { show: false },
        },
        yAxis: {
          type: "category",
          data: categories,
          inverse: true,
          axisLine: { lineStyle: { color: chartGridColor() } },
          axisLabel: { color: chartTextColor(), fontSize: 12, fontWeight: 500 },
          axisTick: { show: false },
        },
        series: [
          {
            type: "custom",
            renderItem: (params, api) => {
              const catIdx = api.value(0);
              const startPx = api.coord([api.value(1), catIdx]);
              const endPx = api.coord([api.value(2), catIdx]);
              const barH = api.size([0, 1])[1] * 0.55;
              return {
                type: "rect",
                shape: { x: startPx[0], y: startPx[1] - barH / 2, width: endPx[0] - startPx[0], height: barH },
                style: { ...api.style(), fill: api.visual("color") },
                styleEmphasis: api.style(),
              };
            },
            encode: { x: [1, 2], y: 0 },
            data: renderItems,
            markLine: markLineData.length > 0 ? { silent: true, symbol: "none", data: markLineData } : undefined,
          },
        ],
      };
    } else {
      option = baseChartOption(chartData);
      if (widgetId === "liquidity-depth") {
        option.series = (option.series || []).map((series) => ({
          ...series,
          // Backstop for null/NaN depth payloads: keep both curves continuous across active tick.
          data: (series.data || []).map((value) => {
            const numeric = Number(value);
            return Number.isFinite(numeric) ? numeric : 0;
          }),
          connectNulls: true,
        }));
      }
      if (comparableLiquidityWidgets.has(widgetId)) {
        option.grid.left = 82;
        option.grid.right = 18;
        option.grid.bottom = chartData.xAxisLabel ? 72 : 60;
        option.grid.containLabel = false;
        option.yAxis.axisLabel = {
          ...option.yAxis.axisLabel,
          width: 62,
          align: "right",
          padding: [0, 8, 0, 0],
        };
        option.xAxis.axisLabel = {
          ...option.xAxis.axisLabel,
          formatter: (value) => formatPrice4dp(value),
          margin: 8,
          hideOverlap: true,
        };
      }
      option.xAxis.boundaryGap = false;
      if (widgetId === "liquidity-distribution") {
        option.grid.bottom = chartData.xAxisLabel ? 72 : 60;
        const xValues = Array.isArray(chartData?.x) ? chartData.x : [];
        const series = Array.isArray(option.series) ? option.series : [];
        if (series.length >= 2) {
          const token0LiquidityLabel = pairAwareLabel("USX Liquidity");
          const token1LiquidityLabel = pairAwareLabel("USDC Liquidity");
          const rankSeries = (item, index) => {
            const name = String(item?.name || "");
            if (name === token0LiquidityLabel) {
              return [0, index];
            }
            if (name === token1LiquidityLabel) {
              return [1, index];
            }
            return [2, index];
          };
          const orderedSeries = [...series]
            .map((item, index) => ({ item, rank: rankSeries(item, index) }))
            .sort((a, b) => {
              if (a.rank[0] !== b.rank[0]) {
                return a.rank[0] - b.rank[0];
              }
              return a.rank[1] - b.rank[1];
            })
            .map((entry) => entry.item);
          // Ensure both token bars render on the same tick column.
          option.series = orderedSeries.map((item) => {
            const name = String(item?.name || "");
            let color = null;
            if (name === token0LiquidityLabel) {
              color = "#f8a94a";
            } else if (name === token1LiquidityLabel) {
              color = "#4bb7ff";
            }
            return {
              ...item,
              stack: "active-tick-liquidity",
              ...(color
                ? {
                    itemStyle: { ...(item.itemStyle || {}), color },
                    lineStyle: { ...(item.lineStyle || {}), color },
                  }
                : {}),
            };
          });
          const firstData = Array.isArray(orderedSeries[0]?.data) ? orderedSeries[0].data : [];
          const secondData = Array.isArray(orderedSeries[1]?.data) ? orderedSeries[1].data : [];
          const rawCurrent = Number(chartData?.reference_lines?.current_price);
          if (xValues.length > 0 && Number.isFinite(rawCurrent)) {
            let overlapIndex = null;
            for (let i = 0; i < Math.min(xValues.length, firstData.length, secondData.length); i += 1) {
              const left = Number(firstData[i] || 0);
              const right = Number(secondData[i] || 0);
              if (Number.isFinite(left) && Number.isFinite(right) && left > 0 && right > 0) {
                if (overlapIndex === null) {
                  overlapIndex = i;
                } else {
                  const bestDist = Math.abs(Number(xValues[overlapIndex]) - rawCurrent);
                  const nextDist = Math.abs(Number(xValues[i]) - rawCurrent);
                  if (nextDist < bestDist) {
                    overlapIndex = i;
                  }
                }
              }
            }
            if (overlapIndex !== null) {
              chartData = {
                ...chartData,
                reference_lines: {
                  ...(chartData.reference_lines || {}),
                  current_price: Number(xValues[overlapIndex]),
                },
              };
            }
          }
        }
      }
      if (leftLinkedZoomWidgets.has(widgetId)) {
        option.dataZoom = [
          {
            type: "inside",
            xAxisIndex: 0,
            filterMode: "none",
            start: focusedTickZoom?.start,
            end: focusedTickZoom?.end,
          },
          {
            type: "slider",
            xAxisIndex: 0,
            height: 12,
            bottom: 28,
            borderColor: chartGridColor(),
            brushSelect: false,
            start: focusedTickZoom?.start,
            end: focusedTickZoom?.end,
          },
        ];
      }
      if (getTimeseriesGroupId(widgetId)) {
        applyLinkedTimeseriesFormat(option);
      }
      if (tickReferenceWidgets.has(widgetId) && Array.isArray(option.series) && option.series.length > 0) {
        const markLine = buildTickReferenceMarkLine(chartData);
        if (markLine) {
          option.series[0] = {
            ...option.series[0],
            markLine,
          };
        }
      }
      if (widgetId === "usdc-lp-flows") {
        const lpNetColor = palette()[0];
        option.yAxis = [
          {
            type: "value",
            min: (axis) => {
              const absMax = Math.max(Math.abs(Number(axis.min) || 0), Math.abs(Number(axis.max) || 0));
              return -absMax;
            },
            max: (axis) => {
              const absMax = Math.max(Math.abs(Number(axis.min) || 0), Math.abs(Number(axis.max) || 0));
              return absMax;
            },
            axisLine: { lineStyle: { color: chartGridColor() } },
            splitLine: { lineStyle: { color: chartGridColor() } },
            axisLabel: { color: chartTextColor(), width: 62, align: "right", padding: [0, 8, 0, 0] },
          },
          {
            type: "value",
            position: "right",
            min: (axis) => {
              const absMax = Math.max(Math.abs(Number(axis.min) || 0), Math.abs(Number(axis.max) || 0));
              return -absMax;
            },
            max: (axis) => {
              const absMax = Math.max(Math.abs(Number(axis.min) || 0), Math.abs(Number(axis.max) || 0));
              return absMax;
            },
            axisLine: { lineStyle: { color: chartGridColor() } },
            splitLine: { show: false },
            axisLabel: {
              color: chartTextColor(),
              formatter: (value) => `${Number(value).toFixed(2)}%`,
            },
          },
        ];
        option.series = (option.series || []).map((series) => {
          if (series.name !== "LP Net % Reserve") {
            return series;
          }
          return {
            ...series,
            yAxisIndex: 1,
            lineStyle: { ...(series.lineStyle || {}), color: lpNetColor },
            itemStyle: { ...(series.itemStyle || {}), color: lpNetColor },
          };
        });
      }
      if (widgetId === "swaps-flows-toggle") {
        option.yAxis = [
          {
            type: "value",
            axisLine: { lineStyle: { color: chartGridColor() } },
            splitLine: { lineStyle: { color: chartGridColor() } },
            axisLabel: { color: chartTextColor(), width: 62, align: "right", padding: [0, 8, 0, 0] },
          },
          {
            type: "value",
            position: "right",
            axisLine: { lineStyle: { color: chartGridColor() } },
            splitLine: { show: false },
            axisLabel: { color: chartTextColor(), formatter: (value) => Math.round(Number(value)).toString() },
          },
        ];
      }
      if (widgetId === "swaps-price-impacts") {
        option.yAxis = {
          type: "value",
          axisLine: { lineStyle: { color: chartGridColor() } },
          splitLine: { lineStyle: { color: chartGridColor() } },
          axisLabel: {
            color: chartTextColor(),
            width: 62,
            align: "right",
            padding: [0, 8, 0, 0],
            formatter: (value) => Number(value).toFixed(3),
          },
        };
      }
      if (widgetId === "swaps-spread-volatility") {
        option.yAxis = [
          {
            type: "value",
            min: (axis) => {
              const min = Number(axis.min) || 0;
              const max = Number(axis.max) || 0;
              const span = Math.max(max - min, 0.0001);
              return min - span * 0.15;
            },
            max: (axis) => {
              const min = Number(axis.min) || 0;
              const max = Number(axis.max) || 0;
              const span = Math.max(max - min, 0.0001);
              return max + span * 0.15;
            },
            axisLine: { lineStyle: { color: chartGridColor() } },
            splitLine: { lineStyle: { color: chartGridColor() } },
            axisLabel: {
              color: chartTextColor(),
              width: 62,
              align: "right",
              padding: [0, 8, 0, 0],
              formatter: (value) => Number(value).toFixed(2),
            },
          },
          {
            type: "value",
            position: "right",
            min: (axis) => {
              const min = Number(axis.min) || 0;
              const max = Number(axis.max) || 0;
              const span = Math.max(max - min, 0.0001);
              return min - span * 0.15;
            },
            max: (axis) => {
              const min = Number(axis.min) || 0;
              const max = Number(axis.max) || 0;
              const span = Math.max(max - min, 0.0001);
              return max + span * 0.15;
            },
            axisLine: { lineStyle: { color: chartGridColor() } },
            splitLine: { show: false },
            axisLabel: { color: chartTextColor(), formatter: (value) => Number(value).toFixed(6) },
          },
        ];
      }
      if (
        widgetId === "swaps-sell-usx-distribution" ||
        widgetId === "swaps-1h-net-sell-pressure-distribution" ||
        widgetId === "swaps-distribution-toggle"
      ) {
        option.xAxis = {
          ...option.xAxis,
          boundaryGap: true,
        };
        option.grid = {
          ...option.grid,
          left: 72,
          right: 52,
        };
        option.yAxis = [
          {
            type: "value",
            axisLine: { lineStyle: { color: chartGridColor() } },
            splitLine: { lineStyle: { color: chartGridColor() } },
            axisLabel: { color: chartTextColor(), formatter: (value) => Math.round(Number(value)).toString() },
          },
          {
            type: "value",
            position: "right",
            axisLine: { lineStyle: { color: chartGridColor() } },
            splitLine: { show: false },
            axisLabel: { color: chartTextColor(), formatter: (value) => Number(value).toFixed(2) },
          },
        ];
      }
    }

    instance.setOption(option, true);
    // ECharts can consume canvas click events, so bind modal open on chart instance.
    instance.off("click");
    instance.on("click", () => {
      openChartModal(widgetId);
    });
    if (leftLinkedZoomWidgets.has(widgetId)) {
      instance.group = linkedGroups.left;
      echarts.connect(linkedGroups.left);
      if (focusedTickZoom) {
        instance.dispatchAction({
          type: "dataZoom",
          start: focusedTickZoom.start,
          end: focusedTickZoom.end,
        });
      }
    } else {
      const tsGroupId = getTimeseriesGroupId(widgetId);
      if (tsGroupId) {
        instance.group = tsGroupId;
        echarts.connect(tsGroupId);
      }
    }
    chartState.set(widgetId, { instance, data });
    if (modalWidgetId === widgetId) {
      syncModalChart();
    }
  }

  function renderPayload(widgetId, payload) {
    const kind = payload?.data?.kind;
    if (!kind) {
      return;
    }

    if (kind === "kpi") {
      renderKpi(widgetId, payload.data);
      return;
    }

    if (kind === "table") {
      if (payload.data.info) {
        renderHealthInfoToggle(widgetId, payload.data.info);
      }
      if (payload.data.title_override) {
        const titleEl = document.querySelector(`#widget-${widgetId} .panel-title-group h3`);
        if (titleEl) titleEl.textContent = payload.data.title_override;
      }
      renderTable(widgetId, `table-${widgetId}`, payload.data.columns || [], payload.data.rows || []);
      if (payload.data.subtitle) {
        const subEl = document.getElementById(`table-subtitle-${widgetId}`);
        if (subEl) subEl.textContent = payload.data.subtitle;
      }
      return;
    }

    if (kind === "table-split") {
      const columns = payload.data.columns || [];
      document.getElementById(`table-left-title-${widgetId}`).textContent = pairAwareLabel(payload.data.left_title || "Left");
      document.getElementById(`table-right-title-${widgetId}`).textContent = pairAwareLabel(payload.data.right_title || "Right");
      renderTable(widgetId, `table-left-${widgetId}`, columns, payload.data.left_rows || []);
      renderTable(widgetId, `table-right-${widgetId}`, columns, payload.data.right_rows || []);
      return;
    }

    renderChart(widgetId, payload.data);
  }

  function updateTimestamp(widgetId, generatedAt) {
    const el = document.getElementById(`updated-${widgetId}`);
    if (!el) {
      return;
    }
    const stamp = generatedAt ? new Date(generatedAt).toLocaleTimeString() : new Date().toLocaleTimeString();
    el.textContent = `updated ${stamp}`;
  }

  function setWidgetError(widgetId, message) {
    const el = document.getElementById(`updated-${widgetId}`);
    if (el) {
      el.textContent = `error: ${message}`;
    }
  }

  function resetWidgetView(el) {
    const widgetId = el.dataset.widgetId;
    const kind = el.dataset.widgetKind;
    if (!widgetId) {
      return;
    }

    const updatedEl = document.getElementById(`updated-${widgetId}`);
    if (updatedEl) {
      updatedEl.textContent = "loading...";
    }

    if (kind === "kpi") {
      const primary = document.getElementById(`kpi-primary-${widgetId}`);
      const secondary = document.getElementById(`kpi-secondary-${widgetId}`);
      if (primary) {
        primary.textContent = "--";
        autoSizeKpi(primary);
      }
      if (secondary) {
        secondary.textContent = "";
      }
      return;
    }

    if (kind === "table") {
      const table = document.getElementById(`table-${widgetId}`);
      if (table) {
        table.innerHTML = "";
      }
      return;
    }

    if (kind === "table-split") {
      const leftTitle = document.getElementById(`table-left-title-${widgetId}`);
      const rightTitle = document.getElementById(`table-right-title-${widgetId}`);
      const left = document.getElementById(`table-left-${widgetId}`);
      const right = document.getElementById(`table-right-${widgetId}`);
      if (leftTitle) {
        leftTitle.textContent = "";
      }
      if (rightTitle) {
        rightTitle.textContent = "";
      }
      if (left) {
        left.innerHTML = "";
      }
      if (right) {
        right.innerHTML = "";
      }
      return;
    }

    const chart = chartState.get(widgetId);
    if (chart?.instance) {
      chart.instance.clear();
    }
  }

  function resetDashboardLoading() {
    leftDefaultZoomWindow = null;
    leftDefaultZoomSignature = "";
    widgetElements().forEach((el) => resetWidgetView(el));
  }

  function getApiBaseUrl() {
    return document.body.dataset.apiBaseUrl || "http://localhost:8001";
  }

  function widgetElements() {
    return Array.from(document.querySelectorAll(".widget-loader"));
  }

  function currentProtocol() {
    const select = document.getElementById("protocol-select");
    return select ? select.value : "raydium";
  }

  function currentPair() {
    const select = document.getElementById("pair-select");
    return select ? select.value : "USX-USDC";
  }

  function currentLastWindow() {
    const select = document.getElementById("last-window-select");
    return select ? select.value : "7d";
  }

  function currentMkt1() {
    const select = document.getElementById("mkt1-select");
    return select ? select.value : "";
  }

  function currentMkt2() {
    const select = document.getElementById("mkt2-select");
    return select ? select.value : "";
  }

  function readPersistedFilters() {
    try {
      const raw = window.localStorage.getItem(FILTER_STORAGE_KEY);
      if (!raw) {
        return null;
      }
      const parsed = JSON.parse(raw);
      return {
        protocol: typeof parsed?.protocol === "string" ? parsed.protocol : "",
        pair: typeof parsed?.pair === "string" ? parsed.pair : "",
        lastWindow: typeof parsed?.lastWindow === "string" ? parsed.lastWindow : "",
      };
    } catch (_) {
      return null;
    }
  }

  function persistFilters(protocol, pair, lastWindow) {
    try {
      window.localStorage.setItem(
        FILTER_STORAGE_KEY,
        JSON.stringify({
          protocol: protocol || "",
          pair: pair || "",
          lastWindow: lastWindow || "",
        })
      );
    } catch (_) {
      // Ignore storage failures (private mode / quota).
    }
  }

  function applyGlobalFilters(protocol, pair, lastWindow, shouldRefresh = true) {
    if (protocol) {
      const protocolSelect = document.getElementById("protocol-select");
      if (protocolSelect) {
        protocolSelect.value = protocol;
      }
    }
    if (pair) {
      const pairSelect = document.getElementById("pair-select");
      if (pairSelect) {
        pairSelect.value = pair;
      }
    }
    if (lastWindow) {
      const lastWindowSelect = document.getElementById("last-window-select");
      if (lastWindowSelect) {
        lastWindowSelect.value = lastWindow;
      }
    }
    persistFilters(
      protocol || currentProtocol(),
      pair || currentPair(),
      lastWindow || currentLastWindow()
    );
    if (shouldRefresh) {
      htmx.trigger(document.body, "dashboard-refresh");
    }
  }

  function setSelectOptions(selectEl, values, selected) {
    if (!selectEl) {
      return;
    }
    const unique = Array.from(new Set(values.filter(Boolean)));
    const options = unique.map((value) => `<option value="${value}">${value}</option>`).join("");
    selectEl.innerHTML = options;
    if (unique.includes(selected)) {
      selectEl.value = selected;
      return;
    }
    if (unique.length > 0) {
      selectEl.value = unique[0];
    }
  }

  function pairsForProtocol(protocol) {
    return protocolPairs.filter((item) => item.protocol === protocol).map((item) => item.pair);
  }

  function applyPairAwarePanelTitles() {
    document.querySelectorAll(".widget-loader .panel-header h3").forEach((titleEl) => {
      const baseTitle = titleEl.dataset.baseTitle || titleEl.textContent || "";
      titleEl.dataset.baseTitle = baseTitle;
      titleEl.textContent = pairAwareLabel(baseTitle);
    });
  }

  function initPageSelector() {
    const pageSelect = document.getElementById("page-select");
    if (!pageSelect) {
      return;
    }
    pageSelect.addEventListener("change", () => {
      if (pageSelect.value && pageSelect.value !== window.location.pathname) {
        window.location.assign(pageSelect.value);
      }
    });
  }

  async function initFilters() {
    const protocolSelect = document.getElementById("protocol-select");
    const pairSelect = document.getElementById("pair-select");
    const lastWindowSelect = document.getElementById("last-window-select");
    if (!lastWindowSelect) {
      return;
    }
    const persisted = readPersistedFilters();
    if (persisted?.lastWindow && lastWindowSelect.querySelector(`option[value="${persisted.lastWindow}"]`)) {
      lastWindowSelect.value = persisted.lastWindow;
    } else if (lastWindowSelect.querySelector('option[value="7d"]')) {
      lastWindowSelect.value = "7d";
    }

    let selectedProtocol = protocolSelect ? protocolSelect.value : currentProtocol();
    let selectedPair = pairSelect ? pairSelect.value : currentPair();
    let selectedLastWindow = lastWindowSelect.value || "7d";
    if (persisted?.protocol) {
      selectedProtocol = persisted.protocol;
    }
    if (persisted?.pair) {
      selectedPair = persisted.pair;
    }
    if (persisted?.lastWindow) {
      selectedLastWindow = persisted.lastWindow;
    }

    if (protocolSelect && pairSelect) {
      try {
        const response = await fetch(`${getApiBaseUrl()}/api/v1/meta`);
        const payload = await response.json();
        protocolPairs = payload.protocol_pairs || [];
        const protocols = payload.protocols || protocolPairs.map((item) => item.protocol);
        setSelectOptions(protocolSelect, protocols, selectedProtocol);
        selectedProtocol = protocolSelect.value || selectedProtocol;
        setSelectOptions(pairSelect, pairsForProtocol(selectedProtocol), selectedPair);
        selectedPair = pairSelect.value || selectedPair;
      } catch (_) {
        protocolPairs = [{ protocol: selectedProtocol, pair: selectedPair }];
      }
    }

    applyGlobalFilters(selectedProtocol, selectedPair, selectedLastWindow, true);
    applyPairAwarePanelTitles();

    if (protocolSelect && pairSelect) {
      protocolSelect.addEventListener("change", () => {
        const protocol = protocolSelect.value;
        setSelectOptions(pairSelect, pairsForProtocol(protocol), pairSelect.value);
        applyPairAwarePanelTitles();
        initSwapsFlowModeToggle();
        resetDashboardLoading();
        applyGlobalFilters(protocol, pairSelect.value, lastWindowSelect.value, true);
      });

      pairSelect.addEventListener("change", () => {
        applyPairAwarePanelTitles();
        initSwapsFlowModeToggle();
        resetDashboardLoading();
        applyGlobalFilters(protocolSelect.value, pairSelect.value, lastWindowSelect.value, true);
      });
    }

    lastWindowSelect.addEventListener("change", () => {
      resetDashboardLoading();
      const protocol = protocolSelect ? protocolSelect.value : currentProtocol();
      const pair = pairSelect ? pairSelect.value : currentPair();
      applyGlobalFilters(protocol, pair, lastWindowSelect.value, true);
    });

    const refreshButton = document.getElementById("refresh-dashboard");
    if (refreshButton) {
      refreshButton.addEventListener("click", () => {
        const protocol = protocolSelect ? protocolSelect.value : currentProtocol();
        const pair = pairSelect ? pairSelect.value : currentPair();
        applyGlobalFilters(protocol, pair, lastWindowSelect.value, true);
      });
    }

    await initMarketSelectors();

    initTradeImpactModeToggle();
    initSwapsFlowModeToggle();
    initSwapsDistributionModeToggle();
    initSwapsOhlcvIntervalToggle();
    initHealthSchemaToggle();
    initHealthAttributeToggle();
    initHealthBaseSchemaToggle();
  }

  async function initMarketSelectors() {
    const container = document.getElementById("market-selectors");
    if (!container) return;

    const mkt1Select = document.getElementById("mkt1-select");
    const mkt2Select = document.getElementById("mkt2-select");
    if (!mkt1Select || !mkt2Select) return;

    const pageId = container.dataset.apiPageId;
    try {
      const url = `${getApiBaseUrl()}/api/v1/${pageId}/exponent-market-meta`;
      const resp = await fetch(url);
      const payload = await resp.json();
      const meta = payload.data || payload;
      const markets = meta.markets || [];
      const defaultMkt1 = meta.selected_mkt1 || "";
      const defaultMkt2 = meta.selected_mkt2 || "";

      setSelectOptions(mkt1Select, markets, defaultMkt1);
      setSelectOptions(mkt2Select, markets, defaultMkt2);
    } catch (_) {
      mkt1Select.innerHTML = '<option value="">Unavailable</option>';
      mkt2Select.innerHTML = '<option value="">Unavailable</option>';
    }

    const lastWindowSelect = document.getElementById("last-window-select");

    mkt1Select.addEventListener("change", () => {
      resetDashboardLoading();
      const protocol = currentProtocol();
      const pair = currentPair();
      const lw = lastWindowSelect ? lastWindowSelect.value : currentLastWindow();
      applyGlobalFilters(protocol, pair, lw, true);
    });

    mkt2Select.addEventListener("change", () => {
      resetDashboardLoading();
      const protocol = currentProtocol();
      const pair = currentPair();
      const lw = lastWindowSelect ? lastWindowSelect.value : currentLastWindow();
      applyGlobalFilters(protocol, pair, lw, true);
    });
  }

  function initTradeImpactModeToggle() {
    const modeSelect = document.getElementById("trade-impact-mode");
    const widget = document.getElementById("widget-trade-impact-toggle");
    if (!modeSelect || !widget) {
      return;
    }
    widget.dataset.impactMode = modeSelect.value || "size";
    modeSelect.addEventListener("change", () => {
      widget.dataset.impactMode = modeSelect.value || "size";
      resetWidgetView(widget);
      htmx.trigger(widget, "impact-mode-change");
    });
  }

  function initSwapsDistributionModeToggle() {
    const modeSelect = document.getElementById("swaps-distribution-mode");
    const widget = document.getElementById("widget-swaps-distribution-toggle");
    if (!modeSelect || !widget) {
      return;
    }
    widget.dataset.distributionMode = modeSelect.value || "sell-order";
    modeSelect.addEventListener("change", () => {
      widget.dataset.distributionMode = modeSelect.value || "sell-order";
      resetWidgetView(widget);
      htmx.trigger(widget, "distribution-mode-change");
    });
  }

  function initSwapsFlowModeToggle() {
    const modeSelect = document.getElementById("swaps-flow-mode");
    const widget = document.getElementById("widget-swaps-flows-toggle");
    if (!modeSelect || !widget) {
      return;
    }
    const { token0, token1 } = currentPairTokens();
    const token0Option = modeSelect.querySelector('option[value="usx"]');
    const token1Option = modeSelect.querySelector('option[value="usdc"]');
    if (token0Option) {
      token0Option.textContent = token0;
    }
    if (token1Option) {
      token1Option.textContent = token1;
    }
    widget.dataset.flowMode = modeSelect.value || "usx";
    modeSelect.addEventListener("change", () => {
      widget.dataset.flowMode = modeSelect.value || "usx";
      resetWidgetView(widget);
      htmx.trigger(widget, "flow-mode-change");
    });
  }

  function initSwapsOhlcvIntervalToggle() {
    const intervalSelect = document.getElementById("swaps-ohlcv-interval");
    const widget = document.getElementById("widget-swaps-ohlcv");
    if (!intervalSelect || !widget) {
      return;
    }
    widget.dataset.ohlcvInterval = intervalSelect.value || "1d";
    intervalSelect.addEventListener("change", () => {
      widget.dataset.ohlcvInterval = intervalSelect.value || "1d";
      resetWidgetView(widget);
      htmx.trigger(widget, "ohlcv-interval-change");
    });
  }

  function initHealthSchemaToggle() {
    const schemaSelect = document.getElementById("health-schema-select");
    const widget = document.getElementById("widget-health-queue-chart");
    if (!schemaSelect || !widget) return;
    widget.dataset.healthSchema = schemaSelect.value || "dexes";
    schemaSelect.addEventListener("change", () => {
      widget.dataset.healthSchema = schemaSelect.value || "dexes";
      resetWidgetView(widget);
      htmx.trigger(document.body, "health-schema-change");
    });
  }

  function initHealthAttributeToggle() {
    const attrSelect = document.getElementById("health-attribute-select");
    const widget = document.getElementById("widget-health-queue-chart");
    if (!attrSelect || !widget) return;
    widget.dataset.healthAttribute = attrSelect.value || "Write Rate";
    attrSelect.addEventListener("change", () => {
      widget.dataset.healthAttribute = attrSelect.value || "Write Rate";
      resetWidgetView(widget);
      htmx.trigger(document.body, "health-attribute-change");
    });
  }

  function initHealthBaseSchemaToggle() {
    const selects = document.querySelectorAll(".health-base-schema-select");
    if (!selects.length) return;
    const eventsWidget = document.getElementById("widget-health-base-chart-events");
    const accountsWidget = document.getElementById("widget-health-base-chart-accounts");
    selects.forEach((sel) => {
      sel.addEventListener("change", () => {
        const val = sel.value || "dexes";
        selects.forEach((s) => { s.value = val; });
        if (eventsWidget) {
          eventsWidget.dataset.healthBaseSchema = val;
          resetWidgetView(eventsWidget);
        }
        if (accountsWidget) {
          accountsWidget.dataset.healthBaseSchema = val;
          resetWidgetView(accountsWidget);
        }
        htmx.trigger(document.body, "health-base-schema-change");
      });
    });
    if (eventsWidget) eventsWidget.dataset.healthBaseSchema = selects[0].value || "dexes";
    if (accountsWidget) accountsWidget.dataset.healthBaseSchema = selects[0].value || "dexes";
  }

  document.body.addEventListener("htmx:afterRequest", (event) => {
    const sourceEl = event.detail.elt;
    if (!sourceEl || !sourceEl.classList.contains("widget-loader")) {
      return;
    }
    const widgetId = sourceEl.dataset.widgetId;
    if (!widgetId) {
      return;
    }
    try {
      const raw = event.detail.xhr.responseText;
      if (!raw) {
        setWidgetError(widgetId, "no response from API");
        return;
      }
      const payload = JSON.parse(raw);
      if (payload.status !== "success") {
        setWidgetError(widgetId, payload.detail || "request failed");
        return;
      }
      renderPayload(widgetId, payload);
      updateTimestamp(widgetId, payload?.metadata?.generated_at);
    } catch (error) {
      setWidgetError(widgetId, String(error));
    }
  });

  document.body.addEventListener("htmx:configRequest", (event) => {
    const sourceEl = event.detail.elt;
    if (!sourceEl || !sourceEl.classList.contains("widget-loader")) {
      return;
    }
    // Enforce active global filters on every widget request.
    event.detail.parameters.protocol = currentProtocol();
    event.detail.parameters.pair = currentPair();
    event.detail.parameters.last_window = currentLastWindow();
    const m1 = currentMkt1();
    const m2 = currentMkt2();
    if (m1) event.detail.parameters.mkt1 = m1;
    if (m2) event.detail.parameters.mkt2 = m2;
    if (sourceEl.dataset.widgetId === "trade-impact-toggle") {
      event.detail.parameters.impact_mode = sourceEl.dataset.impactMode || "size";
    }
    if (sourceEl.dataset.widgetId === "swaps-flows-toggle") {
      event.detail.parameters.flow_mode = sourceEl.dataset.flowMode || "usx";
    }
    if (sourceEl.dataset.widgetId === "swaps-distribution-toggle") {
      event.detail.parameters.distribution_mode = sourceEl.dataset.distributionMode || "sell-order";
    }
    if (sourceEl.dataset.widgetId === "swaps-ohlcv") {
      event.detail.parameters.ohlcv_interval = sourceEl.dataset.ohlcvInterval || "1d";
    }
    if (sourceEl.dataset.widgetId === "health-queue-chart") {
      event.detail.parameters.health_schema = sourceEl.dataset.healthSchema || "dexes";
      event.detail.parameters.health_attribute = sourceEl.dataset.healthAttribute || "Write Rate";
    }
    if (sourceEl.dataset.widgetId === "health-base-chart-events" || sourceEl.dataset.widgetId === "health-base-chart-accounts") {
      event.detail.parameters.health_base_schema = sourceEl.dataset.healthBaseSchema || "dexes";
    }
  });

  document.body.addEventListener("htmx:beforeRequest", (event) => {
    const sourceEl = event.detail.elt;
    if (!sourceEl || !sourceEl.classList.contains("widget-loader")) {
      return;
    }
    // Avoid background polling/request churn when the tab is hidden.
    if (document.hidden) {
      event.preventDefault();
    }
  });

  document.body.addEventListener("htmx:responseError", (event) => {
    const sourceEl = event.detail.elt;
    if (!sourceEl || !sourceEl.classList.contains("widget-loader")) {
      return;
    }
    const widgetId = sourceEl.dataset.widgetId;
    if (!widgetId) {
      return;
    }
    const xhr = event.detail.xhr;
    let detail = `HTTP ${xhr.status}`;
    try {
      const payload = JSON.parse(xhr.responseText);
      if (payload?.detail) {
        detail = payload.detail;
      }
    } catch (_) {
      // Ignore parse errors and keep default status detail.
    }
    setWidgetError(widgetId, detail);
  });

  document.body.addEventListener("htmx:sendError", (event) => {
    const sourceEl = event.detail.elt;
    if (!sourceEl || !sourceEl.classList.contains("widget-loader")) {
      return;
    }
    const widgetId = sourceEl.dataset.widgetId;
    if (!widgetId) {
      return;
    }
    setWidgetError(widgetId, "cannot reach API");
  });

  document.body.addEventListener("htmx:timeout", (event) => {
    const sourceEl = event.detail.elt;
    if (!sourceEl || !sourceEl.classList.contains("widget-loader")) {
      return;
    }
    const widgetId = sourceEl.dataset.widgetId;
    if (!widgetId) {
      return;
    }
    setWidgetError(widgetId, "request timeout");
  });

  document.body.addEventListener("click", (event) => {
    const detailBtn = event.target.closest(".detail-table-btn");
    if (detailBtn) {
      event.preventDefault();
      event.stopPropagation();
      openDetailTable(detailBtn.dataset.widgetId || "");
      return;
    }

    const expandButton = event.target.closest(".chart-expand-btn");
    if (expandButton) {
      event.preventDefault();
      openChartModal(expandButton.dataset.widgetId || "");
      return;
    }

    const chartPanelBody = event.target.closest('.widget-loader[data-widget-kind="chart"][data-expandable="true"] .panel-body');
    if (!chartPanelBody) {
      return;
    }
    const widget = chartPanelBody.closest(".widget-loader");
    if (!widget) {
      return;
    }
    openChartModal(widget.dataset.widgetId || "");
  });

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      closeChartModal();
      closeTableModal();
      closePageActionModal();
    }
  });

  document.body.addEventListener("click", (event) => {
    const { backdrop } = modalElements();
    if (!backdrop || backdrop.hidden) {
      return;
    }
    const closeBtn = event.target.closest("#chart-modal-close");
    if (closeBtn) {
      closeChartModal();
      return;
    }
    if (event.target === backdrop) {
      closeChartModal();
    }
  });

  window.addEventListener("theme:changed", () => {
    chartState.forEach(({ instance, data }, widgetId) => {
      if (instance) {
        renderChart(widgetId, data);
      }
    });
    syncModalChart();
  });

  window.addEventListener("resize", () => {
    chartState.forEach(({ instance }) => instance && instance.resize());
    if (modalInstance) {
      modalInstance.resize();
    }
  });

  /* ── Page-Action Modal ────────────────────────────────────── */
  function pageActionModalEls() {
    return {
      backdrop: document.getElementById("page-action-modal-backdrop"),
      title: document.getElementById("page-action-modal-title"),
      body: document.getElementById("page-action-modal-body"),
    };
  }

  function closePageActionModal() {
    const { backdrop } = pageActionModalEls();
    if (backdrop) backdrop.hidden = true;
  }

  function openPageActionModal(label, html) {
    const { backdrop, title, body } = pageActionModalEls();
    if (!backdrop) return;
    title.textContent = label;
    body.innerHTML = html;
    backdrop.hidden = false;
  }

  function buildExplainerHTML() {
    const isDark = document.documentElement.getAttribute("data-theme") === "dark";
    const themeDirective = isDark
      ? "%%{init: {'theme':'dark', 'themeVariables': { 'lineColor':'#22c55e', 'primaryColor':'#1e40af', 'primaryBorderColor':'#3b82f6', 'secondaryColor':'#0891b2', 'tertiaryColor':'#0d9488'}}}%%"
      : "%%{init: {'theme':'default', 'themeVariables': { 'lineColor':'#16a34a'}}}%%";

    const mermaidDef = `${themeDirective}
flowchart LR
    subgraph LEFT[ ]
        direction TB
        subgraph MARKET[Lending Market]
            MKT((Market<br/>Account))
        end
        MKT -->|owns| RB1
        MKT -->|owns| RB2
        MKT -->|owns| RC1
        subgraph RESERVES[Reserve Accounts]
            RB1[Reserve: USX<br/>borrow]
            RB2[Reserve: USDC<br/>borrow]
            RC1[Reserve: eUSX<br/>collateral]
        end
    end
    subgraph OBLIGATIONS[Obligation Accounts]
        direction TB
        O1[Obligation<br/>user_1]
        O2[Obligation<br/>user_2]
        O3[Obligation<br/>user_n]
    end
    O1 -.->|positions| RESERVES
    O2 -.->|positions| RESERVES
    O3 -.->|positions| RESERVES
    OBLIGATIONS -.->|belongs to| MKT
    linkStyle default stroke:#22c55e,stroke-width:3px
    style LEFT fill:none,stroke:none`;

    return `
<h4>Summary</h4>
<p>The Kamino protocol facilitates a cross-margined lending market, where multiple assets can be borrowed against a common basket of accepted collateral tokens.</p>

<div class="mermaid-wrap"><pre class="mermaid">${mermaidDef}</pre></div>

<h4>Protocol Infrastructure</h4>
<p>Three on-chain account types form the protocol structure:</p>
<ul>
  <li><strong>Market Account</strong> &mdash; Top-level structure that owns all reserve and obligation accounts. Defines a quote currency (typically USD) to value all assets on a common basis using pricing oracles.</li>
  <li><strong>Reserve Account</strong> &mdash; Each token has a unique reserve account serving both borrow and collateral roles. Accepts deposits from suppliers and manages liquidity for borrowers.</li>
  <li><strong>Obligation Account</strong> &mdash; Each user has one obligation per market tracking all borrow, collateral, and supply positions. Aggregates risk and valuation in the market's quote currency.</li>
</ul>

<h4>New Loans</h4>
<p>Borrowing capacity is determined by loan-to-value (LTV) parameters:</p>
<ul>
  <li>Each collateral deposit converts to market quote currency</li>
  <li>Multiplied by its collateral LTV</li>
  <li>Sum defines maximum borrowable value</li>
</ul>
<p>Each borrow asset has a risk weight (borrow factor) that rescales its market value before comparison against maximum borrowable value.</p>

<h4>Health Monitoring</h4>
<p>Unhealthy borrow value = &Sigma;(Collateral value &times; liquidation LTV)</p>
<p>Health Factor (HF) = Unhealthy borrow value &divide; Adjusted borrow value</p>
<ul>
  <li>HF = 1 &rarr; liquidation eligible</li>
  <li>HF &gt; 1 &rarr; healthy</li>
  <li>HF &lt; 1 &rarr; actively liquidatable</li>
</ul>
<p>New loan LTVs are set below liquidation thresholds to buffer against price volatility.</p>

<h4>Liquidations &amp; Loss Socialization</h4>
<ul>
  <li>Liquidators repay borrowed assets for discounted collateral</li>
  <li>Operates on individual borrow-collateral pairs</li>
  <li>Cap applies (~20% max per transaction during standard liquidation)</li>
  <li>Eligibility ends once HF restored above 1</li>
</ul>
<p>A severe LTV threshold defines insolvency risk level where up to 100% may be liquidatable. If liquidators fail to restore solvency, the protocol may socialize losses via haircuts on depositor claims.</p>

<h4>Asset Valuation</h4>
<p>Kamino uses on-chain price oracles. Exponent principal tokens (PT-USX and PT-eUSX) use a custom pricing model:</p>
<blockquote><code>PT price = (1 - (time_to_maturity_seconds &times; annual_discount_rate / seconds_per_year)) &times; underlying_price</code></blockquote>
<p>Current annual discount rate: 25%. Underlying asset for both PT tokens is USX (not eUSX), so they don't transmit eUSX price risk and increase predictably toward maturity.</p>

<h4>APY Pricing</h4>
<p>Supply and borrow APYs are determined by each reserve's utilization rate. Rates increase as utilization rises. The spread between supply and borrow APY is defined by the protocol's take rate.</p>
`;
  }

  function buildExplainerExponentHTML() {
    const isDark = document.documentElement.getAttribute("data-theme") === "dark";
    const themeDirective = isDark
      ? "%%{init: {'theme':'dark', 'themeVariables': { 'lineColor':'#22c55e', 'primaryColor':'#1e40af', 'primaryBorderColor':'#3b82f6', 'secondaryColor':'#0891b2', 'tertiaryColor':'#0d9488'}}}%%"
      : "%%{init: {'theme':'default', 'themeVariables': { 'lineColor':'#16a34a'}}}%%";

    const mermaidDef = `${themeDirective}
flowchart LR
    subgraph WRAP[Wrapping]
        direction TB
        BASE[Base Token<br/>e.g. eUSX] -->|wrap| SY[SY Token]
        SY -->|unwrap| BASE
    end
    subgraph STRIP[Stripping]
        direction TB
        SY2[SY] -->|split 1:1| PTYT["PT + YT<br/>(per maturity)"]
        PTYT -->|merge pair| SY2
    end
    subgraph AMM[Yield Trading AMM]
        direction TB
        POOL["SY + PT<br/>Liquidity Pool"]
        LP[LP Providers] -->|deposit| POOL
        POOL -->|fees| LP
    end
    WRAP --> STRIP
    STRIP --> AMM
    linkStyle default stroke:#22c55e,stroke-width:3px
    style WRAP fill:none,stroke:#3b82f6
    style STRIP fill:none,stroke:#0891b2
    style AMM fill:none,stroke:#0d9488`;

    return `
<h4>Summary</h4>
<p>The Exponent protocol enables the creation of yield derivatives and supporting liquidity, forming a yield trading market that allows users to convert variable yield into fixed-yield exposure, or to speculate on the future variable yield of an underlying token.</p>

<div class="mermaid-wrap"><pre class="mermaid">${mermaidDef}</pre></div>

<h4>Token Ecosystem</h4>
<p>The Exponent protocol operates by minting three token derivatives that are ultimately tied to base token capital: SY, PT, and YT.</p>
<ul>
  <li><strong>Base Tokens &rarr; SY</strong> &mdash; Base tokens are wrapped as SY ("standard yield") tokens. SY tokens can be redeemed for base tokens at any time. SY is not just an entry point into the protocol, it also serves as the liquidity pair in the AMM used to price fixed yield.</li>
  <li><strong>SY &rarr; PT + YT</strong> &mdash; SY tokens can be split into PT-YT token pairs. YT (Yield Token) represents the right to all variable yield that will accrue during the market's term. PT (Principal Token) represents the right to the principal at maturity, with its price determined by the fixed-yield AMM. PT-YT pairs are minted for a specific maturity and are linked to a specific SY token.</li>
</ul>

<h4>Token Claims and Convertibility</h4>
<ul>
  <li><strong>SY &harr; Base Token Conversion</strong> &mdash; The conversion rate between SY and the underlying base token is determined by the accumulated value of the underlying relative to its value when the SY was first minted. This rate is updated via oracle. In the case of a yield-bearing token such as eUSX, as long as the underlying continues to distribute yield and the principal remains intact, the value of 1 SY in base tokens will gradually increase over time.</li>
  <li><strong>SY &harr; PT-YT Conversion</strong> &mdash; SY is convertible into PT-YT token pairs on a fixed 1:1 basis (1 SY = 1 PT and 1 YT). Prior to maturity, PT-YT pairs can only be converted back into SY as complete pairs. At maturity and beyond, PT becomes directly redeemable on its own, at the SY-base exchange rate fixed at maturity. This enforces a 1 PT = 1 base token unit claim at maturity.</li>
  <li><strong>PT Pricing and Fixed Yield</strong> &mdash; PT can be bought and sold for base-token-redeemable SY on a dedicated AMM specific to each PT maturity, with SY as the liquidity pair. The AMM's pricing formula is adapted for yield trading by forcing the PT price toward 1 base token unit as maturity approaches and reducing price sensitivity to trades as maturity nears. The PT/Base price reflects the market-implied discount on principal and therefore defines the fixed yield available to PT buyers.</li>
  <li><strong>YT and Variable Yield Claims</strong> &mdash; YT holders are entitled to withdraw the variable yield portion of SY prior to market maturity, provided they stake their YT tokens into the protocol's staking contract. These mechanics imply that the claims on the SY tokens locked during PT-YT minting evolve over time. A portion becomes withdrawable as variable yield (via YT), and the remaining portion remains claimable through PT redemption at maturity.</li>
</ul>
`;
  }

  const configTableTooltips = {
    "Quote Currency": "On-chain address of the protocol pricing oracle. (Market level)",
    "User Borrow Limits": "Maximum total value an individual address can borrow from this market. (Market level)",
    "Risk Weight for Loan LTV": 'Risk weight applied to borrowed value when calculating collateral requirements. Referred to as the "borrow factor" by the protocol. All protocol health checks use borrow-factor-adjusted debt in LTV and HF calculations. (Reserve level \u2013 Borrowable assets)',
    "General New Loan LTV": "Collateral LTV used to set borrowing limits before borrow-factor risk adjustment. (Reserve level \u2013 Collateral assets)",
    "Unhealthy Threshold LTV": "LTV at which an obligation becomes marked as unhealthy and collateral becomes eligible for liquidation. (Reserve level \u2013 Collateral assets)",
    "Bad Debt Threshold LTV": "LTV at which an obligation is marked as at risk of insolvency and becomes eligible for full liquidation. (Market level)",
    "Unhealthy Loan Share Liquidatable": "Share of loan value eligible for liquidation when an obligation becomes unhealthy. (Market level)",
    "Small Loans Fully Liquidatable": "Loans below this market-value threshold are always liquidatable in full. (Market level)",
    "Max Amount Liquidatable [Any]": "Maximum loan value that can be liquidated in a single transaction. (Market level)",
    "Min Liquidation Fee": "Minimum liquidation bonus (in basis points) awarded to liquidators when an obligation becomes unhealthy; scales upward as LTV exceeds the liquidation threshold. (Reserve level \u2013 Borrowable assets)",
    "Max Liquidation Fee": "Maximum liquidation bonus (in basis points) that liquidators can receive for unhealthy positions; caps the incentive as insolvency risk is approached. (Reserve level \u2013 Borrowable assets)",
    "Bad Debt Liquidation Bonus": "Liquidation bonus (in basis points) applied when an obligation has bad debt, meaning borrowed value exceeds collateral value. (Reserve level \u2013 Borrowable assets)",
    "Aggregate Deposit Cap": "Absolute maximum total deposits allowed in this reserve; new deposits are blocked once this limit is reached. (Reserve level \u2013 Borrowable assets)",
    "Aggregate Borrow Cap": "Absolute maximum total borrows allowed from this reserve; new borrows are blocked once this limit is reached. (Reserve level \u2013 Borrowable assets)",
    "Deposit & Redeem Caps [24hr]": "Rolling 24-hour rate limit for net withdrawals or redemptions from this reserve to prevent rapid liquidity drain. (Reserve level \u2013 Borrowable assets)",
    "Borrow & Repay Cap [24hr]": "Rolling 24-hour rate limit for net new borrows from this reserve to control borrow velocity. (Reserve level \u2013 Borrowable assets)",
    "Market Utilization Limit": 'Utilization percentage above which new borrows are blocked. "None" means no utilization-based restriction is applied. (Reserve level \u2013 Borrowable assets)',
  };

  function escapeHtml(text) {
    const el = document.createElement("span");
    el.textContent = text;
    return el.innerHTML;
  }

  function renderPageActionTable(data) {
    if (!data || !data.columns || !data.rows) return "<p>No data.</p>";
    let html = '<table class="data-table" style="width:100%"><thead><tr>';
    for (const col of data.columns) {
      html += `<th>${col.label}</th>`;
    }
    html += "</tr></thead><tbody>";
    for (const row of data.rows) {
      const tip = configTableTooltips[row.term];
      const cls = tip ? ' class="has-row-tip"' : "";
      html += `<tr${cls}>`;
      for (const col of data.columns) {
        const val = row[col.key];
        const display = val === null || val === undefined ? "" : val;
        if (col.key === "term" && tip) {
          html += `<td><span class="row-tip-wrap">${escapeHtml(String(display))}<svg class="info-tip-icon" width="13" height="13" viewBox="0 0 16 16" fill="none"><circle cx="8" cy="8" r="7" stroke="currentColor" stroke-width="1.3"/><text x="8" y="12" text-anchor="middle" fill="currentColor" font-size="11" font-weight="600">i</text></svg><span class="info-tip-card">${escapeHtml(tip)}</span></span></td>`;
        } else {
          html += `<td>${display}</td>`;
        }
      }
      html += "</tr>";
    }
    html += "</tbody></table>";
    return html;
  }

  function bindRowTipPositioning(container) {
    const wraps = container.querySelectorAll(".row-tip-wrap");
    wraps.forEach((wrap) => {
      wrap.addEventListener("mouseenter", () => {
        const card = wrap.querySelector(".info-tip-card");
        if (!card) return;
        const iconRect = wrap.getBoundingClientRect();
        const cardW = 340;
        let left = iconRect.left;
        if (left + cardW > window.innerWidth - 12) {
          left = window.innerWidth - cardW - 12;
        }
        if (left < 12) left = 12;
        let top = iconRect.top - 6;
        card.style.left = left + "px";
        card.style.top = "";
        card.style.bottom = (window.innerHeight - top) + "px";
        card.style.display = "block";
      });
      wrap.addEventListener("mouseleave", () => {
        const card = wrap.querySelector(".info-tip-card");
        if (card) card.style.display = "";
      });
    });
  }

  async function handlePageActionClick(btn) {
    const actionId = btn.dataset.actionId;
    const modalKind = btn.dataset.modalKind;
    const endpoint = btn.dataset.endpoint || "";
    const label = btn.querySelector("span")?.textContent || "Details";

    if (actionId === "kamino-explainer") {
      openPageActionModal(label, buildExplainerHTML());
      if (window.mermaid) {
        await mermaid.run({ nodes: document.querySelectorAll(".page-action-modal-body .mermaid") });
      }
      return;
    }

    if (actionId === "exponent-explainer") {
      openPageActionModal(label, buildExplainerExponentHTML());
      if (window.mermaid) {
        await mermaid.run({ nodes: document.querySelectorAll(".page-action-modal-body .mermaid") });
      }
      return;
    }

    if (!endpoint) {
      openPageActionModal(label, "<p>No endpoint configured.</p>");
      return;
    }

    openPageActionModal(label, '<p style="color:var(--muted)">Loading…</p>');
    try {
      const actionUrl = new URL(endpoint, window.location.origin);
      const am1 = currentMkt1();
      const am2 = currentMkt2();
      if (am1) actionUrl.searchParams.set("mkt1", am1);
      if (am2) actionUrl.searchParams.set("mkt2", am2);
      const cacheKey = actionUrl.toString();
      const cached = pageActionCache.get(cacheKey);
      let data;
      if (cached && cached.expiresAt > Date.now()) {
        data = cached.payload;
      } else {
        const resp = await fetch(actionUrl);
        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
        data = await resp.json();
        pageActionCache.set(cacheKey, {
          expiresAt: Date.now() + PAGE_ACTION_CACHE_TTL_MS,
          payload: data,
        });
      }
      const tableData = data?.data || data;
      const { body } = pageActionModalEls();
      body.innerHTML = renderPageActionTable(tableData);
      bindRowTipPositioning(body);
    } catch (err) {
      const { body } = pageActionModalEls();
      body.innerHTML = `<p style="color:#ef4444">Failed to load data: ${err.message}</p>`;
    }
  }

  document.body.addEventListener("click", (event) => {
    const actionBtn = event.target.closest(".page-action-btn");
    if (actionBtn) {
      handlePageActionClick(actionBtn);
      return;
    }
    const paBackdrop = document.getElementById("page-action-modal-backdrop");
    if (paBackdrop && !paBackdrop.hidden) {
      const closeBtn = event.target.closest("#page-action-modal-close");
      if (closeBtn) { closePageActionModal(); return; }
      if (event.target === paBackdrop) { closePageActionModal(); }
    }
  });

  // ── Global health indicator (runs on every page) ──
  const HEALTH_POLL_INTERVAL_MS = 60_000;
  const HEALTH_RED_CONFIRM_RETRIES = 2;
  const HEALTH_RED_CONFIRM_DELAY_MS = 5_000;

  function initHealthIndicator() {
    const dot = document.querySelector("#health-indicator .health-dot");
    if (!dot) return;
    const url = "/api/health-status";

    function normalizeStatus(value) {
      if (value === true || value === false) return value;
      if (value == null) return null;
      if (typeof value === "number") return value !== 0;
      if (typeof value === "string") {
        const v = value.trim().toLowerCase();
        if (["true", "t", "1", "yes", "y", "on"].includes(v)) return true;
        if (["false", "f", "0", "no", "n", "off", ""].includes(v)) return false;
      }
      return null;
    }

    async function fetchStatus() {
      try {
        const res = await fetch(url);
        if (!res.ok) return null;
        const json = await res.json();
        return normalizeStatus(json.is_green);
      } catch {
        return null;
      }
    }

    async function poll() {
      let status = await fetchStatus();

      if (status === false) {
        for (let i = 0; i < HEALTH_RED_CONFIRM_RETRIES; i++) {
          await new Promise((r) => setTimeout(r, HEALTH_RED_CONFIRM_DELAY_MS));
          const retry = await fetchStatus();
          if (retry !== false) { status = retry; break; }
        }
      }

      dot.classList.remove("health-dot--unknown", "health-dot--green", "health-dot--red");
      if (status === true) dot.classList.add("health-dot--green");
      else if (status === false) dot.classList.add("health-dot--red");
      else dot.classList.add("health-dot--unknown");

      const label = status === true ? "All systems nominal" : status === false ? "Action required – click to view" : "Health status unavailable";
      dot.closest(".health-indicator").title = label;
    }

    poll();
    setInterval(poll, HEALTH_POLL_INTERVAL_MS);
  }

  document.addEventListener("DOMContentLoaded", () => {
    initPageSelector();
    initFilters();
    initHealthIndicator();
    if (window.mermaid) {
      mermaid.initialize({ startOnLoad: false, theme: "dark" });
    }
  });
})();
