// Marketing UI Kit — primitive components
// React 18 + Babel. No build step. Exported to window for cross-file access.

const { useState, useEffect, useRef } = React;

/* FadeIn — staggered entry */
function FadeIn({ children, delay = 0, className = "" }) {
  const style = { animationDelay: `${delay}s` };
  return (
    <div className={`mk-fade-in ${className}`} style={style}>
      {children}
    </div>
  );
}

/* SectionShell — hero | open | plate */
function SectionShell({ id, variant = "open", children, className = "" }) {
  return (
    <section id={id} className={`mk-section ${variant}`}>
      <div className={`mk-section-inner ${className}`}>{children}</div>
    </section>
  );
}

/* Button */
function Button({ variant = "cta", size = "default", children, as = "a", href = "#", onClick, className = "" }) {
  const cls = `mk-btn ${variant} ${size === "lg" ? "lg" : ""} ${className}`;
  if (as === "a") return <a href={href} onClick={onClick} className={cls}>{children}</a>;
  return <button onClick={onClick} className={cls}>{children}</button>;
}

/* Eyebrow + Section title */
function SectionHeading({ label, title, intro, introWide }) {
  return (
    <FadeIn>
      <p className="mk-eyebrow">{label}</p>
      <h2 className="mk-section-title">{title}</h2>
      {intro && <p className={`mk-section-intro ${introWide ? "wide" : ""}`}>{intro}</p>}
    </FadeIn>
  );
}

/* Card — domain/outcome card with mono index, title, body */
function DomainCard({ index, title, body, lead = false, delay = 0, spanClass = "" }) {
  return (
    <FadeIn delay={delay} className={spanClass}>
      <div className={`mk-card ${lead ? "lead" : ""}`}>
        {index != null && <p className="mk-card-index">{String(index).padStart(2, "0")}</p>}
        <h3 className="mk-card-title">{title}</h3>
        <p className="mk-card-body">{body}</p>
      </div>
    </FadeIn>
  );
}

/* Metric card — label + from → to */
function MetricCard({ label, from, to, delay = 0 }) {
  return (
    <FadeIn delay={delay}>
      <div className="mk-card" style={{ padding: "20px 20px" }}>
        <p style={{
          fontFamily: "var(--font-mono)", fontSize: 11, letterSpacing: "0.14em",
          textTransform: "uppercase", color: "rgba(166,180,200,0.86)", margin: 0
        }}>{label}</p>
        <p style={{
          marginTop: 8, fontSize: "1.07rem", fontWeight: 500,
          letterSpacing: "-0.01em", color: "rgba(237,241,247,0.96)", margin: "8px 0 0"
        }}>{from}&ensp;→&ensp;{to}</p>
      </div>
    </FadeIn>
  );
}

/* Engagement principle card with numbered left gutter */
function PrincipleCard({ index, title, body, delay = 0 }) {
  return (
    <FadeIn delay={delay}>
      <div className="mk-card" style={{ padding: "20px 20px 20px 56px", position: "relative" }}>
        <p className="mk-card-index" style={{
          position: "absolute", left: 20, top: 20, margin: 0
        }}>{String(index).padStart(2, "0")}</p>
        <h3 className="mk-card-title">{title}</h3>
        <p className="mk-card-body">{body}</p>
      </div>
    </FadeIn>
  );
}

/* Mark glyph (mask image) */
function Mark({ size = 20 }) {
  return (
    <span
      aria-hidden
      className="mk-mark"
      style={{ width: size, height: size }}
    />
  );
}

Object.assign(window, {
  FadeIn, SectionShell, Button, SectionHeading,
  DomainCard, MetricCard, PrincipleCard, Mark,
});
