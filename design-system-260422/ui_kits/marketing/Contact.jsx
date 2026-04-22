// Contact — minimal form. Cosmetic only; no backend.

function Contact() {
  const [submitted, setSubmitted] = useState(false);
  return (
    <SectionShell id="contact" variant="open">
      <SectionHeading
        label="Availability"
        title="Selective Engagements"
        intro="Selective engagements where operational visibility and system correctness are critical."
      />

      <form
        onSubmit={(e) => { e.preventDefault(); setSubmitted(true); }}
        style={{
          marginTop: 32, maxWidth: 620,
          display: "flex", flexDirection: "column", gap: 14
        }}
      >
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12 }}>
          <FormField label="Name" name="name" />
          <FormField label="Organisation" name="org" />
        </div>
        <FormField label="Email" name="email" type="email" />
        <FormField
          label="Context"
          name="context"
          textarea
          placeholder="Briefly: the operational environment, the problem you're seeing, and what support you're considering."
        />
        <div style={{ marginTop: 8 }}>
          <Button variant="cta" as="button" size="lg">
            {submitted ? "Message sent" : "Send message"}
          </Button>
        </div>
      </form>
    </SectionShell>
  );
}

function FormField({ label, name, type = "text", placeholder, textarea = false }) {
  const common = {
    name,
    placeholder,
    style: {
      width: "100%",
      background: "rgba(16,25,46,0.6)",
      border: "1px solid var(--border-strong)",
      borderRadius: 8,
      padding: "10px 12px",
      color: "var(--fg-1)",
      fontFamily: "var(--font-sans)",
      fontSize: 14,
      lineHeight: 1.5,
      outline: "none",
      transition: "border-color 280ms, background-color 280ms",
    },
    onFocus: (e) => { e.target.style.borderColor = "rgba(248,169,74,0.58)"; },
    onBlur:  (e) => { e.target.style.borderColor = "var(--border-strong)"; },
  };
  return (
    <label style={{ display: "flex", flexDirection: "column", gap: 6 }}>
      <span style={{
        fontFamily: "var(--font-mono)", fontSize: 11, letterSpacing: "0.14em",
        textTransform: "uppercase", color: "rgba(237,241,247,0.86)"
      }}>{label}</span>
      {textarea
        ? <textarea rows={4} {...common} />
        : <input type={type} {...common} />}
    </label>
  );
}

Object.assign(window, { Contact, FormField });
