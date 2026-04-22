// Outcomes — 3 metric cards + additional benefits list

function Outcomes() {
  const metrics = [
    { label: "Annual MM Cost", from: "~$2m", to: "~$840k" },
    { label: "External MM Model", from: "2 partners", to: "1 partner" },
    { label: "Operating Model", from: "External only", to: "Internal capability" },
  ];
  const outcomes = [
    "Earlier visibility into events that could pressure liquidity",
    "Better oversight of external market-maker performance",
    "Rapid post-incident analysis that helped strengthen protocol risk management",
  ];
  return (
    <SectionShell id="outcomes" variant="open">
      <SectionHeading
        label="Selected Client Outcomes"
        title="Improvements with Financial Impact"
        intro="Better visibility translated into concrete changes in operating model, market-maker oversight, and cost."
        introWide
      />
      <div className="mk-grid-3" style={{ marginTop: 32 }}>
        {metrics.map((m, i) => (
          <MetricCard key={m.label} {...m} delay={0.06 * (i + 1)} />
        ))}
      </div>

      <FadeIn delay={0.22}>
        <p className="mk-eyebrow" style={{ marginTop: 40 }}>
          Additional reported benefits
        </p>
        <ul style={{
          marginTop: 12, padding: 0, listStyle: "none",
          display: "flex", flexDirection: "column", gap: 10,
          fontSize: "0.98rem", lineHeight: 1.65,
          color: "rgba(166,180,200,0.94)", maxWidth: "66ch"
        }}>
          {outcomes.map((item) => (
            <li key={item} style={{ display: "flex", gap: 10 }}>
              <span style={{
                marginTop: "0.58rem", width: 4, height: 4, flexShrink: 0,
                borderRadius: "50%", background: "rgba(166,180,200,0.78)"
              }} />
              {item}
            </li>
          ))}
        </ul>
      </FadeIn>
    </SectionShell>
  );
}

Object.assign(window, { Outcomes });
