(() => {
  const chartState = new Map();
  let protocolPairs = [];
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
  const rightLinkedZoomWidgets = new Set([
    "usdc-lp-flows",
    "usdc-pool-share-concentration",
    "trade-impact-toggle",
  ]);
  const linkedGroups = {
    left: "linked-zoom-left",
    right: "linked-zoom-right",
  };

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

  function formatNumber(value) {
    if (value === null || value === undefined || Number.isNaN(value)) {
      return "--";
    }
    const number = Number(value);
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

  function renderKpi(widgetId, data) {
    const primary = document.getElementById(`kpi-primary-${widgetId}`);
    const secondary = document.getElementById(`kpi-secondary-${widgetId}`);
    if (!primary || !secondary) {
      return;
    }

    if (widgetId === "kpi-impact-500k" || widgetId === "kpi-largest-impact" || widgetId === "kpi-average-impact") {
      primary.textContent = `${formatSigned(data.primary, " bps")}`;
      secondary.textContent = data.secondary ? `Size: ${formatNumber(data.secondary)}` : "";
      return;
    }

    if (widgetId === "kpi-pool-balance") {
      primary.textContent = `${formatNumber(data.primary)}%`;
      secondary.textContent = `${formatNumber(data.secondary)}%`;
      return;
    }

    if (widgetId === "kpi-reserves") {
      primary.textContent = `${formatNumber(data.primary)}m`;
      secondary.textContent = `${formatNumber(data.secondary)}m`;
      return;
    }

    primary.textContent = formatNumber(data.primary);
    secondary.textContent = data.secondary ? formatNumber(data.secondary) : "";
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

    const normalizedColumns = normalizeColumns(widgetId, columns);
    const header = normalizedColumns.map((column) => `<th>${column.label}</th>`).join("");
    const body = rows
      .map((row) => {
        const cells = normalizedColumns
          .map((column) => {
            const raw = row[column.key];
            const value = widgetId === "liquidity-depth-table" ? formatDepthTableValue(column.key, raw) : (raw ?? "");
            return `<td>${value}</td>`;
          })
          .join("");
        return `<tr>${cells}</tr>`;
      })
      .join("");
    target.innerHTML = `<table><thead><tr>${header}</tr></thead><tbody>${body}</tbody></table>`;
  }

  function baseChartOption(data) {
    const option = {
      color: palette(),
      tooltip: { trigger: "axis" },
      legend: { top: 2, textStyle: { color: chartTextColor() } },
      grid: { left: 40, right: 18, top: 30, bottom: 18, containLabel: true },
      xAxis: {
        type: "category",
        data: data.x || [],
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
        type: "value",
        axisLine: { lineStyle: { color: chartGridColor() } },
        splitLine: { lineStyle: { color: chartGridColor() } },
        axisLabel: { color: chartTextColor(), fontSize: 11 },
      },
      series: (data.series || []).map((series) => {
        const mapped = {
          name: series.name,
          type: series.type || "line",
          data: series.data || [],
          showSymbol: false,
          smooth: false,
        };
        if (series.yAxisIndex !== undefined) {
          mapped.yAxisIndex = series.yAxisIndex;
        }
        if (series.color) {
          mapped.itemStyle = { color: series.color };
          mapped.lineStyle = { color: series.color };
        }
        if (series.area) {
          mapped.areaStyle = { opacity: 0.2 };
        }
        return mapped;
      })
    };
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

    let option;
    if (data.chart === "heatmap") {
      const minValue = Number(data.min ?? -1);
      const maxValue = Number(data.max ?? 1);
      const leftLegend = `${minValue.toFixed(2)}%`;
      const rightLegend = `${maxValue >= 0 ? "+" : ""}${maxValue.toFixed(2)}%`;
      option = {
        color: palette(),
        tooltip: { position: "top" },
        grid: { left: 82, right: 18, top: 16, bottom: 58, containLabel: false },
        xAxis: {
          type: "category",
          data: data.x || [],
          boundaryGap: false,
          axisLine: { lineStyle: { color: chartGridColor() } },
          axisLabel: {
            color: chartTextColor(),
            fontSize: 10,
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
        series: [{ type: "heatmap", data: data.points || [] }],
      };
      if (leftLinkedZoomWidgets.has(widgetId)) {
        option.dataZoom = [
          {
            type: "inside",
            xAxisIndex: 0,
            filterMode: "none",
          },
        ];
      }
    } else {
      option = baseChartOption(data);
      if (comparableLiquidityWidgets.has(widgetId)) {
        option.grid.left = 82;
        option.grid.right = 18;
        option.grid.bottom = 18;
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
        option.grid.bottom = 20;
      }
      if (leftLinkedZoomWidgets.has(widgetId) || rightLinkedZoomWidgets.has(widgetId)) {
        option.dataZoom = [
          {
            type: "inside",
            xAxisIndex: 0,
            filterMode: "none",
          },
          {
            type: "slider",
            xAxisIndex: 0,
            height: 12,
            bottom: 2,
            borderColor: chartGridColor(),
            brushSelect: false,
          },
        ];
      }
      if (rightLinkedZoomWidgets.has(widgetId)) {
        option.grid.left = 82;
        option.grid.right = 64;
        option.grid.bottom = 22;
        option.grid.containLabel = false;
        option.yAxis = {
          ...option.yAxis,
          axisLabel: {
            ...option.yAxis.axisLabel,
            width: 62,
            align: "right",
            padding: [0, 8, 0, 0],
          },
        };
        option.xAxis.axisLabel = {
          ...option.xAxis.axisLabel,
          formatter: (value) => formatCompactTimestamp(value),
        };
        option.tooltip.formatter = (params) => {
          const items = Array.isArray(params) ? params : [params];
          if (items.length === 0) {
            return "";
          }
          const header = formatCompactTimestamp(items[0].axisValue);
          const rows = items
            .map((item) => `${item.marker} ${item.seriesName}: ${formatNumber(item.value)}`)
            .join("<br/>");
          return `${header}<br/>${rows}`;
        };
      }
      if (widgetId === "usdc-lp-flows") {
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
            axisLabel: {
              color: chartTextColor(),
              formatter: (value) => `${Number(value).toFixed(2)}%`,
            },
          },
        ];
      }
    }

    instance.setOption(option, true);
    if (leftLinkedZoomWidgets.has(widgetId)) {
      instance.group = linkedGroups.left;
      echarts.connect(linkedGroups.left);
    } else if (rightLinkedZoomWidgets.has(widgetId)) {
      instance.group = linkedGroups.right;
      echarts.connect(linkedGroups.right);
    }
    chartState.set(widgetId, { instance, data });
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
      renderTable(widgetId, `table-${widgetId}`, payload.data.columns || [], payload.data.rows || []);
      return;
    }

    if (kind === "table-split") {
      const columns = payload.data.columns || [];
      document.getElementById(`table-left-title-${widgetId}`).textContent = payload.data.left_title || "Left";
      document.getElementById(`table-right-title-${widgetId}`).textContent = payload.data.right_title || "Right";
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
    return select ? select.value : "24h";
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

  async function initFilters() {
    const protocolSelect = document.getElementById("protocol-select");
    const pairSelect = document.getElementById("pair-select");
    const lastWindowSelect = document.getElementById("last-window-select");
    if (!protocolSelect || !pairSelect || !lastWindowSelect) {
      return;
    }

    let selectedProtocol = protocolSelect.value;
    let selectedPair = pairSelect.value;
    let selectedLastWindow = lastWindowSelect.value || "24h";

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

    applyGlobalFilters(selectedProtocol, selectedPair, selectedLastWindow, true);

    protocolSelect.addEventListener("change", () => {
      const protocol = protocolSelect.value;
      setSelectOptions(pairSelect, pairsForProtocol(protocol), pairSelect.value);
      resetDashboardLoading();
      applyGlobalFilters(protocol, pairSelect.value, lastWindowSelect.value, true);
    });

    pairSelect.addEventListener("change", () => {
      resetDashboardLoading();
      applyGlobalFilters(protocolSelect.value, pairSelect.value, lastWindowSelect.value, true);
    });

    lastWindowSelect.addEventListener("change", () => {
      resetDashboardLoading();
      applyGlobalFilters(protocolSelect.value, pairSelect.value, lastWindowSelect.value, true);
    });

    const refreshButton = document.getElementById("refresh-dashboard");
    if (refreshButton) {
      refreshButton.addEventListener("click", () => {
        applyGlobalFilters(protocolSelect.value, pairSelect.value, lastWindowSelect.value, true);
      });
    }

    initTradeImpactModeToggle();
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
    if (sourceEl.dataset.widgetId === "trade-impact-toggle") {
      event.detail.parameters.impact_mode = sourceEl.dataset.impactMode || "size";
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

  window.addEventListener("theme:changed", () => {
    chartState.forEach(({ instance, data }, widgetId) => {
      if (instance) {
        renderChart(widgetId, data);
      }
    });
  });

  window.addEventListener("resize", () => {
    chartState.forEach(({ instance }) => instance && instance.resize());
  });

  document.addEventListener("DOMContentLoaded", () => {
    initFilters();
  });
})();
