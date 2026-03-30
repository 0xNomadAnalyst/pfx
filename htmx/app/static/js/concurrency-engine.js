(() => {
  function createRiskdashConcurrencyEngine({ maxConcurrentWidgetRequests, requestWidgetNow }) {
    let concurrencyInFlight = 0;
    const concurrencyQueue = [];

    function drainConcurrencyQueue() {
      if (maxConcurrentWidgetRequests <= 0) return;
      while (concurrencyQueue.length > 0 && concurrencyInFlight < maxConcurrentWidgetRequests) {
        const next = concurrencyQueue.shift();
        if (next && next.isConnected) {
          requestWidgetNow(next);
        }
      }
    }

    function requestWidgetManaged(el) {
      if (maxConcurrentWidgetRequests <= 0) {
        requestWidgetNow(el);
        return;
      }
      if (concurrencyInFlight < maxConcurrentWidgetRequests) {
        requestWidgetNow(el);
      } else {
        const widgetId = String(el?.dataset?.widgetId || "");
        const alreadyQueued = concurrencyQueue.some((queued) => {
          if (!queued) return false;
          if (queued === el) return true;
          return widgetId && String(queued?.dataset?.widgetId || "") === widgetId;
        });
        if (!alreadyQueued) {
          concurrencyQueue.push(el);
        }
      }
    }

    function onRequestStarted() {
      if (maxConcurrentWidgetRequests <= 0) return;
      concurrencyInFlight += 1;
    }

    function onRequestTerminal() {
      if (maxConcurrentWidgetRequests <= 0) return;
      concurrencyInFlight = Math.max(0, concurrencyInFlight - 1);
      drainConcurrencyQueue();
    }

    return {
      drainConcurrencyQueue,
      requestWidgetManaged,
      onRequestStarted,
      onRequestTerminal,
    };
  }

  window.__createRiskdashConcurrencyEngine = createRiskdashConcurrencyEngine;
})();
