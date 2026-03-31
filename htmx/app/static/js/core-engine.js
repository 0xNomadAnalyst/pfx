(() => {
  function createRiskdashCoreEngine() {

    function readRuntimeInt(datasetKey, fallback, min = 0, max = Number.MAX_SAFE_INTEGER) {
      const raw = document.body?.dataset?.[datasetKey];
      const parsed = Number(raw);
      if (!Number.isFinite(parsed)) return fallback;
      return Math.min(max, Math.max(min, Math.floor(parsed)));
    }

    function readRuntimeBool(datasetKey, fallback = false) {
      const raw = String(document.body?.dataset?.[datasetKey] || "").toLowerCase().trim();
      if (!raw) return fallback;
      return raw === "1" || raw === "true" || raw === "yes" || raw === "on";
    }

    function widgetElements() {
      return Array.from(document.querySelectorAll(".widget-loader"));
    }

    return {
      readRuntimeInt,
      readRuntimeBool,
      widgetElements,
    };
  }

  window.__createRiskdashCoreEngine = createRiskdashCoreEngine;
})();
