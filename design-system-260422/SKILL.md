# McKinley Financial Systems — Agent Skill

You are working inside the design system for **Roderick McKinley, CFA, FRM** — an independent financial-systems analyst whose public surfaces are a marketing site (`rmckinley.net`, Next.js) and an operational dashboard (`demo.rmckinley.net`, FastAPI + htmx + Plotly). This folder harmonises both into one visual language.

## Before you write anything

Read these in order. Do not skip:

1. **`README.md`** — the single source of truth for voice, positioning, tokens, anti-patterns, and caveats. Contains the full `CONTENT FUNDAMENTALS` and `VISUAL FOUNDATIONS` sections. **The voice rules matter more than the visuals** — the brand's distinctiveness is 60% voice, 40% type/colour.
2. **`colors_and_type.css`** — the one file every downstream design should import. All tokens (colour, type, spacing, radii, motion) live here.
3. **The UI kit that matches your task:**
   - Web pages, site sections, hero compositions, proposals → `ui_kits/marketing/`
   - Dashboards, data widgets, Plotly charts, tables, operational UIs → `ui_kits/dashboard/`
   - Slide decks, capabilities briefings, any 1920×1080 presentation → `ui_kits/slides/`
4. **`preview/*.html`** — canonical specimens. If you're unsure what a token looks like in use, open the preview for that group.

## Quick-reference rules — things you will get wrong if you don't read the README

- **First-person singular voice.** *"I build…", "My work…", "This independent practice…"*. Never `we / our / the team`. Never `services`, `solutions`, `delivery`.
- **Dark is not black.** Page is `#0B1220` (marketing) or `#0A1020` (dashboard). Never `#000`. Depth comes from tonal separation, not shadows.
- **Amber is sparing.** `#F8A94A` and `#FF6B00` only on: CTA buttons, card `01/02/03` mono indices, credential bullet dots, left-edge hairline accents, focus rings, health pulse, chart-1. Never as a border, never as background fill.
- **Medium weights preferred.** Headings are 500, body 400. 600 is rare. 700 almost never.
- **Mono for labels and numbers only.** Geist Mono (fallback IBM Plex Mono) — eyebrows, card indices, metric values, table cells, status deltas.
- **Never emoji.** Never exclamation marks.
- **Never invent outcomes or credentials.** Use the exact copy in `README.md`'s "Copy specimens" block if you need filler — lifting verbatim is safer than paraphrasing.
- **Cards: border-strong, 8px radius, no shadow by default.** Interactive cards get `--shadow-panel` + translateY(-2px) on hover.
- **Left-border-accent cards are forbidden.** The hairline left accent is *1px gradient with amber glow*, full-height, used only on mobile summary cards (see `mk-hairline-left` in `marketing.css`).

## Doing a task

1. Start from the nearest existing artifact — don't write from scratch. `ui_kits/marketing/Capabilities.jsx` is the template for any 5-card grid; `ui_kits/dashboard/Views.jsx::OverviewView` is the template for any dashboard landing.
2. Import `colors_and_type.css`. Never inline colour values; reference tokens (`var(--fg-muted)`, etc.).
3. If you add charts, use `Charts.jsx`'s pre-themed helpers (`AreaChart`, `LineChart`, `BarChart`, `StackedAreaChart`, `DonutChart`). They apply `CHART_LAYOUT_BASE` consistently.
4. If the user asks for something out of scope (e.g. a slide deck, an email template, a pitch PDF) — check `README.md > Substitutions & caveats` before inventing patterns. If the surface genuinely doesn't exist yet, flag it.

## Flagged substitutions you may need to surface to the user

- **Fonts** are Fontsource CDN-copied `.woff2` files, not the Next.js `next/font/google` originals. Visually identical.
- **Icons** — no codebase icon set. Dashboard kit ships a small hand-tuned set (`Ico` in `Chrome.jsx`, Lucide-style at 1.5-1.75px stroke). Extend that set rather than adding a new dependency.
- **Mobile layouts for the marketing site** are not in this kit. The real codebase ships them separately (`md:hidden` / `hidden md:block` trees).
- **System/protocol diagrams** (system-diagram.tsx, orca-diagram.tsx, etc.) are bespoke SVG components in the codebase — not reproduced here. Ask for the source if needed.

## Do not

- Do not add gradients except the three permitted uses documented in README.
- Do not add drop-shadows to default cards.
- Do not use pure white (`#FFFFFF`) for text. Use `--fg-1` (`#EDF1F7`).
- Do not invent new chart colours outside the 6-colour palette.
- Do not round corners beyond 14px (except icon buttons and tag pills).
- Do not use icons from a generic web stock set. Either use the provided `Ico` set or ask.
