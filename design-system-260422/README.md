# McKinley Financial Systems — Design System

**v1.1 · Consulting · Dark, analytical, institutional**

*Changelog: v1.1 — adds slide-deck UI kit (`ui_kits/slides/`) with nine layout templates, 1920×1080 canvas, harmonised chart styling, and print/PPTX export support. v1.0 — marketing + dashboard kits, token library, preview cards.*

A harmonised design system for the independent practice of **Roderick McKinley, CFA, FRM** — an independent financial-systems analyst and advisor working with leadership teams on monitoring, analytics, risk design, and decision-support infrastructure across DeFi and digital-asset environments.

This system unifies two existing surfaces into one visual language with charting capability:

| Surface | Codebase | Role |
|---|---|---|
| **Marketing site** (`rmckinley.net`) | `myweb/opus/` — Next.js 15 + React 19 + Tailwind v4 + shadcn/ui | Analytical briefing layer: positioning, credentials, engagement framing |
| **Dashboard** (`demo.rmckinley.net`) | `pfx` repo, `htmx/` subtree — FastAPI + htmx + Plotly + custom CSS | Operational layer: realtime DeFi risk, liquidity, MM performance |

The marketing surface was explicitly designed to feel *slightly lighter* than the dashboard so the transition from site → dashboard reads as "briefing layer → operational depth." This system preserves that relationship.

---

## Positioning & Voice

> "Understand and operate complex financial systems in realtime environments."

**Positioning:** principal-led independent financial-systems *practice* — not a consultancy, not a startup, not a freelancer portfolio.

**Subhead:** I build monitoring, analytics, and decision-support systems, and provide data-driven advisory for teams operating in DeFi and other complex digital-asset environments.

---

## Sources

**Codebases** (access on request — not redistributable):
- `myweb/opus/` — Next.js marketing site. Key files:
  - `app/globals.css` — dark-mode token definitions (OKLCH + hex)
  - `components/sections/*.tsx` — hero, capabilities, outcomes, engagement, background, contact
  - `components/ui/*.tsx` — shadcn/ui button, card, badge, input, textarea, separator
  - `components/shared/section-shell.tsx` — layout primitive
  - `components/shared/dashboard-screenshot-carousel.tsx` — dashboard preview carousel
- `myweb/stylemaster.md` — the canonical style brief (reproduced concepts throughout this README)
- `myweb/identitymaster.md` — the canonical voice/positioning brief
- `pfx/htmx/app/static/css/theme.css` — dashboard CSS (3200+ lines)
- `pfx/htmx/app/static/images/` — dashboard logos & favicons

**Imagery:** dashboard screenshot carousel in `assets/dashboard/` — six real-world DeFi analytics views (swap distributions, lending reserves, yields, risk surfaces, ecosystem map, stress tests).

---

## Index of this folder

```
README.md                     ← you are here
SKILL.md                      ← Agent Skills entry point (for Claude Code use)
colors_and_type.css           ← single import for all tokens (colors, type, spacing, radii, motion)
fonts/                        ← Inter-Variable, GeistMono-Variable (woff2)
assets/                       ← logos, icons, favicons, dashboard screenshot carousel
  dashboard/                  ← six real operational dashboard screenshots (.webp)
  TokenDesign_Icon_White.png  ← the "mark" used throughout the marketing site
  safari-pinned-tab.svg       ← monochrome mark
  shyft_logo.svg              ← data-source logo (dashboard footer)
ui_kits/
  slides/                     ← 9-slide capabilities deck (1920×1080, deck-stage)
    index.html, slides.css, deck-stage.js, README.md
  marketing/                  ← full marketing-site recreation
    index.html                ← interactive click-thru
    *.jsx                     ← Header, Hero, Capabilities, Outcomes,
                                Engagement, Background, Contact, Footer, primitives
  dashboard/                  ← operational dashboard recreation (with live charts)
    index.html                ← interactive click-thru, tab navigation
    *.jsx                     ← TopBar, Sidebar, Widget, MetricStrip, PlotlyChart,
                                DataTable, Filters, ViewHeader, etc.
preview/                      ← Design-System tab cards (registered assets)
```

---

## CONTENT FUNDAMENTALS

