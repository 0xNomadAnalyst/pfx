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
    ["linked-ts-global", new Set([
      "ge-issuance-time",
      "ge-yield-generation",
      "ge-yield-vesting-rate",
      "ge-yields-vs-time",
      "ge-token-avail-usx",
      "ge-token-avail-eusx",
      "ge-tvl-defi-usx",
      "ge-tvl-defi-eusx",
      "ge-tvl-share-usx",
      "ge-tvl-share-eusx",
      "ge-activity-vol-usx",
      "ge-activity-vol-eusx",
      "ge-activity-share-usx",
      "ge-activity-share-eusx",
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

  const defaultBucketIntervals = {
    "1h": "1 minute", "4h": "5 minutes", "6h": "5 minutes",
    "24h": "15 minutes", "7d": "1 hour", "30d": "4 hours", "90d": "12 hours",
  };
  const globalBucketIntervals = {
    "1h": "5 minutes", "4h": "15 minutes", "6h": "30 minutes",
    "24h": "1 hour", "7d": "4 hours", "30d": "1 day", "90d": "3 days",
  };
  const healthBucketIntervals = {
    "1h": "2 minutes", "4h": "5 minutes", "6h": "5 minutes",
    "24h": "30 minutes", "7d": "3 hours", "30d": "12 hours", "90d": "1 day",
  };
  const bucketIntervalsByGroup = {
    "linked-ts-global": globalBucketIntervals,
    "linked-ts-health-base": healthBucketIntervals,
  };
  const noIntervalSubtitle = new Set(["swaps-ohlcv"]);

  function bucketIntervalLabel(widgetId) {
    const groupId = getTimeseriesGroupId(widgetId);
    if (!groupId || noIntervalSubtitle.has(widgetId)) return null;
    const key = String(currentLastWindow() || "24h").toLowerCase();
    const mapping = bucketIntervalsByGroup[groupId] || defaultBucketIntervals;
    return mapping[key] || null;
  }

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

  function hexToRgba(hex, alpha) {
    if (!hex) return hex;
    let h = hex.replace("#", "");
    if (h.length === 3) h = h[0]+h[0]+h[1]+h[1]+h[2]+h[2];
    const r = parseInt(h.substring(0, 2), 16);
    const g = parseInt(h.substring(2, 4), 16);
    const b = parseInt(h.substring(4, 6), 16);
    if (isNaN(r) || isNaN(g) || isNaN(b)) return hex;
    return `rgba(${r},${g},${b},${alpha})`;
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

  function formatSigned4dp(value) {
    if (value === null || value === undefined || Number.isNaN(value)) {
      return "--";
    }
    const number = Number(value);
    if (!Number.isFinite(number)) {
      return "--";
    }
    const prefix = number > 0 ? "+" : "";
    return `${prefix}${number.toFixed(4)}`;
  }

  function currentLastWindowLabel() {
    const mapping = {
      "1h": "Last 1H",
      "4h": "Last 4H",
      "6h": "Last 6H",
      "24h": "Last 1D",
      "7d": "Last 7D",
      "30d": "Last 30D",
      "90d": "Last 90D",
    };
    const key = String(currentLastWindow() || "24h").toLowerCase();
    return mapping[key] || `Last ${key.toUpperCase()}`;
  }

  const MONTH_ABBR = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];

  function formatCompactTimestamp(value) {
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      return String(value);
    }
    const day = String(date.getDate()).padStart(2, "0");
    const mon = MONTH_ABBR[date.getMonth()];
    const hours = String(date.getHours()).padStart(2, "0");
    const minutes = String(date.getMinutes()).padStart(2, "0");
    return `${day}-${mon} ${hours}:${minutes}`;
  }

  function parseIsoDate(value) {
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? null : date;
  }

  function applyLinkedTimeseriesFormat(option) {
    const hasRightAxis = Array.isArray(option.yAxis) && option.yAxis.length > 1;
    const hasRightLabel = hasRightAxis && !!option.yAxis[1].name;
    option.grid = { ...(option.grid || {}), left: 68, right: 90, top: 14, bottom: 60, containLabel: false };

    if (option.xAxis && !Array.isArray(option.xAxis)) {
      option.xAxis.axisLabel = {
        ...(option.xAxis.axisLabel || {}),
        formatter: (value) => formatCompactTimestamp(value),
      };
    }

    const compactLabel = {
      width: 46,
      align: "right",
      padding: [0, 14, 0, 0],
      formatter: (v) => formatCompactMagnitude(v),
    };

    if (Array.isArray(option.yAxis)) {
      option.yAxis[0] = {
        ...option.yAxis[0],
        nameGap: option.yAxis[0].nameGap ? Math.max(option.yAxis[0].nameGap, 52) : 52,
        axisLabel: {
          ...(option.yAxis[0].axisLabel || {}),
          ...compactLabel,
        },
      };
    } else if (option.yAxis) {
      option.yAxis = {
        ...option.yAxis,
        nameGap: option.yAxis.nameGap ? Math.max(option.yAxis.nameGap, 52) : 52,
        axisLabel: {
          ...(option.yAxis.axisLabel || {}),
          ...compactLabel,
        },
      };
    }

    option.dataZoom = [
      { type: "inside", xAxisIndex: 0, filterMode: "none" },
      {
        type: "slider",
        xAxisIndex: 0,
        height: 10,
        bottom: 20,
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
    const { token0, token1 } = currentPairTokens();
    const lastLabel = currentLastWindowLabel();
    const lastLabelHtml = `<span style="color:#2fbf71">${lastLabel}</span>`;

    if (widgetId === "kpi-impact-500k") {
      primary.innerHTML = `<span style="color:var(--bad)">${formatSigned4dp(data.primary)}</span> / ${formatNumber(data.secondary)}`;
      secondary.innerHTML = `bps / ${token0}`;
    } else if (widgetId === "kpi-largest-impact" || widgetId === "kpi-average-impact") {
      primary.innerHTML = `<span style="color:var(--bad)">${formatSigned4dp(data.primary)}</span> / ${formatNumber(data.secondary)}`;
      secondary.innerHTML = `bps / ${token0}, ${lastLabelHtml}`;
    } else if (widgetId === "kpi-pool-balance") {
      primary.textContent = `${formatNumber(data.primary)}%`;
      secondary.textContent = `${formatNumber(data.secondary)}%`;
      if (secondary.textContent && secondary.textContent !== "--%") {
        primary.textContent = `${primary.textContent} / ${secondary.textContent}`;
      }
      secondary.textContent = `${token1} / ${token0}`;
    } else if (widgetId === "kpi-reserves") {
      const left = `${formatNumber(data.primary)}m`;
      const right = `${formatNumber(data.secondary)}m`;
      primary.textContent = `${left} / ${right}`;
      secondary.textContent = `${token1} / ${token0}`;
    } else if (widgetId === "kpi-swap-volume-24h") {
      const vol = formatNumber(data.primary);
      const pctTvl = data.secondary === null || data.secondary === undefined ? "--" : `${formatNumber(data.secondary)}%`;
      primary.textContent = `${vol} / ${pctTvl}`;
      secondary.textContent = `${token1} / % TVL`;
    } else if (widgetId === "kpi-price-min-max") {
      const maxValue = Number(data.primary);
      const minValue = Number(data.secondary);
      const maxStr = Number.isFinite(maxValue) ? maxValue.toFixed(4) : "--";
      const minStr = Number.isFinite(minValue) ? minValue.toFixed(4) : "--";
      primary.innerHTML = `<span style="color:#2fbf71">${maxStr}</span> / <span style="color:#e24c4c">${minStr}</span>`;
      secondary.innerHTML = `${token1} / ${token0}, ${lastLabelHtml}`;
    } else if (widgetId === "kpi-vwap-buy-sell") {
      const buy = Number(data.primary);
      const sell = Number(data.secondary);
      const buyStr = Number.isFinite(buy) ? buy.toFixed(4) : "--";
      const sellStr = Number.isFinite(sell) ? sell.toFixed(4) : "--";
      primary.innerHTML = `<span style="color:#2fbf71">${buyStr}</span> / <span style="color:#e24c4c">${sellStr}</span>`;
      secondary.innerHTML = `${token1} / ${token0}, ${lastLabelHtml}`;
    } else if (widgetId === "kpi-price-std-dev") {
      const stdDev = Number(data.primary);
      primary.textContent = Number.isFinite(stdDev) ? stdDev.toFixed(4) : "--";
      secondary.innerHTML = `${token1} / ${token0}, ${lastLabelHtml}`;
    } else if (widgetId === "kpi-vwap-spread") {
      const spread = Number(data.primary);
      primary.textContent = Number.isFinite(spread) ? spread.toFixed(4) : "--";
      secondary.innerHTML = `bps, ${lastLabelHtml}`;
    } else if (
      widgetId === "kpi-largest-usx-sell" ||
      widgetId === "kpi-largest-usx-buy" ||
      widgetId === "kpi-max-1h-sell-pressure" ||
      widgetId === "kpi-max-1h-buy-pressure"
    ) {
      const bpsValue = data.secondary === null || data.secondary === undefined ? null : Number(data.secondary);
      const bpsStr = formatSigned4dp(data.secondary);
      const bpsColor = bpsValue === null || !Number.isFinite(bpsValue) ? "" : bpsValue < 0 ? "#e24c4c" : "#2fbf71";
      const bpsHtml = bpsColor ? `<span style="color:${bpsColor}">${bpsStr}</span>` : bpsStr;
      primary.innerHTML = `${formatNumber(data.primary)} / ${bpsHtml}`;
      secondary.innerHTML = `${token0} / bps, ${lastLabelHtml}`;
    } else if (widgetId === "kpi-unhealthy-share") {
      const val = Number(data.primary);
      const formatted = formatNumber(data.primary);
      if (Number.isFinite(val) && val > 0) {
        primary.innerHTML = `<span style="color:var(--bad)">${formatted}%</span>`;
      } else {
        primary.textContent = formatted + "%";
      }
      secondary.textContent = data.secondary || "";
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
    if (columnKey === "bps_target" && numeric > 0) {
      return "+" + numeric;
    }
    if (columnKey === "liquidity_in_band" || columnKey === "swap_size_equivalent") {
      return numeric.toLocaleString(undefined, { maximumFractionDigits: 0 });
    }
    if (columnKey === "pct_of_reserve") {
      return numeric.toLocaleString(undefined, { maximumFractionDigits: 0 }) + "%";
    }
    return String(value);
  }

  function depthTableRowStyle(row) {
    const bps = Number(row.bps_target);
    if (!Number.isFinite(bps) || bps === 0) return "";
    const absBps = Math.abs(bps);
    const opacity = Math.max(0.06, 0.45 / Math.pow(absBps, 0.55));
    const color = bps > 0 ? "248, 169, 74" : "75, 183, 255";
    return ` style="background:rgba(${color},${opacity})"`;
  }

  const PAGINATED_TABLES = { "kamino-obligation-watchlist": 25 };

  const WATCHLIST_COLUMN_TOOLTIPS = {
    "loan_value_total": "The market value of all debt held by this obligation across all borrow assets, and its percentage share of total market debt.",
    "collateral_value_total": "The market value of all collateral held by this obligation across all collateral assets, and its percentage share of total market collateral.",
    "liquidation_buffer_pct": "The portion of borrowed value that exceeds the unhealthy HF = 1 threshold, expressed as a percentage of total debt.",
    "health_factor": "The health factor is the ratio of the unhealthy borrow limit (based on collateral composition and liquidation thresholds) divided by the borrow-factor-adjusted market value of debt. Positions become liquidatable when HF = 1.",
    "status": "Health status of each loan. \u201cNear Liquidation\u201d is used for HF between 1.0 and 1.1. \u201cUnhealthy\u201d follows the protocol definition of HF < 1 but above the insolvency-risk threshold. \u201cBad\u201d follows the protocol definition of HF at or below the insolvency-risk threshold.",
  };

  const WATCHLIST_LABEL_TOOLTIPS = {
    "loan value": WATCHLIST_COLUMN_TOOLTIPS["loan_value_total"],
    "collateral value": WATCHLIST_COLUMN_TOOLTIPS["collateral_value_total"],
    "liquidation buffer (%)": WATCHLIST_COLUMN_TOOLTIPS["liquidation_buffer_pct"],
    "liquidation buffer": WATCHLIST_COLUMN_TOOLTIPS["liquidation_buffer_pct"],
    "hf": WATCHLIST_COLUMN_TOOLTIPS["health_factor"],
    "status": WATCHLIST_COLUMN_TOOLTIPS["status"],
  };

  function watchlistColumnTooltip(key, label) {
    return WATCHLIST_COLUMN_TOOLTIPS[key]
      || WATCHLIST_LABEL_TOOLTIPS[(label || "").toLowerCase().trim()]
      || null;
  }

  const INFO_TIP_SVG = '<svg class="info-tip-icon" width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true" style="display:inline-block;vertical-align:-1px;margin-left:3px;opacity:0.4"><circle cx="8" cy="8" r="7" stroke="currentColor" stroke-width="1.3"/><text x="8" y="12" text-anchor="middle" fill="currentColor" font-size="11" font-weight="600">i</text></svg>';

  function statusCellStyle(value) {
    const v = String(value || "").toLowerCase().trim();
    if (v === "unhealthy") return ' style="color:#ef4444;font-weight:600"';
    if (v === "near liquidation") return ' style="color:#f5a623;font-weight:600"';
    if (v === "healthy") return ' style="color:#36c96a;font-weight:600"';
    return "";
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
    const isDepthTable = widgetId === "liquidity-depth-table";
    const isWatchlist = widgetId === "kamino-obligation-watchlist";
    const normalizedColumns = normalizeColumns(widgetId, columns);
    const visibleColumns = normalizedColumns.filter((c) => c.key !== "is_red");
    const header = visibleColumns.map((column) => {
      const label = pairAwareLabel(column.label);
      if (isWatchlist) {
        const tip = watchlistColumnTooltip(column.key, column.label);
        if (tip) {
          return `<th><span class="info-tip-wrap">${label}${INFO_TIP_SVG}<span class="info-tip-card">${tip}</span></span></th>`;
        }
      }
      return `<th>${label}</th>`;
    }).join("");

    const pageSize = PAGINATED_TABLES[widgetId];

    const WATCHLIST_SCALED_BAR_KEYS = new Set(["loan_value_total"]);
    const WATCHLIST_SCALED_BAR_LABELS = new Set(["loan value"]);

    function isScaledBarCol(col) {
      return WATCHLIST_SCALED_BAR_KEYS.has(col.key) || WATCHLIST_SCALED_BAR_LABELS.has((col.label || "").toLowerCase().trim());
    }

    function buildBody(displayRows) {
      let scaledBarMax = 0;
      if (isWatchlist) {
        const barCol = visibleColumns.find((c) => isScaledBarCol(c));
        if (barCol) {
          scaledBarMax = displayRows.reduce((mx, r) => {
            const v = Number(r[barCol.key]);
            return Number.isFinite(v) && v > mx ? v : mx;
          }, 0);
        }
      }

      return displayRows
        .map((row) => {
          let rowAttr = "";
          if (isHealthTable && row.is_red) {
            rowAttr = ' class="health-row-red"';
          } else if (isDepthTable) {
            rowAttr = depthTableRowStyle(row);
          }
          const cells = visibleColumns
            .map((column) => {
              const raw = row[column.key];
              const value = widgetId === "liquidity-depth-table" ? formatDepthTableValue(column.key, raw) : (raw ?? "");
              const displayValue = typeof value === "string" ? pairAwareLabel(value) : value;
              if (column.key === "signature" && displayValue) {
                const signature = String(displayValue);
                const href = `https://solscan.io/tx/${encodeURIComponent(signature)}`;
                return (
                  `<td>` +
                  `<a href="${href}" target="_blank" rel="noopener noreferrer">${signature}</a>` +
                  `</td>`
                );
              }
              if (isWatchlist && (column.key === "ltv_pct" || (column.label || "").toLowerCase() === "ltv (%)")) {
                const pct = Number(raw);
                const w = Number.isFinite(pct) ? Math.min(Math.max(pct, 0), 100) : 0;
                return (
                  `<td><div class="microbar-cell">` +
                  `<div class="microbar-fill" style="width:${w}%"></div>` +
                  `<span class="microbar-label">${displayValue}</span>` +
                  `</div></td>`
                );
              }
              if (isWatchlist && isScaledBarCol(column) && scaledBarMax > 0) {
                const num = Number(raw);
                const w = Number.isFinite(num) ? Math.min((num / scaledBarMax) * 100, 100) : 0;
                return (
                  `<td><div class="microbar-cell microbar-blue">` +
                  `<div class="microbar-fill" style="width:${w.toFixed(1)}%"></div>` +
                  `<span class="microbar-label">${displayValue}</span>` +
                  `</div></td>`
                );
              }
              const statusStyle = column.key === "status" ? statusCellStyle(displayValue) : "";
              return `<td${statusStyle}>${displayValue}</td>`;
            })
            .join("");
          return `<tr${rowAttr}>${cells}</tr>`;
        })
        .join("");
    }

    if (pageSize && rows.length > pageSize) {
      let currentPage = 0;
      const totalPages = Math.ceil(rows.length / pageSize);

      function renderPage() {
        const start = currentPage * pageSize;
        const pageRows = rows.slice(start, start + pageSize);
        const body = buildBody(pageRows);
        const prevDisabled = currentPage === 0 ? " disabled" : "";
        const nextDisabled = currentPage >= totalPages - 1 ? " disabled" : "";
        target.innerHTML =
          `<table><thead><tr>${header}</tr></thead><tbody>${body}</tbody></table>` +
          `<div class="table-pagination">` +
          `<button class="pagination-btn" data-dir="prev"${prevDisabled}>Previous</button>` +
          `<span class="pagination-info">Page ${currentPage + 1}</span>` +
          `<button class="pagination-btn" data-dir="next"${nextDisabled}>Next</button>` +
          `</div>`;
        target.querySelector('.pagination-btn[data-dir="prev"]')?.addEventListener("click", () => {
          if (currentPage > 0) { currentPage--; renderPage(); }
        });
        target.querySelector('.pagination-btn[data-dir="next"]')?.addEventListener("click", () => {
          if (currentPage < totalPages - 1) { currentPage++; renderPage(); }
        });
      }
      renderPage();
    } else {
      const body = buildBody(rows);
      target.innerHTML = `<table><thead><tr>${header}</tr></thead><tbody>${body}</tbody></table>`;
    }
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
    const hasBars = (data.series || []).some((s) => s.type === "bar");
    const rightPad = dual ? (hasYRightLabel ? 60 : 50) : (hasBars ? 30 : 18);
    const option = {
      color: palette(),
      tooltip: { trigger: "axis" },
      legend: { bottom: -4, textStyle: { color: chartTextColor() } },
      grid: { left: hasYLabel ? 60 : 40, right: rightPad, top: 22, bottom: hasXLabel ? 72 : 60, containLabel: true },
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
          margin: 14,
          formatter: xFmt || ((value) => formatPrice4dp(value)),
          hideOverlap: true,
        },
      },
      yAxis: hasDualAxis(data) ? [
        {
          type: "value",
          name: yLabel || undefined,
          nameLocation: "middle",
          nameGap: hasYLabel ? 52 : undefined,
          nameTextStyle: hasYLabel ? { color: chartTextColor(), fontSize: 12 } : undefined,
          axisLine: { lineStyle: { color: chartGridColor() } },
          splitLine: { lineStyle: { color: chartGridColor() } },
          axisLabel: { color: chartTextColor(), fontSize: 11, formatter: yFmt || undefined },
        },
        {
          type: "value",
          name: yRightLabel || undefined,
          nameLocation: "middle",
          nameGap: hasYRightLabel ? 46 : undefined,
          nameTextStyle: hasYRightLabel ? { color: chartTextColor(), fontSize: 12 } : undefined,
          axisLine: { lineStyle: { color: chartGridColor() } },
          splitLine: { show: false },
          axisLabel: { color: chartTextColor(), fontSize: 11, formatter: axisFormatter(data.yRightAxisFormat) || undefined },
        },
      ] : {
        type: "value",
        name: yLabel || undefined,
        nameLocation: "middle",
        nameGap: hasYLabel ? 52 : undefined,
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
        if (series.barCategoryGap !== undefined) {
          mapped.barCategoryGap = series.barCategoryGap;
        }
        if (series.connectNulls !== undefined) {
          mapped.connectNulls = Boolean(series.connectNulls);
        } else if (mapped.type === "line") {
          mapped.connectNulls = true;
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
      const lastWindow = currentLastWindow();
      chartData = trimOhlcvToLastWindow(chartData, lastWindow);
      const xs = chartData.x;
      if (Array.isArray(xs) && xs.length >= 2) {
        const first = parseIsoDate(xs[0]);
        const last = parseIsoDate(xs[xs.length - 1]);
        const expectedMs = windowMsFromLastWindow(lastWindow);
        if (first && last && expectedMs > 0) {
          const spanMs = last.getTime() - first.getTime();
          const prev = chartState.get(widgetId);
          const prevLen = prev?.data?.x?.length || 0;
          if (spanMs < expectedMs * 0.85 && prevLen >= xs.length) {
            return;
          }
        }
      }
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
      const { token0: ohlcToken0, token1: ohlcToken1 } = currentPairTokens();
      const ohlcLegendIcon = "image://data:image/svg+xml," + encodeURIComponent(
        '<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14">'
        + '<polygon points="0,0 14,0 0,14" fill="#2fbf71"/>'
        + '<polygon points="14,0 14,14 0,14" fill="#e24c4c"/>'
        + '</svg>'
      );
      option = {
        color: palette(),
        legend: {
          data: [
            { name: "OHLC", icon: ohlcLegendIcon },
            "Volume",
          ],
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
          { left: 82, right: 88, top: 14, height: "48%", containLabel: false },
          { left: 82, right: 88, top: "64%", height: "16%", containLabel: false },
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
            name: `${ohlcToken1} / ${ohlcToken0}`,
            nameLocation: "middle",
            nameGap: 70,
            nameTextStyle: { color: chartTextColor(), fontSize: 11 },
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
            name: `Vol. (${ohlcToken1})`,
            nameLocation: "middle",
            nameGap: 70,
            nameTextStyle: { color: chartTextColor(), fontSize: 11 },
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
          if (s.type === "line") mapped.connectNulls = true;
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
          stack: "all",
        };
        if (barWidth) {
          mapped.barWidth = barWidth;
        }
        if (series.color) {
          mapped.itemStyle = { color: hexToRgba(series.color, 0.2), borderColor: series.color, borderWidth: 2 };
        }
        return mapped;
      });
      if (legendGroups.length > 0) {
        legendGroups.forEach((group) => {
          option.series.push({
            name: group.title,
            type: "bar",
            data: [],
            stack: "all",
            silent: true,
            itemStyle: { color: "transparent" },
            tooltip: { show: false },
          });
        });
      }
      const catCount = (chartData.x || []).length;
      if (catCount <= 3) {
        option.yAxis.axisTick = { alignWithLabel: true };
        option.series.forEach((s) => {
          if (s.type === "bar") {
            s.barWidth = "50%";
          }
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
      const hmXLabel = pairAwareLabel(chartData.xAxisLabel) || pairAwareLabel("Price (USDC per USX)");

      const hmSubEl = document.getElementById(`chart-subtitle-${widgetId}`);
      if (hmSubEl) {
        const windowLabel = currentLastWindowLabel();
        const added = chartData.gross_added != null ? Number(chartData.gross_added) : null;
        const removed = chartData.gross_removed != null ? Number(chartData.gross_removed) : null;
        const grossTotal = chartData.gross_turnover != null ? Number(chartData.gross_turnover) : null;
        const totalChange = chartData.total_change != null ? Number(chartData.total_change) : null;
        const { token1 } = currentPairTokens();
        let line = `<span style="color:#2fbf71">Change over ${windowLabel.replace(/^Last\s*/i, "last ")}</span>`;
        if (added != null || removed != null) {
          const metrics = [];
          if (added != null) metrics.push(`Added: ${formatNumber(Math.round(added))}`);
          if (removed != null) metrics.push(`Removed: ${formatNumber(Math.round(removed))}`);
          if (grossTotal != null) metrics.push(`Total: ${formatNumber(Math.round(grossTotal))}`);
          line += `<br>${metrics.join(" | ")} (valued in current ${token1})`;
        } else if (totalChange != null) {
          line += `<br>Total change: ${formatNumber(Math.round(totalChange))} (valued in current ${token1})`;
        }
        hmSubEl.innerHTML = line;
      }

      option = {
        color: palette(),
        tooltip: { position: "top" },
        grid: { left: 82, right: 18, top: 16, bottom: 76, containLabel: false },
        xAxis: {
          type: "category",
          data: chartData.x || [],
          boundaryGap: false,
          name: hmXLabel,
          nameLocation: "middle",
          nameGap: 36,
          nameTextStyle: { color: chartTextColor(), fontSize: 12 },
          axisLine: { lineStyle: { color: chartGridColor() } },
          axisLabel: {
            color: chartTextColor(),
            fontSize: 11,
            margin: 14,
            formatter: (value) => "$" + formatPrice4dp(value),
            hideOverlap: true,
          },
        },
        yAxis: {
          type: "category",
          data: [" "],
          name: "% Total Change",
          nameLocation: "middle",
          nameGap: 58,
          nameTextStyle: { color: chartTextColor(), fontSize: 11 },
          axisLabel: { show: false },
        },
        visualMap: {
          show: false,
          min: minValue,
          max: maxValue,
          inRange: {
            color: [
              "rgba(143, 0, 14, 0.95)",
              "rgba(226, 76, 76, 0.7)",
              "rgba(255, 255, 255, 0.02)",
              "rgba(36, 179, 107, 0.7)",
              "rgba(4, 109, 67, 0.95)",
            ],
          },
        },
        _heatmapLegend: { left: leftLegend, right: rightLegend },
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
      const topPad = arrows ? 52 : 22;
      const areaYLabel = pairAwareLabel(chartData.yAxisLabel) || (arrows ? "Debt Value ($)" : "");
      const areaXLabel = pairAwareLabel(chartData.xAxisLabel) || "";
      const areaYFmt = axisFormatter(chartData.yAxisFormat);
      const defaultYFmt = arrows
        ? (v) => { if (Math.abs(v) >= 1e6) return "$" + (v / 1e6).toFixed(1) + "M"; if (Math.abs(v) >= 1e3) return "$" + (v / 1e3).toFixed(0) + "k"; return "$" + v; }
        : undefined;
      const defaultXFmt = arrows
        ? (v) => { const n = Number(v); return Number.isFinite(n) ? (n >= 0 ? "+" : "") + n.toFixed(1) : v; }
        : (v) => formatPrice4dp(v);
      const stressXFmt = arrows
        ? (value, index) => {
            const n = Number(value);
            if (!Number.isFinite(n)) return value;
            if (n === 0) return "0";
            const s = (n >= 0 ? "+" : "") + (n % 1 === 0 ? n.toFixed(0) : n.toFixed(1));
            return s;
          }
        : defaultXFmt;
      const stressXInterval = arrows
        ? (() => {
            const xNums = (chartData.x || []).map(Number).filter(Number.isFinite);
            const range = xNums.length > 1 ? Math.max(...xNums) - Math.min(...xNums) : 0;
            const step = range > 60 ? 10 : range > 20 ? 5 : 2;
            return (index, value) => {
              const n = Number(value);
              if (n === 0) return true;
              return Number.isFinite(n) && Math.abs(Math.abs(n) % step) < 0.01;
            };
          })()
        : undefined;
      option = {
        color: palette(),
        tooltip: { trigger: "axis" },
        legend: { bottom: 2, textStyle: { color: chartTextColor() } },
        grid: { left: areaYLabel ? 60 : 50, right: 18, top: topPad, bottom: areaXLabel ? 72 : 60, containLabel: true },
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
            formatter: stressXFmt,
            interval: stressXInterval,
            hideOverlap: arrows ? false : true,
          },
        },
        yAxis: {
          type: "value",
          name: areaYLabel || undefined,
          nameLocation: "middle",
          nameGap: areaYLabel ? 55 : undefined,
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
          if (mapped.type === "line") mapped.connectNulls = true;
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
        const tc = chartTextColor();
        const subTc = document.documentElement.getAttribute("data-theme") === "light" ? "#8899aa" : "#6b7a8d";
        option.graphic = [
          {
            type: "text",
            left: 8,
            top: 4,
            style: {
              text: `\u2190  Decrease in Collateral Value\n{sub|${arrows.left}}`,
              fill: tc,
              fontSize: 11,
              lineHeight: 16,
              rich: { sub: { fontSize: 9, fill: subTc, lineHeight: 14 } },
            },
          },
          {
            type: "text",
            right: 8,
            top: 4,
            style: {
              text: `Increase in Debt Value  \u2192\n{sub|${arrows.right}}`,
              fill: tc,
              fontSize: 11,
              lineHeight: 16,
              textAlign: "right",
              rich: { sub: { fontSize: 9, fill: subTc, lineHeight: 14, textAlign: "right" } },
            },
          },
        ];

      }
      if (Array.isArray(chartData.volatility_lines) && chartData.volatility_lines.length > 0) {
        const xLabels = (chartData.x || []).map(String);
        const isDark = document.documentElement.getAttribute("data-theme") !== "light";
        const labelBg = isDark ? "rgba(0,0,0,0.65)" : "rgba(255,255,255,0.85)";
        const volSeries = option.series.find((s) => s.data && s.data.length > 0) || option.series[0];
        if (volSeries) {
          const resolved = chartData.volatility_lines.map((vl) => {
            const closest = xLabels.reduce((best, lbl, idx) => {
              const diff = Math.abs(parseFloat(lbl) - vl.value);
              return diff < best.diff ? { idx, diff } : best;
            }, { idx: 0, diff: Infinity });
            return { ...vl, xIdx: closest.idx, isNeg: vl.value < 0 };
          });
          const usedPositions = {};
          volSeries.markLine = {
            silent: true,
            symbol: "none",
            data: resolved.map((vl) => {
              const sigmaName = vl.label || (Math.abs(vl.value).toFixed(1) + "%");
              const absVal = Math.abs(Number(vl.value));
              let dp = 1;
              while (dp < 6 && Number(absVal.toFixed(dp)) === 0) dp++;
              const pctValue = (vl.value >= 0 ? "+" : "-") + absVal.toFixed(dp) + "%";
              const sigmaLabel = `${sigmaName}:\n{val|${pctValue}}`;
              const side = vl.isNeg ? "neg" : "pos";
              const posKey = `${side}_${vl.xIdx}`;
              const slot = usedPositions[posKey] || 0;
              usedPositions[posKey] = slot + 1;
              return {
                xAxis: vl.xIdx,
                lineStyle: { type: "dashed", color: vl.color || "#28c987", width: slot === 0 ? 2 : 1 },
                label: {
                  show: slot === 0,
                  formatter: sigmaLabel,
                  position: "end",
                  rotate: 0,
                  align: vl.isNeg ? "right" : "left",
                  distance: vl.isNeg ? [8, 0] : [-8, 0],
                  color: vl.color || "#28c987",
                  fontSize: 10,
                  lineHeight: 13,
                  backgroundColor: labelBg,
                  padding: [2, 4],
                  borderRadius: 3,
                  rich: {
                    val: {
                      fontSize: 10,
                      color: vl.color || "#28c987",
                      lineHeight: 13,
                    },
                  },
                },
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
              itemStyle: s.color ? { color: hexToRgba(s.color, 0.2), borderColor: s.color, borderWidth: 2 } : undefined,
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
            lineStyle: { type: "dashed", color: "#28c987", width: 2 },
            label: { show: true, formatter: "Now", color: "#28c987", fontSize: 12, fontWeight: "bold", position: "start" },
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
              const barColor = api.visual("color");
              return {
                type: "rect",
                shape: { x: startPx[0], y: startPx[1] - barH / 2, width: endPx[0] - startPx[0], height: barH },
                style: { ...api.style(), fill: hexToRgba(barColor, 0.2), stroke: barColor, lineWidth: 2 },
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
        const xValues = Array.isArray(chartData?.x) ? chartData.x : [];
        const refs = chartData?.reference_lines || {};
        const activePrice = Number(refs.current_price);
        const activeIdx = Number.isFinite(activePrice) ? nearestCategoryIndex(xValues, activePrice) : null;
        option.series = (option.series || []).map((series) => ({
          ...series,
          data: (series.data || []).map((value, i) => {
            if (activeIdx !== null && i === activeIdx) return null;
            const numeric = Number(value);
            return Number.isFinite(numeric) ? numeric : null;
          }),
          connectNulls: true,
        }));
      }
      if (comparableLiquidityWidgets.has(widgetId)) {
        option.grid.left = 82;
        option.grid.right = 18;
        option.grid.bottom = chartData.xAxisLabel ? 96 : 64;
        option.grid.containLabel = false;
        if (!Array.isArray(option.yAxis)) {
          option.yAxis.nameGap = option.yAxis.name ? 58 : undefined;
          option.yAxis.axisLabel = {
            ...option.yAxis.axisLabel,
            width: 62,
            align: "right",
            padding: [0, 8, 0, 0],
          };
        }
        option.xAxis.axisLabel = {
          ...option.xAxis.axisLabel,
          fontSize: 10,
          formatter: (value) => "$" + formatPrice4dp(value),
          margin: 10,
          hideOverlap: true,
        };
        if (option.xAxis.name) {
          option.xAxis.nameGap = 26;
        }
      }
      if (widgetId === "kamino-liability-flows" || widgetId === "kamino-liquidations") {
        const isDark = document.documentElement.getAttribute("data-theme") !== "light";
        const netFlowColor = isDark ? "#ffffff" : "#1a1a2e";
        (option.series || []).forEach((s) => {
          if (/net\s*flow/i.test(s.name)) {
            s.itemStyle = { color: netFlowColor };
            s.lineStyle = { ...(s.lineStyle || {}), color: netFlowColor, width: 2 };
            s.showSymbol = true;
            s.symbolSize = 4;
          }
        });
      }
      if (option.xAxis && !Array.isArray(option.xAxis)) {
        const seriesList = Array.isArray(option.series) ? option.series : [];
        const hasBarSeries = seriesList.some((series) => series?.type === "bar");
        option.xAxis.boundaryGap = hasBarSeries;
      }
      if (widgetId === "liquidity-distribution") {
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
            bottom: 44,
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
        const { token1 } = currentPairTokens();
        option.yAxis = [
          {
            type: "value",
            name: token1,
            nameLocation: "middle",
            nameGap: 42,
            nameTextStyle: { color: chartTextColor(), fontSize: 12 },
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
            axisLabel: { color: chartTextColor(), width: 46, align: "right", padding: [0, 8, 0, 0], formatter: (v) => formatCompactMagnitude(v) },
          },
          {
            type: "value",
            name: "Share of Reserve",
            nameLocation: "middle",
            nameGap: 72,
            nameTextStyle: { color: chartTextColor(), fontSize: 12 },
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
              padding: [0, 0, 0, 16],
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
        const flowYLabel = pairAwareLabel(chartData.yAxisLabel) || "";
        const flowYRightLabel = pairAwareLabel(chartData.yRightAxisLabel) || "";
        option.yAxis = [
          {
            type: "value",
            name: flowYLabel || undefined,
            nameLocation: "middle",
            nameGap: flowYLabel ? 58 : undefined,
            nameTextStyle: flowYLabel ? { color: chartTextColor(), fontSize: 11 } : undefined,
            axisLine: { lineStyle: { color: chartGridColor() } },
            splitLine: { lineStyle: { color: chartGridColor() } },
            axisLabel: { color: chartTextColor(), width: 62, align: "right", padding: [0, 8, 0, 0], formatter: (v) => formatCompactMagnitude(v) },
          },
          {
            type: "value",
            position: "right",
            name: flowYRightLabel || undefined,
            nameLocation: "middle",
            nameGap: flowYRightLabel ? 36 : undefined,
            nameTextStyle: flowYRightLabel ? { color: chartTextColor(), fontSize: 11 } : undefined,
            axisLine: { lineStyle: { color: chartGridColor() } },
            splitLine: { show: false },
            axisLabel: { color: chartTextColor(), formatter: (value) => Math.round(Number(value)).toString() },
          },
        ];
        option.grid = { ...(option.grid || {}), right: 90 };
      }
      if (widgetId === "swaps-price-impacts") {
        const impactYLabel = pairAwareLabel(chartData.yAxisLabel) || "";
        option.yAxis = {
          type: "value",
          name: impactYLabel || undefined,
          nameLocation: "middle",
          nameGap: impactYLabel ? 58 : undefined,
          nameTextStyle: impactYLabel ? { color: chartTextColor(), fontSize: 11 } : undefined,
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
        option.grid = { ...(option.grid || {}), right: 90 };
      }
      if (widgetId === "swaps-spread-volatility") {
        const spreadYLabel = pairAwareLabel(chartData.yAxisLabel) || "";
        const spreadYRightLabel = pairAwareLabel(chartData.yRightAxisLabel) || "";
        option.yAxis = [
          {
            type: "value",
            name: spreadYLabel || undefined,
            nameLocation: "middle",
            nameGap: spreadYLabel ? 58 : undefined,
            nameTextStyle: spreadYLabel ? { color: chartTextColor(), fontSize: 11 } : undefined,
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
            name: spreadYRightLabel || undefined,
            nameLocation: "middle",
            nameGap: spreadYRightLabel ? 68 : undefined,
            nameTextStyle: spreadYRightLabel ? { color: chartTextColor(), fontSize: 11 } : undefined,
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
        option.grid = { ...(option.grid || {}), right: 90 };
      }
      if (
        widgetId === "swaps-sell-usx-distribution" ||
        widgetId === "swaps-1h-net-sell-pressure-distribution" ||
        widgetId === "swaps-distribution-toggle"
      ) {
        const distYLabel = pairAwareLabel(chartData.yAxisLabel) || "";
        const distYRightLabel = pairAwareLabel(chartData.yRightAxisLabel) || "";
        const distLabelFontSize = 11;
        const distLineHeight = 16;
        const distLabelMargin = 6;
        const distGridBottom = 26 + distLabelMargin + distLineHeight * 2;
        option.xAxis = {
          ...option.xAxis,
          boundaryGap: true,
          axisLabel: {
            ...option.xAxis.axisLabel,
            margin: distLabelMargin,
            lineHeight: distLineHeight,
            fontSize: distLabelFontSize,
            formatter: (value) => value,
          },
        };
        option.grid = {
          ...option.grid,
          left: 72,
          right: distYRightLabel ? 70 : 52,
          bottom: distGridBottom,
          containLabel: false,
        };
        option.yAxis = [
          {
            type: "value",
            name: distYLabel || undefined,
            nameLocation: "middle",
            nameGap: distYLabel ? 48 : undefined,
            nameTextStyle: distYLabel ? { color: chartTextColor(), fontSize: 11 } : undefined,
            axisLine: { lineStyle: { color: chartGridColor() } },
            splitLine: { lineStyle: { color: chartGridColor() } },
            axisLabel: { color: chartTextColor(), formatter: (value) => Math.round(Number(value)).toString() },
          },
          {
            type: "value",
            position: "right",
            name: distYRightLabel || undefined,
            nameLocation: "middle",
            nameGap: distYRightLabel ? 56 : undefined,
            nameTextStyle: distYRightLabel ? { color: chartTextColor(), fontSize: 11 } : undefined,
            axisLine: { lineStyle: { color: chartGridColor() } },
            splitLine: { show: false },
            axisLabel: { color: chartTextColor(), formatter: (value) => Number(value).toFixed(2) },
          },
        ];
        const row1Bottom = distGridBottom - distLabelMargin - distLineHeight;
        const row2Bottom = row1Bottom - distLineHeight;
        option.graphic = [
          {
            type: "text",
            left: 4,
            bottom: row1Bottom,
            style: { text: "U Bound", fill: chartTextColor(), fontSize: distLabelFontSize, textAlign: "left", textVerticalAlign: "top" },
          },
          {
            type: "text",
            left: 4,
            bottom: row2Bottom,
            style: { text: "Percentile", fill: chartTextColor(), fontSize: distLabelFontSize, textAlign: "left", textVerticalAlign: "top" },
          },
        ];
      }
    }

    instance.setOption(option, true);



    if (option._heatmapLegend) {
      const legendId = `heatmap-legend-${widgetId}`;
      let legendEl = document.getElementById(legendId);
      if (!legendEl) {
        const chartEl = document.getElementById(`chart-${widgetId}`);
        if (chartEl) {
          legendEl = document.createElement("div");
          legendEl.id = legendId;
          legendEl.className = "heatmap-legend";
          chartEl.parentNode.insertBefore(legendEl, chartEl.nextSibling);
        }
      }
      if (legendEl) {
        const { left, right } = option._heatmapLegend;
        legendEl.innerHTML =
          `<span class="heatmap-legend-label">${left}</span>` +
          `<span class="heatmap-legend-bar"></span>` +
          `<span class="heatmap-legend-label">${right}</span>`;
      }
    }

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

    // Backward-compat: some API instances may still return a single table
    // with a "side" column for swaps-ranked-events. Force split-table layout.
    if (
      widgetId === "swaps-ranked-events" &&
      kind === "table" &&
      Array.isArray(payload?.data?.rows) &&
      payload.data.rows.some((row) => row && row.side !== undefined)
    ) {
      const rows = payload.data.rows || [];
      const leftRows = rows.filter((row) => String(row?.side || "").toLowerCase().includes("buy"));
      const rightRows = rows.filter((row) => String(row?.side || "").toLowerCase().includes("sell"));
      const baseColumns = (payload.data.columns || []).filter((col) => col?.key !== "side");
      const columns = baseColumns.length
        ? baseColumns
        : [
            { key: "tx_time", label: "Time" },
            { key: "primary_flow", label: "Swap Amount" },
            { key: "primary_flow_impact_bps_now", label: "Est. Price Impact Now" },
            { key: "signature", label: "Tx Signature" },
          ];

      const leftTitleEl = document.getElementById(`table-left-title-${widgetId}`);
      const rightTitleEl = document.getElementById(`table-right-title-${widgetId}`);
      if (leftTitleEl) {
        leftTitleEl.textContent = pairAwareLabel("USX Bought");
      }
      if (rightTitleEl) {
        rightTitleEl.textContent = pairAwareLabel("USX Sold");
      }
      renderTable(widgetId, `table-left-${widgetId}`, columns, leftRows);
      renderTable(widgetId, `table-right-${widgetId}`, columns, rightRows);
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
      if (widgetId === "liquidity-depth-table") {
        const dtTitleEl = document.querySelector(`#widget-${widgetId} .panel-title-group h3`);
        if (dtTitleEl) {
          const { token0, token1 } = currentPairTokens();
          const base = dtTitleEl.dataset.baseTitle || dtTitleEl.textContent || "";
          dtTitleEl.innerHTML = `${pairAwareLabel(base)} `
            + `<span style="color:var(--text-secondary,#6b7a8d);font-weight:400">|</span> `
            + `<span class="depth-table-legend">`
            + `<span class="depth-legend-swatch" style="background:#4bb7ff"></span>${token1} Liquidity`
            + `<span class="depth-legend-swatch" style="background:#f8a94a"></span>${token0} Liquidity`
            + `</span>`;
        }
      }
      return;
    }

    if (kind === "table-split") {
      const columns = payload.data.columns || [];
      document.getElementById(`table-left-title-${widgetId}`).textContent = pairAwareLabel(payload.data.left_title || "Left");
      document.getElementById(`table-right-title-${widgetId}`).textContent = pairAwareLabel(payload.data.right_title || "Right");
      renderTable(widgetId, `table-left-${widgetId}`, columns, payload.data.left_rows || []);
      renderTable(widgetId, `table-right-${widgetId}`, columns, payload.data.right_rows || []);
      const splitTitleEl = document.querySelector(`#widget-${widgetId} .panel-header h3`);
      if (splitTitleEl) {
        const baseTitle = splitTitleEl.dataset.baseTitle || splitTitleEl.textContent || "";
        splitTitleEl.innerHTML = `${pairAwareLabel(baseTitle)} <span style="color:var(--text-secondary,#6b7a8d);font-weight:400">|</span> <span style="color:#2fbf71">${currentLastWindowLabel()}</span>`;
      }
      return;
    }

    const chartSubEl = document.getElementById(`chart-subtitle-${widgetId}`);
    if (chartSubEl) {
      if (payload.data.event_count != null) {
        const noun = payload.data.event_noun || "Events";
        const windowLabel = currentLastWindowLabel().replace(/^Last\s*/i, "");
        const pctSuffix = payload.data.event_pct != null ? ` (${payload.data.event_pct}%)` : "";
        chartSubEl.textContent = `${Number(payload.data.event_count).toLocaleString()} ${noun} in ${windowLabel} Sample${pctSuffix}`;
      } else {
        const interval = bucketIntervalLabel(widgetId);
        chartSubEl.textContent = interval ? `Reported at ${interval} intervals` : "";
      }
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
      const short = String(message || "unknown error").slice(0, 60).replace(/\s+/g, " ");
      el.textContent = `error: ${short}`;
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
    const attr = document.body.dataset.apiBaseUrl;
    return attr != null ? attr : "";
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
    const val = select ? select.value : "";
    return val === "__none__" ? "" : val;
  }

  function currentMkt2() {
    const select = document.getElementById("mkt2-select");
    const val = select ? select.value : "";
    return val === "__none__" ? "" : val;
  }

  function isMarketDisabled(widgetId) {
    const mkt1Select = document.getElementById("mkt1-select");
    const mkt2Select = document.getElementById("mkt2-select");
    if (!mkt1Select && !mkt2Select) return false;
    if (widgetId.endsWith("-mkt1") && mkt1Select && mkt1Select.value === "__none__") return true;
    if (widgetId.endsWith("-mkt2") && mkt2Select && mkt2Select.value === "__none__") return true;
    return false;
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

  function setSelectOptions(selectEl, values, selected, includeNone) {
    if (!selectEl) {
      return;
    }
    const unique = Array.from(new Set(values.filter(Boolean)));
    let options = "";
    if (includeNone) {
      options += '<option value="__none__">None</option>';
    }
    options += unique.map((value) => `<option value="${value}">${value}</option>`).join("");
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
        const response = await fetch(`${getApiBaseUrl()}/api/v1/meta`, { cache: "no-store" });
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
    async function fetchMarketMeta() {
      const url = `${getApiBaseUrl()}/api/v1/${pageId}/exponent-market-meta`;
      const resp = await fetch(url, { cache: "no-store" });
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const payload = await resp.json();
      const meta = payload.data || payload;
      const markets = meta.markets || [];
      if (markets.length === 0) throw new Error("empty markets list");
      return meta;
    }

    let meta = null;
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        meta = await fetchMarketMeta();
        break;
      } catch (err) {
        if (attempt < 2) {
          await new Promise((r) => setTimeout(r, 2000 * (attempt + 1)));
        } else {
          console.warn("Market meta fetch failed after retries:", err);
        }
      }
    }

    if (meta) {
      setSelectOptions(mkt1Select, meta.markets || [], meta.selected_mkt1 || "", true);
      setSelectOptions(mkt2Select, meta.markets || [], meta.selected_mkt2 || "", true);
    } else {
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
    // Skip aborted or failed requests – dedicated handlers
    // (htmx:responseError, htmx:sendError, htmx:timeout) cover real errors.
    // Without this guard, hx-sync="this:replace" aborts produce empty XHR
    // responses that flash a spurious "no response from API" error.
    if (!event.detail.successful) {
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

  document.body.addEventListener("htmx:beforeRequest", (event) => {
    const sourceEl = event.detail.elt;
    if (!sourceEl || !sourceEl.classList.contains("widget-loader")) return;
    const widgetId = sourceEl.dataset.widgetId;
    if (widgetId && isMarketDisabled(widgetId)) {
      event.preventDefault();
      resetWidgetView(sourceEl);
      const updatedEl = document.getElementById(`updated-${widgetId}`);
      if (updatedEl) updatedEl.textContent = "market not selected";
      return;
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

  function initMermaidZoom(container) {
    const wraps = container.querySelectorAll(".mermaid-wrap");
    wraps.forEach((wrap) => {
      const svg = wrap.querySelector("svg");
      if (svg) {
        const vb = svg.getAttribute("viewBox");
        if (vb) {
          const parts = vb.split(/[\s,]+/).map(Number);
          if (parts.length === 4) {
            const pad = 20;
            svg.setAttribute("viewBox",
              `${parts[0] - pad} ${parts[1] - pad} ${parts[2] + pad * 2} ${parts[3] + pad * 2}`);
          }
        }
      }

      const INITIAL_SCALE = 0.85;
      let scale = INITIAL_SCALE;
      let panX = 0;
      let panY = 0;
      let isPanning = false;
      let startX = 0;
      let startY = 0;
      const MIN_SCALE = 0.5;
      const MAX_SCALE = 3;
      const ZOOM_STEP = 0.1;

      function applyTransform() {
        const inner = wrap.querySelector("svg") || wrap.querySelector("pre");
        if (!inner) return;
        inner.style.transform = `translate(${panX}px, ${panY}px) scale(${scale})`;
        inner.style.transformOrigin = "center center";
      }
      applyTransform();

      wrap.addEventListener("wheel", (e) => {
        e.preventDefault();
        const delta = e.deltaY > 0 ? -ZOOM_STEP : ZOOM_STEP;
        scale = Math.min(MAX_SCALE, Math.max(MIN_SCALE, scale + delta));
        applyTransform();
      }, { passive: false });

      wrap.addEventListener("pointerdown", (e) => {
        if (e.button !== 0) return;
        isPanning = true;
        startX = e.clientX - panX;
        startY = e.clientY - panY;
        wrap.setPointerCapture(e.pointerId);
        wrap.style.cursor = "grabbing";
      });

      wrap.addEventListener("pointermove", (e) => {
        if (!isPanning) return;
        panX = e.clientX - startX;
        panY = e.clientY - startY;
        applyTransform();
      });

      const endPan = () => { isPanning = false; wrap.style.cursor = ""; };
      wrap.addEventListener("pointerup", endPan);
      wrap.addEventListener("pointercancel", endPan);

      wrap.addEventListener("dblclick", () => {
        scale = INITIAL_SCALE;
        panX = 0;
        panY = 0;
        applyTransform();
      });
    });
  }

  function explainerMermaidTheme() {
    const isDark = document.documentElement.getAttribute("data-theme") === "dark";
    const linkColor = isDark ? "#f8a94a" : "#f39a2d";
    const fc = "'flowchart': {'useMaxWidth': false, 'padding': 24, 'nodeSpacing': 40, 'rankSpacing': 70, 'wrappingWidth': 200}";
    const directive = isDark
      ? "%%{init: {" + fc + ", 'theme':'dark', 'themeVariables': { 'lineColor':'" + linkColor + "', 'primaryColor':'#1a2d4d', 'primaryTextColor':'#e4e9f4', 'primaryBorderColor':'#4b8fe0', 'secondaryColor':'#152340', 'secondaryTextColor':'#a0b4d4', 'secondaryBorderColor':'#2a4570', 'tertiaryColor':'#152340', 'tertiaryBorderColor':'#2a4570', 'clusterBkg':'#111d33', 'clusterBorder':'#2a4570', 'edgeLabelBackground':'#152340', 'fontFamily':'system-ui, sans-serif', 'fontSize':'13px'}}}%%"
      : "%%{init: {" + fc + ", 'theme':'default', 'themeVariables': { 'lineColor':'" + linkColor + "', 'primaryColor':'#ffffff', 'primaryTextColor':'#11203a', 'primaryBorderColor':'#93b4e0', 'secondaryColor':'#f4f8ff', 'secondaryTextColor':'#5f7396', 'secondaryBorderColor':'#d7e0ef', 'tertiaryColor':'#f4f8ff', 'tertiaryBorderColor':'#d7e0ef', 'clusterBkg':'#f4f8ff', 'clusterBorder':'#d7e0ef', 'edgeLabelBackground':'#eef2f9', 'fontFamily':'system-ui, sans-serif', 'fontSize':'13px'}}}%%";
    return { isDark, linkColor, directive };
  }

  const explainerCache = {};

  async function buildExplainerFromJSON(jsonPath) {
    if (!explainerCache[jsonPath]) {
      const resp = await fetch(jsonPath);
      if (!resp.ok) throw new Error(`Failed to load ${jsonPath}: ${resp.status}`);
      explainerCache[jsonPath] = await resp.json();
    }
    const data = explainerCache[jsonPath];
    const { isDark, linkColor, directive } = explainerMermaidTheme();
    const theme = isDark ? "dark" : "light";
    const styleLines = Object.entries(data.styles[theme])
      .map(([node, style]) => `    style ${node} ${style}`)
      .join("\n");
    const mermaidDef = `${directive}\n${data.graph}\n    linkStyle default stroke:${linkColor},stroke-width:2px\n${styleLines}`;
    return data.html.replace("{{MERMAID}}", mermaidDef);
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

  const INTEGER_COMMA_COLUMNS = new Set([
    "available", "borrowed", "total_supply",
  ]);
  const INTEGER_COMMA_LABELS = new Set([
    "available", "borrowed", "total supply",
  ]);

  function formatPageActionCell(key, label, value) {
    if (value === null || value === undefined || value === "") return "";
    if (INTEGER_COMMA_COLUMNS.has(key) || INTEGER_COMMA_LABELS.has((label || "").toLowerCase())) {
      const n = Number(value);
      if (Number.isFinite(n)) {
        return Math.round(n).toLocaleString();
      }
    }
    return value;
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
        const display = val === null || val === undefined ? "" : formatPageActionCell(col.key, col.label, val);
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

    const explainerPaths = {
      "kamino-explainer": "/static/data/kamino-explainer.json",
      "exponent-explainer": "/static/data/exponent-explainer.json",
    };
    if (explainerPaths[actionId]) {
      openPageActionModal(label, '<p style="color:var(--muted)">Loading\u2026</p>');
      try {
        const html = await buildExplainerFromJSON(explainerPaths[actionId]);
        const { body } = pageActionModalEls();
        body.innerHTML = html;
        if (window.mermaid) {
          await mermaid.run({ nodes: body.querySelectorAll(".mermaid") });
        }
        initMermaidZoom(body);
      } catch (err) {
        const { body } = pageActionModalEls();
        body.innerHTML = `<p style="color:#ef4444">Failed to load explainer: ${err.message}</p>`;
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
  const HEALTH_RED_RECOVERY_POLL_INTERVAL_MS = 10_000;
  const HEALTH_CACHE_TTL_MS = 90_000;
  const HEALTH_RED_CACHE_TTL_MS = 20_000;
  const HEALTH_CACHE_KEY = "riskdash:header-health-status:v1";
  const HEALTH_RED_CONFIRM_RETRIES = 3;
  const HEALTH_RED_CONFIRM_DELAY_MS = 2_000;

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

    function setDotStatus(status) {
      dot.classList.remove("health-dot--unknown", "health-dot--green", "health-dot--red");
      if (status === true) dot.classList.add("health-dot--green");
      else if (status === false) dot.classList.add("health-dot--red");
      else dot.classList.add("health-dot--unknown");

      const label = status === true ? "All systems nominal" : status === false ? "Action required – click to view" : "Health status unavailable";
      dot.closest(".health-indicator").title = label;
    }

    function readCachedStatus() {
      try {
        const raw = localStorage.getItem(HEALTH_CACHE_KEY);
        if (!raw) return null;
        const parsed = JSON.parse(raw);
        if (!parsed || typeof parsed !== "object") return null;
        const cachedStatus = normalizeStatus(parsed.status);
        const ttlMs = cachedStatus === false ? HEALTH_RED_CACHE_TTL_MS : HEALTH_CACHE_TTL_MS;
        const ageMs = Date.now() - Number(parsed.ts || 0);
        if (!Number.isFinite(ageMs) || ageMs > ttlMs) return null;
        return cachedStatus;
      } catch {
        return null;
      }
    }

    function writeCachedStatus(status) {
      try {
        localStorage.setItem(HEALTH_CACHE_KEY, JSON.stringify({ status, ts: Date.now() }));
      } catch {
        // Ignore quota/storage issues; indicator still works without persistence.
      }
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

    let pollTimer = null;
    let pollInFlight = false;

    function schedulePoll(delayMs) {
      if (pollTimer) clearTimeout(pollTimer);
      pollTimer = setTimeout(() => {
        poll();
      }, delayMs);
    }

    async function poll() {
      if (pollInFlight) return;
      pollInFlight = true;
      const cached = readCachedStatus();
      if (cached !== null) {
        setDotStatus(cached);
      }

      try {
        let status = await fetchStatus();

        if (status === false) {
          for (let i = 0; i < HEALTH_RED_CONFIRM_RETRIES; i++) {
            await new Promise((r) => setTimeout(r, HEALTH_RED_CONFIRM_DELAY_MS));
            const retry = await fetchStatus();
            if (retry !== false) { status = retry; break; }
          }
        }

        writeCachedStatus(status);
        setDotStatus(status);
        schedulePoll(status === false ? HEALTH_RED_RECOVERY_POLL_INTERVAL_MS : HEALTH_POLL_INTERVAL_MS);
      } finally {
        pollInFlight = false;
      }
    }

    const cached = readCachedStatus();
    if (cached !== null) {
      setDotStatus(cached);
    }
    poll();
  }

  function initTooltipPositioning() {
    document.addEventListener("mouseover", (e) => {
      const wrap = e.target.closest(".info-tip-wrap");
      if (!wrap) return;
      const card = wrap.querySelector(".info-tip-card");
      if (!card) return;
      const rect = wrap.getBoundingClientRect();
      const cardW = 280;
      let left = rect.left;
      if (left + cardW > window.innerWidth - 12) {
        left = window.innerWidth - cardW - 12;
      }
      if (left < 12) left = 12;
      let top = rect.bottom + 6;
      if (top + 200 > window.innerHeight) {
        top = rect.top - 6;
        card.style.top = "";
        card.style.bottom = (window.innerHeight - top) + "px";
      } else {
        card.style.bottom = "";
        card.style.top = top + "px";
      }
      card.style.left = left + "px";
    });

    document.addEventListener("mouseout", (e) => {
      const wrap = e.target.closest(".info-tip-wrap");
      if (!wrap) return;
      if (e.relatedTarget && wrap.contains(e.relatedTarget)) return;
      const card = wrap.querySelector(".info-tip-card");
      if (!card) return;
      card.style.left = "-9999px";
      card.style.top = "-9999px";
      card.style.bottom = "";
    });
  }

  document.addEventListener("DOMContentLoaded", () => {
    initPageSelector();
    initFilters();
    initHealthIndicator();
    initTooltipPositioning();
    if (window.mermaid) {
      mermaid.initialize({ startOnLoad: false, theme: "dark" });
    }
  });
})();
