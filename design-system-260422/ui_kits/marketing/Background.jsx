// Background — narrative column + credentials panel with hairline accents

function Background() {
  const groups = [
    {
      title: "Digital Asset & OnChain Work",
      items: [
        "Operational Risk Infrastructure - Solstice USX Stablecoin (~$350M AUM)",
        "Public Token Economy Dashboard - Token LaunchPad with 250k users",
        "ICO / Utility Token Fundraising Support - (~$60M in private and public raises)",
      ],
    },
    {
      title: "Institutional Experience",
      items: [
        "Bloomberg - Analytical Research & Financial Modelling",
        "M&A Analyst - UK Renewable Energy Assets",
        "Project Finance Modelling - Private Equity Sponsored Renewables (Chile)",
      ],
    },
    {
      title: "Professional Credentials",
      items: ["CFA Charterholder", "Financial Risk Manager (FRM)"],
    },
    {
      title: "Education",
      items: [
        "MSc Economic Policy - University College London",
        "BSc Economics & Philosophy - University of Bristol (First Class Honours)",
      ],
    },
  ];
  const split = (s) => {
    const i = s.indexOf(" - ");
    return i === -1 ? { l1: s, l2: null } : { l1: s.slice(0, i).trim(), l2: s.slice(i + 3).trim() };
  };

  return (
    <SectionShell id="background" variant="open" className="mk-bg-ambient">
      <div
        aria-hidden
        style={{
          position: "absolute", inset: 0, pointerEvents: "none",
          background:
            "radial-gradient(780px 380px at 82% 12%, rgba(128,162,198,0.12), transparent 62%), " +
            "radial-gradient(480px 320px at 12% 88%, rgba(248,169,74,0.05), transparent 60%)"
        }}
      />
      <div style={{ position: "relative" }}>
        <SectionHeading
          label="Professional Foundations"
          title="Institutional Discipline, Onchain"
          intro="Judgment shaped by experience across institutional finance, risk analysis, and digital-asset markets."
          introWide
        />

        <div style={{
          display: "grid",
          gridTemplateColumns: "minmax(0, 6.1fr) minmax(0, 5.9fr)",
          gap: 24, marginTop: 32
        }} className="mk-bg-grid">
          <FadeIn delay={0.09}>
            <div style={{ display: "flex", flexDirection: "column", gap: 24, maxWidth: "60ch" }}>
              <div style={{ fontSize: "1rem", lineHeight: 1.72, color: "rgba(166,180,200,0.95)", display: "flex", flexDirection: "column", gap: 16 }}>
                <p style={{ margin: 0 }}>
                  Blockchain systems introduce genuinely new financial structures,
                  requiring the ability to reinterpret legacy instruments,
                  institutions, and infrastructure while cutting through narrative,
                  ideology, and conflicting incentives that can obscure economic reality.
                </p>
                <p style={{ margin: 0 }}>
                  A strong foundation in traditional finance and economic reasoning
                  provides the grounding to do this clearly, while remaining open to
                  the structural possibilities programmable onchain systems create.
                </p>
              </div>

              <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
                <span style={{ width: 32, height: 1, background: "rgba(248,169,74,0.58)", flex: "none" }} />
                <p className="mk-eyebrow" style={{
                  margin: 0, letterSpacing: "0.16em", color: "rgba(248,169,74,0.78)"
                }}>Structured Financial Reasoning</p>
              </div>

              <div style={{ fontSize: "1rem", lineHeight: 1.72, color: "rgba(166,180,200,0.95)", display: "flex", flexDirection: "column", gap: 16 }}>
                <p style={{ margin: 0 }}>
                  Success depends on treating blockchain networks as observable
                  financial systems — drawing on the public data they expose,
                  though often only through substantial analytical and
                  infrastructure work.
                </p>
                <p style={{ margin: 0 }}>
                  My work — from institutional finance through independent
                  consulting — has centred on enabling data-driven decision-making
                  in materially risky environments. That same perspective now
                  informs monitoring and risk-support work for complex
                  digital-asset systems.
                </p>
              </div>

              <blockquote style={{
                position: "relative", margin: 0,
                paddingLeft: 18, fontSize: "1.02rem", lineHeight: 1.68,
                color: "rgba(237,241,247,0.86)"
              }}>
                <span style={{
                  position: "absolute", left: 0, top: 3, bottom: 3, width: 1.5,
                  background: "rgba(248,169,74,0.57)"
                }} />
                The results: clearer visibility, faster investigation, and stronger
                operating decisions in live financial environments.
              </blockquote>
            </div>
          </FadeIn>

          <FadeIn delay={0.18}>
            <div style={{
              position: "relative", overflow: "hidden",
              borderRadius: 12, border: "1px solid rgba(255,255,255,0.11)",
              background: "rgba(25,38,59,0.48)",
              boxShadow: "0 10px 24px rgba(0,0,0,0.18)"
            }}>
              <span className="mk-hairline-top" />
              <span className="mk-hairline-left" style={{ width: 2 }} />

              <div>
                {groups.map((g, gi) => (
                  <div key={g.title} style={{
                    position: "relative",
                    display: "grid",
                    gridTemplateColumns: "138px minmax(0, 1fr)",
                    gap: 24,
                    padding: "20px 12px 20px 28px",
                    borderTop: gi === 0 ? "none" : "1px solid rgba(255,255,255,0.04)"
                  }}>
                    <div style={{ display: "flex", alignItems: "start", gap: 10, paddingTop: 2 }}>
                      <span style={{
                        marginTop: 5, width: 6, height: 6, flex: "none",
                        borderRadius: "50%", background: "rgba(248,169,74,0.58)"
                      }} />
                      <p className="mk-eyebrow" style={{
                        margin: 0, letterSpacing: "0.14em", lineHeight: 1.3,
                        fontSize: 11.5
                      }}>{g.title}</p>
                    </div>
                    <ul style={{ margin: 0, padding: 0, listStyle: "none", display: "flex", flexDirection: "column", gap: 12 }}>
                      {g.items.map((item) => {
                        const s = split(item);
                        return (
                          <li key={item} style={{ position: "relative", paddingLeft: 14 }}>
                            <span style={{
                              position: "absolute", left: 0, top: 9,
                              width: 3, height: 3, borderRadius: "50%",
                              background: "rgba(166,180,200,0.46)"
                            }} />
                            <p style={{
                              margin: 0, fontSize: "0.97rem", lineHeight: 1.3,
                              color: "rgba(237,241,247,0.88)"
                            }}>{s.l1}</p>
                            {s.l2 && (
                              <p style={{
                                marginTop: 4, fontSize: "0.875rem", lineHeight: 1.3,
                                color: "rgba(237,241,247,0.82)"
                              }}>{s.l2}</p>
                            )}
                          </li>
                        );
                      })}
                    </ul>
                  </div>
                ))}
              </div>
            </div>
          </FadeIn>
        </div>
      </div>
    </SectionShell>
  );
}

Object.assign(window, { Background });
