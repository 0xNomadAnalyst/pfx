// Header + Footer

function Header() {
  const links = [
    { label: "Platform", href: "#system" },
    { label: "Domains", href: "#capabilities" },
    { label: "Outcomes", href: "#outcomes" },
    { label: "Approach", href: "#approach" },
    { label: "Background", href: "#background" },
  ];
  return (
    <header className="mk-header">
      <div className="mk-header-inner">
        <a href="#top" className="mk-brand">Roderick McKinley, CFA, FRM</a>
        <nav className="mk-nav">
          {links.map((l) => <a key={l.href} href={l.href}>{l.label}</a>)}
          <Button variant="ghost" href="#contact">Contact</Button>
          <Mark size={20} />
        </nav>
      </div>
    </header>
  );
}

function Footer() {
  return (
    <footer className="mk-footer">
      <hr />
      <p>© 2026 Roderick McKinley</p>
    </footer>
  );
}

Object.assign(window, { Header, Footer });
