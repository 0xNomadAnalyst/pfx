// Dashboard UI Kit — Widget shell, Metric, DataTable, BottomBar

function Widget({ title, icon, sub, controls, children, colSpan = 6, minHeight }) {
  const IcoComp = icon && Ico[icon];
  return (
    <section className={`db-widget db-col-${colSpan}`} style={minHeight ? { minHeight } : null}>
      <header className="db-widget-header">
        <h3 className="db-widget-title">
          {IcoComp && <IcoComp className="ico" />}
          {title}
          {sub && <span className="db-widget-sub" style={{ marginLeft: 8 }}>{sub}</span>}
        </h3>
        {controls && <div className="row" style={{ gap: 8 }}>{controls}</div>}
      </header>
      {children}
    </section>
  );
}

function Metric({ label, value, delta, direction = "neutral" }) {
  const arrow = direction === "up" ? "▲" : direction === "down" ? "▼" : "·";
  return (
    <div className="db-metric">
      <div className="db-metric-label">{label}</div>
      <div className="db-metric-value">{value}</div>
      {delta && (
        <div className={`db-metric-delta db-delta-${direction}`}>
          {arrow} {delta}
        </div>
      )}
    </div>
  );
}

function MetricStrip({ metrics }) {
  return (
    <div style={{
      display: "grid",
      gridTemplateColumns: `repeat(${metrics.length}, 1fr)`,
      gap: 0,
      borderLeft: "1px solid var(--db-border-soft)"
    }}>
      {metrics.map((m, i) => (
        <div
          key={m.label}
          style={{
            padding: "12px 16px",
            borderRight: "1px solid var(--db-border-soft)",
            borderTop: "1px solid var(--db-border-soft)",
            borderBottom: "1px solid var(--db-border-soft)",
          }}
        >
          <Metric {...m} />
        </div>
      ))}
    </div>
  );
}

function DataTable({ columns, rows }) {
  return (
    <div style={{ overflowX: "auto" }}>
      <table className="db-table">
        <thead>
          <tr>{columns.map(c => <th key={c.key} className={c.num ? "num" : ""}>{c.label}</th>)}</tr>
        </thead>
        <tbody>
          {rows.map((row, i) => (
            <tr key={i}>
              {columns.map(c => {
                const v = row[c.key];
                if (c.render) return <td key={c.key} className={c.num ? "num" : ""}>{c.render(v, row)}</td>;
                return <td key={c.key} className={c.num ? "num" : ""}>{v}</td>;
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function Delta({ value }) {
  if (value == null) return <span className="db-delta-neutral">—</span>;
  const up = value > 0;
  return (
    <span className={up ? "db-delta-up" : "db-delta-down"} style={{
      fontFamily: "var(--font-mono)", fontVariantNumeric: "tabular-nums"
    }}>
      {up ? "▲" : "▼"}&nbsp;{Math.abs(value).toFixed(2)}%
    </span>
  );
}

function BottomBar({ left, right }) {
  return (
    <footer className="db-bottombar">
      <div className="db-bottombar-row">{left}</div>
      <div className="db-bottombar-row">{right}</div>
    </footer>
  );
}

Object.assign(window, { Widget, Metric, MetricStrip, DataTable, Delta, BottomBar });
