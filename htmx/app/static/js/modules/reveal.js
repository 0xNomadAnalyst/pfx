(() => {
  const registry = window.__riskdashModuleFactories || (window.__riskdashModuleFactories = {});
  registry.reveal = (ctx) => ({
    name: "reveal",
    beginBatch: (els) => ctx?.reveal?.beginBatch?.(els),
    clearState: () => ctx?.reveal?.clearState?.(),
    onTerminalSettle: (el, widgetId) => ctx?.reveal?.onTerminalSettle?.(el, widgetId),
  });
})();
