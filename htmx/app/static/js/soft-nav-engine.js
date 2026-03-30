(() => {
  function createRiskdashSoftNavEngine() {
    function normalizeSoftNavPath(path) {
      try {
        const u = new URL(path, window.location.origin);
        return `${u.pathname}${u.search || ""}`;
      } catch (_) {
        return path || "";
      }
    }

    function collectSoftNavPathsFromUi() {
      const paths = [];
      const pageSelect = document.getElementById("page-select");
      if (pageSelect && pageSelect.options?.length) {
        Array.from(pageSelect.options).forEach((opt) => {
          const normalized = normalizeSoftNavPath(opt.value || "");
          if (normalized && !paths.includes(normalized)) paths.push(normalized);
        });
      }
      document.querySelectorAll("#sidebar-nav .sidebar-nav-link[data-sidebar-path]").forEach((link) => {
        const normalized = normalizeSoftNavPath(link.getAttribute("data-sidebar-path") || "");
        if (normalized && !paths.includes(normalized)) paths.push(normalized);
      });
      return paths;
    }

    function syncSidebarHighlight(targetPath) {
      const normalizedTarget = normalizeSoftNavPath(
        targetPath || `${window.location.pathname}${window.location.search || ""}`,
      );
      const liveLinks = Array.from(document.querySelectorAll("#sidebar-nav .sidebar-nav-link[data-sidebar-path]"));
      liveLinks.forEach((l) => {
        const linkPath = normalizeSoftNavPath(l.getAttribute("data-sidebar-path") || "");
        const match = !!normalizedTarget && !!linkPath && linkPath === normalizedTarget;
        l.classList.toggle("is-active", match);
        if (match) l.setAttribute("aria-current", "page");
        else l.removeAttribute("aria-current");
      });
    }

    return {
      normalizeSoftNavPath,
      collectSoftNavPathsFromUi,
      syncSidebarHighlight,
    };
  }

  window.__createRiskdashSoftNavEngine = createRiskdashSoftNavEngine;
})();
