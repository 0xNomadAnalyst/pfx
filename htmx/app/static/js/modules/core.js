(() => {
  const registry = window.__riskdashModuleFactories || (window.__riskdashModuleFactories = {});
  registry.core = (ctx) => ({
    name: "core",
    readRuntimeInt: ctx?.utils?.readRuntimeInt,
    readRuntimeBool: ctx?.utils?.readRuntimeBool,
    widgetElements: ctx?.utils?.widgetElements,
    sharedFamilyId: ctx?.utils?.sharedFamilyId,
    sharedFamilyWidgetElements: ctx?.utils?.sharedFamilyWidgetElements,
  });
})();
