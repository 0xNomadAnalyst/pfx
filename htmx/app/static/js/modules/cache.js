(() => {
  const registry = window.__riskdashModuleFactories || (window.__riskdashModuleFactories = {});
  registry.cache = (ctx) => ({
    name: "cache",
    hydrateWidgetsFromCache: () => ctx?.cache?.hydrateWidgetsFromCache?.(),
    hasCachedPayload: (el) => ctx?.cache?.hasCachedWidgetPayloadForCurrentSignature?.(el),
    widgetResponseCache: ctx?.state?.widgetResponseCache,
  });
})();