The voice is the *single most distinctive* element of this brand. It is quiet. It refuses to sell.

### Voice rules

- **Reflective, practitioner-led, understated.** "Calm, analytical, institutional."
- **Principal, not company.** Write in first-person singular: *"I work with…"*, *"My work…"*, *"This independent practice…"*. **Never** *"we"*, *"our"*, *"the team"*.
- **Practice, not services.** Prefer *"engagements"*, *"environments"*, *"systems"*, *"operational visibility"*, *"decision support"*, *"practice"*. Remove *"services"*, *"solutions"*, *"delivery"*, *"consulting firm"* framings.
- **Describe domains, not services.** Card titles read like system domains — *Risk Observability*, *Protocol State Monitoring*, *Market Microstructure Analysis*, *Decision Surfaces*, *Operational Intelligence*, *Failure & Stress Monitoring* — not *"We analyze…"*.
- **Ownership implied across the chain.** Every description hints at the full arc: *analysis → design → implementation → interpretation*. "Collapsing analytical and technical ownership."
- **No marketing exaggeration.** No superlatives, no "transform", no "unlock", no "empower", no "next-generation". No claims that aren't narrowly defensible.
- **Credibility anchor, not resume.** One quiet line: *"Roderick McKinley, CFA, FRM — Independent Financial Systems Analyst"*. Never biographical hero copy.
- **Selective framing on availability.** *"Selective engagements where operational visibility and system correctness are critical."* Never "book a call".

### Casing & mechanics

- **Headings:** Title Case with sentence-case connectives ("Where Visibility Matters Most", "Improvements with Financial Impact").
- **Eyebrow labels:** Mono, UPPERCASE, 11px, wide tracking — *"KEY OPERATIONAL DOMAINS"*, *"SELECTED CLIENT OUTCOMES"*, *"WORKING TOGETHER"*, *"BACKGROUND"*.
- **Card numbers:** zero-padded, mono, CTA-tinted: `01`, `02`, `03`…
- **Dashes:** en-dash or hyphen with spaces (` – ` or ` - `) for phrase joins. Em-dash sparingly.
- **Arrows:** `→` for outcomes (`~$2m → ~$840k`) — renders cleanly in mono.
- **Numbers:** tabular-nums for anything tabular. Approximations marked (`~$350M AUM`, `~$60M in raises`).
- **No emoji. Ever.** Not in the codebase, not in content, not as accents.
- **No exclamation marks.**

### Copy specimens (lift these verbatim if stuck)

> **Hero H1 —** *Understand and operate complex financial systems in realtime environments.*
>
> **Subhead —** *I build monitoring, analytics, and decision-support systems, and provide data-driven advisory for teams operating in DeFi and other complex digital-asset environments.*
>
> **Section intro —** *Teams managing live onchain financial operations often need support in one or more of these areas.*
>
> **Outcome line —** *Better visibility translated into concrete changes in operating model, market-maker oversight, and cost.*
>
> **Blockquote —** *The results: clearer visibility, faster investigation, and stronger operating decisions in live financial environments.*
>
> **Availability —** *Selective engagements where operational visibility and system correctness are critical.*

The subliminal goal is that a sophisticated visitor thinks *"this person can understand the problem before building anything — and can build what is required once understood."*

---

## VISUAL FOUNDATIONS

### Aesthetic intent

*Institutional trading platform* / *quantitative research environment* / *market analytics system* — never *startup dark mode* and never *pure-black developer theme*. Controlled, engineered, calm, low-glare, long-session readable.

### Color

**Forbidden:** `#000000`, `#050505`, pure black backgrounds, animated gradients, neon glow, bluish-purple gradients, saturated brand rainbows.

**Dark ≠ black.** The whole palette lives in deep-navy / graphite territory (OKLCH lightness ~0.08–0.18 on blue hues).

