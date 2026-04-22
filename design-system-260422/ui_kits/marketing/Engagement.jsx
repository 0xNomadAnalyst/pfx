// Engagement — 2-col layout: narrative + numbered principle cards

function Engagement() {
  const principles = [
    {
      title: "Principal-Led Delivery",
      description:
        "You work directly with the person defining analysis, models, and operational systems — without delivery layers or handoffs.",
    },
    {
      title: "Integrated Advisory & Build",
      description:
        "Analytical definition and technical implementation remain aligned throughout the engagement, ensuring decisions translate into working systems.",
    },
    {
      title: "Designed for Internal Ownership",
      description:
        "Systems and analytical frameworks are transferred so internal teams can understand, operate, and extend them independently.",
    },
  ];
  return (
    <SectionShell id="engagement" variant="open">
      <div className="mk-grid-2">
        <FadeIn>
          <div style={{ maxWidth: 520 }}>
            <p className="mk-eyebrow">Working Together</p>
            <h2 className="mk-section-title">What Engagement Looks Like</h2>
            <p className="mk-section-intro" style={{ marginTop: 20, maxWidth: "56ch" }}>
              A compact, principal-led model designed to stay close to operating
              realities and avoid fragmentation between analysis, implementation,
              and handover.
            </p>
            <p style={{
              marginTop: 20, fontSize: "1rem", lineHeight: 1.7,
              color: "rgba(166,180,200,0.92)", maxWidth: "56ch"
            }}>
              Engagements are shaped around the specific operational problem,
              internal team structure, and level of support required. Some begin with
              diagnostic analysis, policy review, or strategic advisory; others extend
              into monitoring design, implementation, or refinement of an existing system.
            </p>
            <p style={{
              marginTop: 20, fontSize: "1rem", lineHeight: 1.7,
              color: "rgba(166,180,200,0.9)", maxWidth: "56ch"
            }}>
              The aim is to keep analytical definition, technical execution, and
              operational context aligned throughout — so useful work happens
              quickly and internal teams can take ownership without unnecessary
              delivery layers.
            </p>
          </div>
        </FadeIn>

        <div style={{ display: "flex", flexDirection: "column", gap: 14, position: "relative" }}>
          {principles.map((p, i) => (
            <PrincipleCard
              key={p.title}
              index={i + 1}
              title={p.title}
              body={p.description}
              delay={0.08 * (i + 1)}
            />
          ))}
        </div>
      </div>
    </SectionShell>
  );
}

Object.assign(window, { Engagement });
