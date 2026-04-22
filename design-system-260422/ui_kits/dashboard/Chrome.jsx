// Dashboard UI Kit — TopBar, Sidebar, filter primitives

const { useState, useEffect, useRef } = React;

/* Inline icons (Lucide-like: 1.5px stroke, 14x14 viewBox 24). */
const Ico = {
  overview: (p) => (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" {...p}><rect x="3" y="3" width="7" height="9"/><rect x="14" y="3" width="7" height="5"/><rect x="14" y="12" width="7" height="9"/><rect x="3" y="16" width="7" height="5"/></svg>
  ),
  liquidity: (p) => (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" {...p}><path d="M12 2.69l5.66 5.66a8 8 0 1 1-11.32 0Z"/></svg>
  ),
  yields: (p) => (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" {...p}><path d="M3 17l6-6 4 4 8-8"/><path d="M14 7h7v7"/></svg>
  ),
  reserves: (p) => (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" {...p}><ellipse cx="12" cy="6" rx="9" ry="3"/><path d="M3 6v6c0 1.66 4.03 3 9 3s9-1.34 9-3V6"/><path d="M3 12v6c0 1.66 4.03 3 9 3s9-1.34 9-3v-6"/></svg>
  ),
  risk: (p) => (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" {...p}><path d="M10.29 3.86l-8.3 14.37A2 2 0 0 0 3.72 21h16.56a2 2 0 0 0 1.73-2.77l-8.3-14.37a2 2 0 0 0-3.42 0Z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>
  ),
  stress: (p) => (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" {...p}><path d="M21 12a9 9 0 1 1-9-9"/><path d="M21 3v6h-6"/><path d="M12 7v5l3 2"/></svg>
  ),
  incidents: (p) => (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" {...p}><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3"/></svg>
  ),
  chart: (p) => (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" {...p}><path d="M3 3v18h18"/><path d="M7 15l4-4 4 4 5-6"/></svg>
  ),
  download: (p) => (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" {...p}><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
  ),
  settings: (p) => (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" {...p}><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h0a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51h0a1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v0a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1Z"/></svg>
  ),
};

/* TopBar */
function TopBar({ title, network, time, health = "green", filters }) {
  return (
    <header className="db-topbar">
      <div className="db-topbar-left">
        <span className="db-topbar-title">
          <span className="db-mark" />
          {title}
        </span>
        <span className="db-tag">{network}</span>
      </div>

      <div className="row" style={{ justifyContent: "center", gap: 20 }}>
        {filters}
      </div>

      <div className="db-topbar-right">
        <span className="db-topbar-meta">{time}</span>
        <a className={`db-health`} title="System health" href="#">
          <span className={`db-health-dot ${health === "warn" ? "warn" : health === "err" ? "err" : ""}`} />
        </a>
        <button className="db-action-btn" type="button">
          <Ico.download width="12" height="12" style={{ verticalAlign: "-2px", marginRight: 6 }} />
          Export
        </button>
      </div>
    </header>
  );
}

/* Sidebar with sections */
function Sidebar({ tabs, active, onSelect }) {
  const sections = {};
  tabs.forEach(t => {
    (sections[t.section] = sections[t.section] || []).push(t);
  });
  return (
    <aside className="db-sidebar">
      {Object.entries(sections).map(([section, items]) => (
        <div key={section}>
          <div className="db-sidebar-section">{section}</div>
          {items.map(t => {
            const IcoComp = Ico[t.icon] || Ico.chart;
            return (
              <button
                key={t.id}
                className={`db-sidebar-item ${active === t.id ? "active" : ""}`}
                onClick={() => onSelect(t.id)}
              >
                <IcoComp className="ico" />
                <span>{t.label}</span>
              </button>
            );
          })}
        </div>
      ))}
    </aside>
  );
}

/* Filter primitives */
function FilterSelect({ label, value, options, onChange }) {
  return (
    <label className="row" style={{ gap: 8 }}>
      <span className="db-filter-label">{label}</span>
      <select
        className="db-select"
        value={value}
        onChange={(e) => onChange && onChange(e.target.value)}
      >
        {options.map(o => <option key={o} value={o}>{o}</option>)}
      </select>
    </label>
  );
}

Object.assign(window, { Ico, TopBar, Sidebar, FilterSelect });