- **Surface hierarchy (L0 → L4):** `#0B1220` page → `#0D1627` section bands → `#10192E` muted / tags → `#172033` popovers → `#19263B` cards → `#1E2B42` hover. Depth comes from **tone differences**, not shadows.
- **Marketing vs dashboard tonality:** the marketing site is *slightly lighter* than the dashboard. Dashboard base is `#0a1020` (marketing is `#0B1220`). Preserve this relationship — marketing is the briefing layer above the operational depth.
- **Text:** `#EDF1F7` primary (never stark white), `#A6B4C8` muted, `#6B7794` quiet.
- **Accent:** warm amber only — `#F8A94A` (cta) and `#FF6B00` (cta-strong, ring). Used *sparingly*: CTA buttons, card numbering, hover ring, hairline accents on card left edges, focus rings.
- **Data / status:** `#36C96A` up, `#F65F74` down, `#4BB7FF` info, `#8FB7FF` table links.
- **Chart palette:** `#FF6B00 → #4BB7FF → #36C96A → #B085F5 → #F65F74 → #8EA1C7` (amber-forward, then cool series). Grid `rgba(255,255,255,0.06)`.

### Typography

**Inter** for everything body/heading. **Geist Mono** for labels, numbers, eyebrows, card indices, table cells, code. IBM Plex Mono is the acceptable fallback. Forbidden: Roboto, Arial as a design choice, system-ui as a display face, any hand-tuned display serif.

Rules: **medium weights preferred** (400–500 is the vocabulary; 600 is rare, 700 almost never). Tight headline hierarchy. Generous vertical spacing. **Never use oversized hero text** — the display scale tops out around 2.9rem / ~46px.

Type should feel like professional system documentation.

### Spacing

8pt base scale (`--space-1` = 4px through `--space-20` = 80px). Container max 1180px (1360px for feature variant). Sections: `py-9 md:py-12` for open variant, `py-9 md:py-12` inside a plate. Card internal padding scales 16/20/24/28 with the card's prominence.

### Borders

Always alpha-white on dark (`rgba(255,255,255,0.04/0.07/0.11)`) — never grays, never accent-colored borders by default. Radii are restrained: **6–12px on everything**. No pill rounding except tiny status dots and icon buttons.

### Elevation

- **Default cards:** no shadow. Depth is tonal (`bg-card` on `bg-background`).
- **Interactive cards (`.card-interactive`):** inset 1px top-highlight + subtle `0 10px 26px rgba(0,0,0,0.18)`. On hover: `translateY(-2px)` + slightly brighter inset + slightly stronger drop.
- **Modals / video dialogs:** the cta-glow ring — `0 0 17px rgba(248,169,74,0.25), 0 0 37px rgba(248,169,74,0.14)`. This is the *one* place glow is permitted.
- **Dashboard panels:** tonal only. Borders do the work.

### Backgrounds

- **No full-bleed hero imagery.** The hero is type + dashboard-carousel preview only.
- **No hand-drawn illustrations.** No decorative imagery. Real product screenshots (`assets/dashboard/`) only.
- **No repeating patterns / textures / grain.** None.
- **Gradients:** rare and muted. Three permitted uses: (1) the hairline top-edge gradient on some cards (`from-transparent via-border to-transparent`), (2) the left-edge amber hairline on mobile cards (`from-transparent via-cta/55 to-transparent` with small shadow), (3) large radial ambient glows on the background section (`radial-gradient(780px_380px_at_82%_12%, rgba(128,162,198,0.12), transparent)`) — imperceptible, atmospheric.
- **Imagery color vibe:** cool, engineered, data-dense. Never warm photography.

### Transparency & blur

Used for one thing: the **fixed header** (`bg-background/88 backdrop-blur-md`) and the mobile nav popover. Do not use glassmorphism on cards.

### Motion

**Allowed:** subtle fade-in (FadeIn component, 300–600ms, ease-out), minimal hover elevation (`translateY(-2px)` over 520ms), smooth color transitions (350–700ms). Entry fades staggered by `0.06–0.08s * index`.

**Forbidden:** animated gradients, parallax, attention-seeking motion, spring bounces on content, anything that competes with data.

Hover states: **brighten / warm** the surface (`hover:bg-accent`, border strengthens from `border-soft` → `border`, sometimes a faint cyan-blue outer glow on domain tags). **Never** darken on hover.

Press states: no transform-scale shrink. Default browser active behavior is fine.

### Layout rules

