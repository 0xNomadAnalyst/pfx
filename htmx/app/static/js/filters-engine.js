(() => {
  function createRiskdashFiltersEngine(deps) {
    const {
      storageKey,
      readCurrentProtocol,
      readCurrentPair,
      readCurrentLastWindow,
      triggerDashboardRefresh,
      scheduleRewarmup,
    } = deps;

    function readPersistedFilters() {
      try {
        const raw = window.localStorage.getItem(storageKey);
        if (!raw) {
          return null;
        }
        const parsed = JSON.parse(raw);
        return {
          protocol: typeof parsed?.protocol === "string" ? parsed.protocol : "",
          pair: typeof parsed?.pair === "string" ? parsed.pair : "",
          lastWindow: typeof parsed?.lastWindow === "string" ? parsed.lastWindow : "",
        };
      } catch (_) {
        return null;
      }
    }

    function persistFilters(protocol, pair, lastWindow) {
      try {
        window.localStorage.setItem(
          storageKey,
          JSON.stringify({
            protocol: protocol || "",
            pair: pair || "",
            lastWindow: lastWindow || "",
          })
        );
      } catch (_) {
        // Ignore storage failures (private mode / quota).
      }
    }

    function applyGlobalFilters(protocol, pair, lastWindow, shouldRefresh = true) {
      if (protocol) {
        const protocolSelect = document.getElementById("protocol-select");
        if (protocolSelect) {
          protocolSelect.value = protocol;
        }
      }
      if (pair) {
        const pairSelect = document.getElementById("pair-select");
        if (pairSelect) {
          pairSelect.value = pair;
        }
      }
      if (lastWindow) {
        const lastWindowSelect = document.getElementById("last-window-select");
        if (lastWindowSelect) {
          lastWindowSelect.value = lastWindow;
        }
      }
      persistFilters(
        protocol || readCurrentProtocol(),
        pair || readCurrentPair(),
        lastWindow || readCurrentLastWindow()
      );
      if (shouldRefresh) {
        triggerDashboardRefresh({ prioritizeViewport: true });
        scheduleRewarmup();
      }
    }

    return {
      readPersistedFilters,
      persistFilters,
      applyGlobalFilters,
    };
  }

  window.__createRiskdashFiltersEngine = createRiskdashFiltersEngine;
})();
