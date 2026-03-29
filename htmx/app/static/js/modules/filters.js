(() => {
  const registry = window.__riskdashModuleFactories || (window.__riskdashModuleFactories = {});
  registry.filters = (ctx) => ({
    name: "filters",
    initFilters: () => ctx?.filters?.initFilters?.(),
    triggerRefresh: () => ctx?.apis?.triggerDashboardRefresh?.({ prioritizeViewport: true }),
  });
})();