- **Fixed:** only the header (56px, full-width, blurred).
- **Container:** `max-w-[1180px]` with `px-6 sm:px-7 md:px-12` gutters.
- **Section rhythm:** eyebrow (mono uppercase) → section title (~2rem medium) → section intro (66ch muted) → content grid.
- **Card grids:** 12-col on marketing. First card in a 5-domain grid spans `lg:col-span-7` (lead card), second `col-span-5`, remaining three `col-span-4` — this is the signature layout rhythm.
- **Mobile:** all marketing sections ship a *separate* mobile layout (`md:hidden` / `hidden md:block`). Mobile cards are looser, with left-edge amber hairline accents.

### Card anatomy

- Border `border-strong` (`rgba(255,255,255,0.11)`), radius `rounded-lg` (8px), `bg-card` (`#19263B`).
- Prominence cues, in order of weight: (1) the `01/02/03` mono label in `text-cta/84`, (2) the `h3` title, (3) muted body copy at 0.95–0.98rem. Never ever color-code card left-borders (the left-edge amber hairline exists only on mobile summary cards and is a full-height gradient, not a solid stripe).

### Dashboard-specific (htmx surface)

- Panels: `#0f1a2d` on `#0a1020`. Border `#20314d`. Radius 6–8px.
- Plotly charts use the shared chart palette. Grid lines at `rgba(255,255,255,0.06)`. Chart text pure white. Tabular mono numbers throughout.
- Data tables: link color `#8fb7ff` → hover `#b8d2ff`. Positive `#36c96a`, negative `#f65f74`.

---

## ICONOGRAPHY

The brand uses almost no iconography — restraint is itself a design choice here. What does exist:

- **The mark.** `assets/TokenDesign_Icon_White.png` — a compact geometric glyph used in the header (14–20px, pure white with a very soft amber drop-shadow: `drop-shadow(0 0 5px rgba(248,169,74,0.32))`) and occasionally inline. It's applied via CSS `mask-image` so its color is controlled by the container.
- **Monochrome pinned-tab mark.** `assets/safari-pinned-tab.svg` — single-color SVG used for Safari pinned tab and as a fallback mark.
- **Favicons.** `assets/favicon-32x32.png`, `assets/apple-touch-icon.png`, `assets/android-chrome-192x192.png`.
- **Data-source logos** (dashboard only). `assets/shyft_logo.svg` — inline SVG shown in the dashboard footer as a data-source acknowledgement. Other protocol logos (Kamino, Orca, Exponent) appear as custom SVGs inside diagram components and in `assets/dashboard/*.webp` screenshots.
- **Controls (nav chevrons, close X, play triangle).** Inline SVGs — terse, 1.5–2px strokes or simple solid shapes. No icon font dependency.
- **Emoji:** **never.** Unicode-as-icon: only `→`, `&rarr;` in outcome lines.

**CDN substitution — flagged.** For generic UI controls in this design system (menu, search, close, chevron) that are not already in the codebase, use **Lucide icons** (CDN-linked: `https://unpkg.com/lucide-static@latest/`) as the nearest match — 1.5–2px stroke, geometric, monoline — and keep them at `currentColor`. *This is a substitution, not the codebase's own set. Flag for review and replace with hand-tuned inline SVG if the brand owner prefers.*

### Substitutions & caveats — please review

- **Fonts.** The real site uses Inter (Next.js `next/font/google`) and Geist Mono (likewise). I've shipped variable `.woff2` files from Fontsource CDN copies — visually identical for design use. If you want the exact Vercel/Rsms-published files, drop replacements into `fonts/` with the same filenames.
- **Icons.** No dedicated icon set in the codebase. Lucide is proposed as the default substitute for generic controls.
- **Deck.** The marketing codebase contains a `components/deck/` folder (slide infrastructure) but I did not find a fleshed-out sample deck with real content, so I have not created `slides/`. If you want one, attach a sample deck and I'll recreate the slide templates.

---

## Using this system (quick start)

```html
<link rel="stylesheet" href="colors_and_type.css">
<body>
  <p class="eyebrow">KEY OPERATIONAL DOMAINS</p>
  <h2 class="section-title">Where Visibility Matters Most</h2>
  <p class="section-intro">Domains where better monitoring, accountability, and system-level understanding have the greatest impact.</p>
</body>
```

For a full interactive specimen, open either UI kit's `index.html`.
