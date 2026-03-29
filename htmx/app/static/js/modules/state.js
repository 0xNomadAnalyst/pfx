(() => {
  const registry = window.__riskdashModuleFactories || (window.__riskdashModuleFactories = {});
  registry.state = (ctx) => ({
    name: "state",
    get constants() {
      return ctx?.constants || {};
    },
    get stores() {
      return ctx?.state || {};
    },
  });
})();
