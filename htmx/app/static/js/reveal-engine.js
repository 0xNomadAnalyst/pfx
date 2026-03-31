(() => {
  function createRiskdashRevealEngine(deps) {
    const {
      batchedRevealEnabled,
      batchedRevealTimeoutMs,
      sharedFamilyRevealTimeoutMs,
      unifiedRevealCoordinatorEnabled,
      sharedFamilyId,
      sharedFamilyWidgetElements,
      renderWidgetResponse,
    } = deps;

    const batchedRevealBuffer = new Map();
    const batchedRevealTargets = new Set();
    let batchedRevealTimer = null;

    const sharedFamilyRevealBuffer = new Map();
    const sharedFamilyRevealTimers = new Map();

    const revealCoordinatorGroups = new Map();
    const revealCoordinatorBatchTargets = new Set();
    const revealCoordinatorBatchBuffer = new Map();
    let revealCoordinatorBatchTimer = null;

    function flushBatchedReveal() {
      if (batchedRevealTimer) {
        clearTimeout(batchedRevealTimer);
        batchedRevealTimer = null;
      }
      if (batchedRevealBuffer.size === 0) {
        batchedRevealTargets.clear();
        return;
      }
      requestAnimationFrame(() => {
        batchedRevealBuffer.forEach(({ widgetId, payload, srcId, sourceEl }) => {
          if (!sourceEl?.isConnected) return;
          renderWidgetResponse(widgetId, payload, srcId, sourceEl);
        });
        batchedRevealBuffer.clear();
        batchedRevealTargets.clear();
      });
    }

    function settleBatchedRevealTarget(widgetId) {
      if (!batchedRevealEnabled || !widgetId) return;
      if (!batchedRevealTargets.has(widgetId)) return;
      batchedRevealTargets.delete(widgetId);
      if (batchedRevealTargets.size === 0) {
        flushBatchedReveal();
      }
    }

    function clearSharedFamilyRevealState() {
      sharedFamilyRevealBuffer.clear();
      sharedFamilyRevealTimers.forEach((timer) => {
        try { clearTimeout(timer); } catch (_) {}
      });
      sharedFamilyRevealTimers.clear();
    }

    function clearRevealCoordinatorState() {
      revealCoordinatorBatchTargets.clear();
      revealCoordinatorBatchBuffer.clear();
      if (revealCoordinatorBatchTimer) {
        try { clearTimeout(revealCoordinatorBatchTimer); } catch (_) {}
        revealCoordinatorBatchTimer = null;
      }
      revealCoordinatorGroups.forEach((group) => {
        if (group?.timer) {
          try { clearTimeout(group.timer); } catch (_) {}
        }
      });
      revealCoordinatorGroups.clear();
    }

    function clearActiveRevealState() {
      if (unifiedRevealCoordinatorEnabled) {
        clearRevealCoordinatorState();
        return;
      }
      batchedRevealBuffer.clear();
      batchedRevealTargets.clear();
      if (batchedRevealTimer) {
        try { clearTimeout(batchedRevealTimer); } catch (_) {}
        batchedRevealTimer = null;
      }
      clearSharedFamilyRevealState();
    }

    function flushSharedFamilyReveal(familyId) {
      const family = String(familyId || "").trim();
      if (!family) return;
      const timer = sharedFamilyRevealTimers.get(family);
      if (timer) {
        try { clearTimeout(timer); } catch (_) {}
        sharedFamilyRevealTimers.delete(family);
      }
      const pending = [];
      sharedFamilyRevealBuffer.forEach((entry, widgetId) => {
        if (entry && entry.familyId === family) {
          pending.push([widgetId, entry]);
        }
      });
      pending.forEach(([widgetId, entry]) => {
        sharedFamilyRevealBuffer.delete(widgetId);
        if (!entry?.sourceEl?.isConnected) return;
        renderWidgetResponse(widgetId, entry.payload, entry.srcId, entry.sourceEl);
      });
    }

    function bufferSharedFamilyReveal(familyId, widgetId, payload, srcId, sourceEl) {
      const family = String(familyId || "").trim();
      if (!family || !widgetId) return;
      sharedFamilyRevealBuffer.set(widgetId, { familyId: family, payload, srcId, sourceEl });
      if (sharedFamilyRevealTimers.has(family) || sharedFamilyRevealTimeoutMs <= 0) return;
      const timer = setTimeout(() => flushSharedFamilyReveal(family), sharedFamilyRevealTimeoutMs);
      sharedFamilyRevealTimers.set(family, timer);
    }

    function flushRevealCoordinatorGroup(groupKey) {
      const key = String(groupKey || "").trim();
      if (!key) return;
      const group = revealCoordinatorGroups.get(key);
      if (!group) return;
      if (group.timer) {
        try { clearTimeout(group.timer); } catch (_) {}
      }
      revealCoordinatorGroups.delete(key);
      const entries = Array.isArray(group.entries) ? group.entries : [];
      entries.forEach((entry) => {
        if (!entry?.sourceEl?.isConnected) return;
        renderWidgetResponse(entry.widgetId, entry.payload, entry.srcId, entry.sourceEl);
      });
    }

    function bufferRevealCoordinatorGroup(groupKey, widgetId, payload, srcId, sourceEl, timeoutMs) {
      const key = String(groupKey || "").trim();
      if (!key || !widgetId) return;
      const existing = revealCoordinatorGroups.get(key) || { entries: [], timer: 0 };
      const nextEntries = Array.isArray(existing.entries) ? existing.entries.filter((entry) => entry.widgetId !== widgetId) : [];
      nextEntries.push({ widgetId, payload, srcId, sourceEl });
      let timer = existing.timer || 0;
      if (!timer && Number(timeoutMs || 0) > 0) {
        timer = setTimeout(() => flushRevealCoordinatorGroup(key), Number(timeoutMs));
      }
      revealCoordinatorGroups.set(key, { entries: nextEntries, timer });
    }

    function flushRevealCoordinatorBatchBuffer() {
      if (revealCoordinatorBatchBuffer.size === 0) {
        revealCoordinatorBatchTargets.clear();
        return;
      }
      requestAnimationFrame(() => {
        revealCoordinatorBatchBuffer.forEach((entry, wid) => {
          revealCoordinatorBatchBuffer.delete(wid);
          if (!entry?.sourceEl?.isConnected) return;
          renderWidgetResponse(wid, entry.payload, entry.srcId, entry.sourceEl);
        });
        revealCoordinatorBatchTargets.clear();
      });
    }

    function settleRevealCoordinatorBatchTarget(widgetId) {
      if (!widgetId || !revealCoordinatorBatchTargets.has(widgetId)) return;
      revealCoordinatorBatchTargets.delete(widgetId);
      if (revealCoordinatorBatchTargets.size === 0) {
        if (revealCoordinatorBatchTimer) {
          try { clearTimeout(revealCoordinatorBatchTimer); } catch (_) {}
          revealCoordinatorBatchTimer = null;
        }
        flushRevealCoordinatorBatchBuffer();
      }
    }

    function beginRevealCoordinatorBatch(els) {
      revealCoordinatorBatchTargets.clear();
      revealCoordinatorBatchBuffer.clear();
      if (revealCoordinatorBatchTimer) {
        try { clearTimeout(revealCoordinatorBatchTimer); } catch (_) {}
        revealCoordinatorBatchTimer = null;
      }
      els.forEach((el) => {
        const wid = el?.dataset?.widgetId;
        if (wid) revealCoordinatorBatchTargets.add(String(wid));
      });
      if (revealCoordinatorBatchTargets.size > 0 && batchedRevealTimeoutMs > 0) {
        revealCoordinatorBatchTimer = setTimeout(() => {
          revealCoordinatorBatchTimer = null;
          flushRevealCoordinatorBatchBuffer();
        }, batchedRevealTimeoutMs);
      }
    }

    function flushFamilyWhenSettled(sourceEl, flushFamily) {
      const familyId = sharedFamilyId(sourceEl);
      if (!familyId) return;
      const familyPending = sharedFamilyWidgetElements(familyId)
        .some((el) => {
          if (el === sourceEl) return false;
          if (el.classList.contains("htmx-request")) return true;
          if (el.dataset?.hasLoadedOnce !== "1") return true;
          return false;
        });
      if (!familyPending) {
        flushFamily(familyId);
      }
    }

    function maybeFlushFamilyOnTerminal(sourceEl) {
      flushFamilyWhenSettled(sourceEl, flushSharedFamilyReveal);
    }

    function maybeFlushCoordinatorFamilyOnTerminal(sourceEl) {
      flushFamilyWhenSettled(sourceEl, (familyId) => {
        flushRevealCoordinatorGroup(`family:${familyId}`);
      });
    }

    function settleActiveBatchTarget(widgetId = "") {
      if (unifiedRevealCoordinatorEnabled) {
        settleRevealCoordinatorBatchTarget(widgetId);
      } else {
        settleBatchedRevealTarget(widgetId);
      }
    }

    function onTerminalRevealSettle(sourceEl, widgetId = "") {
      if (unifiedRevealCoordinatorEnabled) {
        maybeFlushCoordinatorFamilyOnTerminal(sourceEl);
        settleActiveBatchTarget(widgetId);
        return;
      }
      maybeFlushFamilyOnTerminal(sourceEl);
      settleActiveBatchTarget(widgetId);
    }

    function isWidgetInActiveBatch(widgetId) {
      if (!batchedRevealEnabled || !widgetId) return false;
      if (unifiedRevealCoordinatorEnabled) {
        return revealCoordinatorBatchTargets.has(widgetId);
      }
      return batchedRevealTargets.has(widgetId);
    }

    function bufferActiveBatch(widgetId, payload, srcId, sourceEl) {
      if (!batchedRevealEnabled || !widgetId) return false;
      if (!isWidgetInActiveBatch(widgetId)) return false;
      if (unifiedRevealCoordinatorEnabled) {
        revealCoordinatorBatchBuffer.set(widgetId, { widgetId, payload, srcId, sourceEl });
        settleRevealCoordinatorBatchTarget(widgetId);
      } else {
        batchedRevealBuffer.set(widgetId, { widgetId, payload, srcId, sourceEl });
        settleBatchedRevealTarget(widgetId);
      }
      return true;
    }

    function bufferActiveFamily(familyId, widgetId, payload, srcId, sourceEl) {
      if (!familyId || !widgetId) return;
      if (unifiedRevealCoordinatorEnabled) {
        bufferRevealCoordinatorGroup(
          `family:${familyId}`,
          widgetId,
          payload,
          srcId,
          sourceEl,
          sharedFamilyRevealTimeoutMs,
        );
        return;
      }
      bufferSharedFamilyReveal(familyId, widgetId, payload, srcId, sourceEl);
    }

    function flushActiveFamily(familyId) {
      if (!familyId) return;
      if (unifiedRevealCoordinatorEnabled) {
        flushRevealCoordinatorGroup(`family:${familyId}`);
        return;
      }
      flushSharedFamilyReveal(familyId);
    }

    function beginActiveBatch(els) {
      if (!batchedRevealEnabled) return;
      if (unifiedRevealCoordinatorEnabled) {
        beginRevealCoordinatorBatch(els);
        return;
      }
      batchedRevealBuffer.clear();
      batchedRevealTargets.clear();
      if (batchedRevealTimer) {
        clearTimeout(batchedRevealTimer);
        batchedRevealTimer = null;
      }
      els.forEach((el) => {
        const wid = el?.dataset?.widgetId;
        if (wid) batchedRevealTargets.add(String(wid));
      });
      if (batchedRevealTargets.size > 0 && batchedRevealTimeoutMs > 0) {
        batchedRevealTimer = setTimeout(flushBatchedReveal, batchedRevealTimeoutMs);
      }
    }

    return {
      clearActiveRevealState,
      onTerminalRevealSettle,
      bufferActiveBatch,
      bufferActiveFamily,
      flushActiveFamily,
      beginActiveBatch,
    };
  }

  window.__createRiskdashRevealEngine = createRiskdashRevealEngine;
})();
