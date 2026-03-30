(() => {
  function createRiskdashWarmupEngine(deps) {
    const {
      warmupEnabled,
      rewarmupOnFilterChange,
      rewarmupIdleDelayMs,
      warmupSessionKey,
      getWarmupSchedulerStarted,
      setWarmupSchedulerStarted,
      hasWarmupRunThisSession,
      markWarmupRunThisSession,
      readWarmupManifest,
      isWarmupInFlight,
      isPipelineSwitchInProgress,
      runPerPageWarmup,
      getNavigationReadinessTimer,
      setNavigationReadinessTimer,
      isSoftNavInFlight,
      normalizeSoftNavPath,
      setAllShellPrefetchCompleted,
      scheduleAllShellPrefetch,
      isAdaptiveDialdownTriggered,
      getRewarmupDebounceTimer,
      setRewarmupDebounceTimer,
    } = deps;

    function initWarmupScheduler() {
      if (!warmupEnabled) return;
      if (getWarmupSchedulerStarted()) return;
      setWarmupSchedulerStarted(true);
      if (hasWarmupRunThisSession()) return;

      const manifest = readWarmupManifest();
      if (!manifest.length) return;

      let userInteracted = false;
      const markInteraction = () => {
        userInteracted = true;
        setTimeout(attemptWarmup, 150);
      };
      document.addEventListener("pointerdown", markInteraction, { once: true });
      document.addEventListener("keydown", markInteraction, { once: true });

      const attemptWarmup = async () => {
        if (isWarmupInFlight() || hasWarmupRunThisSession()) return;
        if (document.hidden || isPipelineSwitchInProgress()) return;
        const connection = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
        const effectiveType = String(connection?.effectiveType || "").toLowerCase();
        const saveData = connection?.saveData === true;
        if (saveData || effectiveType === "slow-2g" || effectiveType === "2g") {
          markWarmupRunThisSession();
          return;
        }

        if (!manifest.length) {
          markWarmupRunThisSession();
          return;
        }

        try {
          await runPerPageWarmup(manifest, { includeActivePage: true, reason: "startup" });
        } catch (_) {
          // Best-effort background optimization.
        }
      };

      setTimeout(attemptWarmup, 4000);
      document.addEventListener("visibilitychange", () => {
        if (!document.hidden) {
          setTimeout(attemptWarmup, 500);
        }
      });
    }

    function initNavigationReadinessScheduler() {
      if (getNavigationReadinessTimer()) return;
      const cadenceMs = 120_000;
      const timer = setInterval(() => {
        if (document.hidden || isSoftNavInFlight() || isPipelineSwitchInProgress()) return;
        const currentPath = normalizeSoftNavPath(`${window.location.pathname}${window.location.search || ""}`);
        setAllShellPrefetchCompleted(false);
        scheduleAllShellPrefetch(currentPath ? [currentPath] : []);
      }, cadenceMs);
      setNavigationReadinessTimer(timer);
    }

    function scheduleRewarmup() {
      if (!rewarmupOnFilterChange || !warmupEnabled) return;
      if (isAdaptiveDialdownTriggered()) return;
      const currentTimer = getRewarmupDebounceTimer();
      if (currentTimer !== null) {
        clearTimeout(currentTimer);
      }
      const delay = rewarmupIdleDelayMs > 0 ? rewarmupIdleDelayMs : 3000;
      const timer = setTimeout(async () => {
        setRewarmupDebounceTimer(null);
        if (isWarmupInFlight() || document.hidden || isPipelineSwitchInProgress()) return;
        const conn = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
        if (conn && (conn.saveData || String(conn.effectiveType || "").toLowerCase() === "slow-2g" || String(conn.effectiveType || "").toLowerCase() === "2g")) return;
        try { sessionStorage.removeItem(warmupSessionKey); } catch (_) {}
        const manifest = readWarmupManifest();
        if (!manifest.length) return;
        try {
          await runPerPageWarmup(manifest, { includeActivePage: true, reason: "filter-rewarm" });
        } catch (_) {
          // Best-effort background re-warmup.
        }
      }, delay);
      setRewarmupDebounceTimer(timer);
    }

    return {
      initWarmupScheduler,
      initNavigationReadinessScheduler,
      scheduleRewarmup,
    };
  }

  window.__createRiskdashWarmupEngine = createRiskdashWarmupEngine;
})();
