(() => {
  const storageKey = "risk-dashboard-theme";
  const root = document.documentElement;
  const toggleButton = () => document.getElementById("theme-toggle");
  const themeIcon = () => document.getElementById("theme-icon");

  function updateThemeIcon(theme) {
    const icon = themeIcon();
    if (!icon) {
      return;
    }
    icon.textContent = theme === "light" ? "☀️" : "🌙";
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

  document.addEventListener("DOMContentLoaded", () => {
    initTheme();
    const button = toggleButton();
    if (!button) {
      return;
    }
    button.addEventListener("click", () => {
      const next = root.getAttribute("data-theme") === "dark" ? "light" : "dark";
      applyTheme(next);
    });
  });
})();
