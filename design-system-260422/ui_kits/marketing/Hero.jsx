// Hero — principal-led practice framing + CTA + dashboard screenshot

function Hero() {
  const domains = [
    "Risk Management",
    "DEX liquidity visibility",
    "Market-maker oversight",
    "Incident analysis",
    "Cross-protocol monitoring",
  ];
  return (
    <SectionShell variant="hero">
      <FadeIn>
        <div style={{ maxWidth: 980 }}>
          <h1 style={{
            fontSize: "var(--fs-display)",
            lineHeight: 1.16,
            fontWeight: 500,
            letterSpacing: "-0.01em",
            color: "var(--fg-1)",
            margin: 0
          }}>
            Understand and operate complex<br />
            financial systems in realtime environments.
          </h1>
          <p style={{
            marginTop: 20, maxWidth: "72ch",
            fontSize: "1.08rem", lineHeight: 1.75,
            color: "rgba(237,241,247,0.9)"
          }}>
            I build monitoring, analytics, and decision-support systems, and provide
            data-driven advisory for teams operating in DeFi and other complex
            digital-asset environments.
          </p>
          <p style={{
            marginTop: 12, maxWidth: "72ch",
            fontSize: "1rem", lineHeight: 1.65,
            color: "rgba(166,180,200,0.86)"
          }}>
            This independent practice spans financial risk analysis, empirical modelling,
            and realtime infrastructure across digital-asset markets — from problem
            definition to deployment.
          </p>
          <hr className="mk-divider" />
          <p style={{
            fontSize: "0.98rem",
            color: "rgba(166,180,200,0.5)",
            margin: 0,
            lineHeight: 1.6
          }}>
            Roderick McKinley, CFA, FRM<br />
            Independent Financial Systems Analyst
          </p>

          <div style={{ marginTop: 32 }}>
            <Button variant="cta" size="lg" href="#system">
              Explore Operational Dashboard
            </Button>
            <div style={{
              marginTop: 14, display: "flex", alignItems: "center", gap: 8,
              fontSize: 14, color: "rgba(166,180,200,0.6)"
            }}>
              Watch dashboard introduction video
              <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
                <path d="M23.5 6.2a3.01 3.01 0 0 0-2.12-2.13C19.54 3.6 12 3.6 12 3.6s-7.54 0-9.38.47A3.01 3.01 0 0 0 .5 6.2 31.6 31.6 0 0 0 0 12a31.6 31.6 0 0 0 .5 5.8 3.01 3.01 0 0 0 2.12 2.13C4.46 20.4 12 20.4 12 20.4s7.54 0 9.38-.47a3.01 3.01 0 0 0 2.12-2.13A31.6 31.6 0 0 0 24 12a31.6 31.6 0 0 0-.5-5.8zM9.75 15.52V8.48L15.86 12l-6.11 3.52z"/>
              </svg>
            </div>
            <p style={{
              marginTop: 8, fontFamily: "var(--font-mono)",
              fontSize: 12, color: "rgba(166,180,200,0.45)"
            }}>
              View advisory capabilities deck (PDF)
            </p>
          </div>
        </div>
      </FadeIn>

      <FadeIn delay={0.2}>
        <div style={{ marginTop: 44 }} className="mk-chip-row">
          {domains.map((d) => <span key={d} className="mk-chip">{d}</span>)}
        </div>
      </FadeIn>
    </SectionShell>
  );
}

Object.assign(window, { Hero });
