(() => {
  const registry = window.__riskdashModuleFactories || (window.__riskdashModuleFactories = {});
  registry.render = (ctx) => ({
    name: "render",
    renderPayload: (widgetId, payload, srcId) => ctx?.render?.renderPayload?.(widgetId, payload, srcId),
    chartState: ctx?.state?.chartState,
  });
})();
