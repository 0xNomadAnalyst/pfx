(() => {
  const storageKey = "risk-dashboard-theme";
  const root = document.documentElement;
  const toggleButton = () => document.getElementById("theme-toggle");
  const themeIcon = () => document.getElementById("theme-icon");

  const svgMoon = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>';
  const svgSun = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/></svg>';

  function updateThemeIcon(theme) {
    const icon = themeIcon();
    if (!icon) {
      return;
    }
    icon.innerHTML = theme === "light" ? svgSun : svgMoon;
  }

  function applyTheme(theme) {
    root.setAttribute("data-theme", theme);
    localStorage.setItem(storageKey, theme);
    updateThemeIcon(theme);
    window.dispatchEvent(new CustomEvent("theme:changed", { detail: { theme } }));
  }

  function initTheme() {
    const stored = localStorage.getItem(storageKey);
    applyTheme(stored || "dark");
  }

  document.addEventListener("click", (e) => {
    const button = e.target.closest("#theme-toggle");
    if (!button) return;
    const next = root.getAttribute("data-theme") === "dark" ? "light" : "dark";
    applyTheme(next);
  });

  window.__syncThemeIcon = () => updateThemeIcon(root.getAttribute("data-theme") || "dark");

  initTheme();
})();
