(() => {
  const registry = window.__riskdashModuleFactories || (window.__riskdashModuleFactories = {});
  registry.warmup = (ctx) => ({
    name: "warmup",
    runPerPageWarmup: (manifest, options) => ctx?.warmup?.runPerPageWarmup?.(manifest, options),
  });
})();
