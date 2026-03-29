(() => {
  const registry = window.__riskdashModuleFactories || (window.__riskdashModuleFactories = {});
  registry.concurrency = (ctx) => ({
    name: "concurrency",
    maxConcurrentWidgetRequests: Number(ctx?.constants?.MAX_CONCURRENT_WIDGET_REQUESTS || 0),
    requestManaged: (el) => ctx?.concurrency?.requestManaged?.(el),
    requestNow: (el) => ctx?.apis?.requestWidgetNow?.(el),
  });
})();
