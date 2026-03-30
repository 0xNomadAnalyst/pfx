(() => {
  function createRiskdashCoreEngine() {
    let sharedFamilyWidgetIndex = null;

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

    function sharedFamilyId(el) {
      const family = String(el?.dataset?.sharedDataFamily || "").trim();
      return family || "";
    }

    function sharedFamilyWidgetElements(familyId) {
      const family = String(familyId || "").trim();
      if (!family) return [];
      if (!sharedFamilyWidgetIndex) {
        sharedFamilyWidgetIndex = new Map();
        widgetElements().forEach((el) => {
          const id = sharedFamilyId(el);
          if (!id) return;
          if (!sharedFamilyWidgetIndex.has(id)) sharedFamilyWidgetIndex.set(id, []);
          sharedFamilyWidgetIndex.get(id).push(el);
        });
      }
      return sharedFamilyWidgetIndex.get(family) || [];
    }

    function invalidateSharedFamilyWidgetIndex() {
      sharedFamilyWidgetIndex = null;
    }

    return {
      readRuntimeInt,
      readRuntimeBool,
      widgetElements,
      sharedFamilyId,
      sharedFamilyWidgetElements,
      invalidateSharedFamilyWidgetIndex,
    };
  }

  window.__createRiskdashCoreEngine = createRiskdashCoreEngine;
})();
