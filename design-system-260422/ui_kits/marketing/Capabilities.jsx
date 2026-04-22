// Capabilities — 5-card grid. Lead card spans 7/12, second 5/12, remaining 4/12.

function Capabilities() {
  const domains = [
    {
      title: "Liquidity & Market Structure Visibility",
      description:
        "Understand available depth, concentration, venue dependency, and price-impact conditions before execution quality deteriorates.",
    },
    {
      title: "Market Maker Visibility & Accountability",
      description:
        "Monitor third-party support, performance during stress periods, and improve negotiation and KPI design.",
    },
    {
      title: "Cross-Protocol Risk & Exposure Monitoring",
      description:
        "Track and interpret exposures across DeFi venues, and issuer-controlled contracts using normalized metrics and unified views.",
    },
    {
      title: "Incident Replay & Root-Cause Analysis",
      description:
        "Turn live stress events into structured investigation quickly, shortening the path from incident to understanding.",
    },
    {
      title: "Simulation & Risk-Policy Support",
      description:
        "Use observed behaviour and structured historical data to refine intervention rules, thresholds, and operating playbooks.",
    },
  ];
  const spanClass = (i) => {
    if (i === 0) return "mk-span-7";
    if (i === 1) return "mk-span-5";
    return "mk-span-4";
  };
  return (
    <SectionShell id="capabilities" variant="open">
      <SectionHeading
        label="Key Operational Domains"
        title="Where Visibility Matters Most"
        intro="Domains where better monitoring, accountability, and system-level understanding have the greatest impact."
        introWide
      />
      <div className="mk-grid-12" style={{ marginTop: 32 }}>
        {domains.map((d, i) => (
          <DomainCard
            key={d.title}
            index={i + 1}
            title={d.title}
            body={d.description}
            lead={i === 0}
            delay={i * 0.08}
            spanClass={spanClass(i)}
          />
        ))}
      </div>
    </SectionShell>
  );
}

Object.assign(window, { Capabilities });
