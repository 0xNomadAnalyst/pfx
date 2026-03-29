(() => {
  const registry = window.__riskdashModuleFactories || (window.__riskdashModuleFactories = {});
  registry["soft-nav"] = (ctx) => ({
    name: "soft-nav",
    navigate: (path, opts) => ctx?.apis?.softNavigateToPage?.(path, opts),
    teardown: () => ctx?.softNav?.teardownForSoftNavigation?.(),
    hydrate: (path, opts) => ctx?.softNav?.hydrateSoftNavPage?.(path, opts),
    shellCache: ctx?.state?.softNavShellCache,
  });
})();
