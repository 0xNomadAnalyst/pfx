(() => {
  function createRiskdashCacheEngine(deps) {
    const {
      widgetElements,
      sharedFamilyId,
      renderCachedWidgetPayload,
      widgetFilterSignature,
      resolveSourceWidgetId,
      getWidgetCacheEntry,
      getLatestWidgetCacheEntry,
      classifyWidgetCacheFreshness,
      softNavDebug,
      softNavDebugEvent,
    } = deps;

    function hasCachedWidgetPayloadForCurrentSignature(sourceEl) {
      if (!sourceEl || !sourceEl.classList.contains("widget-loader")) return false;
      const widgetId = sourceEl.dataset.widgetId || "";
      if (!widgetId) return false;
      const signature = widgetFilterSignature(sourceEl);
      const sourceWidgetId = resolveSourceWidgetId(sourceEl);
      let entry = getWidgetCacheEntry(widgetId, signature);
      if (!entry && sourceWidgetId && sourceWidgetId !== widgetId) {
        entry = getWidgetCacheEntry(sourceWidgetId, signature);
      }
      if (!entry) {
        entry = getLatestWidgetCacheEntry(widgetId);
      }
      if (!entry && sourceWidgetId && sourceWidgetId !== widgetId) {
        entry = getLatestWidgetCacheEntry(sourceWidgetId);
      }
      if (!entry || !entry.payload) return false;
      return classifyWidgetCacheFreshness(widgetId, entry) !== "expired";
    }

    function hydrateWidgetsFromCache() {
      const startedAt = performance.now();
      let hits = 0;
      const widgets = widgetElements();
      const blockedByFamily = new Set();
      const familyGroups = new Map();
      widgets.forEach((el) => {
        const familyId = sharedFamilyId(el);
        if (!familyId) return;
        if (!familyGroups.has(familyId)) {
          familyGroups.set(familyId, []);
        }
        familyGroups.get(familyId).push(el);
      });
      familyGroups.forEach((members) => {
        if (!Array.isArray(members) || members.length < 2) return;
        const allFamilyMembersCached = members.every((el) => hasCachedWidgetPayloadForCurrentSignature(el));
        if (allFamilyMembersCached) return;
        members.forEach((el) => {
          const wid = String(el?.dataset?.widgetId || "");
          if (wid) blockedByFamily.add(wid);
        });
      });

      widgets.forEach((el) => {
        const wid = String(el?.dataset?.widgetId || "");
        if (wid && blockedByFamily.has(wid)) {
          return;
        }
        if (renderCachedWidgetPayload(el)) {
          hits += 1;
        }
      });
      if (hits > 0) {
        const latencyMs = Math.max(0, performance.now() - startedAt);
        softNavDebug.persistRestoreToVisibleMs = latencyMs;
        const samples = Array.isArray(softNavDebug.persistRestoreToVisibleSamples)
          ? softNavDebug.persistRestoreToVisibleSamples
          : [];
        samples.push(latencyMs);
        if (samples.length > 50) samples.splice(0, samples.length - 50);
        softNavDebug.persistRestoreToVisibleSamples = samples;
        softNavDebugEvent("persist_restore_visible", { hits, latencyMs });
      }
      return hits;
    }

    return {
      hasCachedWidgetPayloadForCurrentSignature,
      hydrateWidgetsFromCache,
    };
  }

  window.__createRiskdashCacheEngine = createRiskdashCacheEngine;
})();
