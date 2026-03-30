(() => {
  function createRiskdashRenderEngine(deps) {
    const {
      skeletonMinDisplayMs,
      skeletonShownAt,
      widgetFilterSignature,
      renderPayload,
      updateTimestamp,
      setWidgetCachedPayload,
      setWidgetError,
    } = deps;

    function renderWidgetResponse(widgetId, payload, srcId, sourceEl) {
      const skeletonStart = skeletonShownAt.get(widgetId);
      const minDelay = skeletonMinDisplayMs;
      const elapsed = skeletonStart ? Date.now() - skeletonStart : minDelay;
      const remaining = minDelay > 0 && elapsed < minDelay ? minDelay - elapsed : 0;

      const doRender = () => {
        try {
          skeletonShownAt.delete(widgetId);
          const signature = widgetFilterSignature(sourceEl);
          const generatedAt = String(payload?.metadata?.generated_at || "");
          const isIdenticalRefresh = (
            sourceEl.dataset.hasLoadedOnce === "1"
            && sourceEl.dataset.lastRenderedSignature === signature
            && sourceEl.dataset.lastRenderedGeneratedAt === generatedAt
          );
          if (!isIdenticalRefresh) {
            renderPayload(widgetId, payload, srcId);
          }
          updateTimestamp(widgetId, payload?.metadata?.generated_at);
          setWidgetCachedPayload(widgetId, signature, payload);
          sourceEl.dataset.lastRenderedSignature = signature;
          sourceEl.dataset.lastRenderedGeneratedAt = generatedAt;
          sourceEl.dataset.hasLoadedOnce = "1";
        } catch (error) {
          setWidgetError(widgetId, String(error));
        }
      };

      if (remaining > 0) {
        setTimeout(doRender, remaining);
      } else {
        doRender();
      }
    }

    return {
      renderWidgetResponse,
    };
  }

  window.__createRiskdashRenderEngine = createRiskdashRenderEngine;
})();
