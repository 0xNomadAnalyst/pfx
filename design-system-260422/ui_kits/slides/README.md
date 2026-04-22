# Slide Deck UI Kit

A 1920×1080 deck system for McKinley Financial Systems, harmonised with the marketing and dashboard surfaces. Uses the `deck-stage` web component for scaling, keyboard nav, and print-to-PDF.

## Structure

```
index.html      ← 9-slide capabilities deck demonstrating every template
slides.css      ← scoped slide styles (imports ../../colors_and_type.css)
deck-stage.js   ← scaling shell (starter component)
```

## Example decks

- **`index.html`** — 9-slide capabilities briefing demonstrating the core templates
- **`Platform Architecture.html`** — 12-slide technical briefing demonstrating pipeline, layers, recovery, split, and 6-up templates
- **`Visual Reference.html`** — 9-slide reference deck demonstrating v1.2 templates: title-split, icon-card 5-up grid, stat-trio + callout, 5-step icon process, chart+legend, data table with status pills, quote+metric-grid with sparklines, closing icon strip

## v1.2 templates (visual reference)

- **Title split** (`.s-title-split` + `.s-hero-panel`) — copy left, embedded chart/screenshot right
- **Icon-card 5-up grid** (`.s-grid-5` + `.s-icard` + `.s-icard.focus`) — 3×2 grid where tile 1 spans two rows with amber-accent background; circular glyph + mono index per card
- **Stat-trio cards** (`.s-stat-card` with `.glyph` + `.label` + `.figure` + `.sub`) + **callout** (`.s-callout` with amber quote mark) — outcomes slide combo
- **5-step horizontal process** (`.s-process` + `.s-process-step` + `.s-process-footer`) — icon-topped steps with amber arrow connectors
- **Chart + legend** (`.s-legend` + `.item` + `.dot` + `.val`) — inline colour-dot legend with right-aligned values
- **Data table** (`.s-table` + `.s-status.healthy/monitor/risk`) — mono rows, tabular numerals, coloured status pills
- **Metric grid with sparklines** (`.s-metric-grid` + `.s-mini` + `.spark`) — 2×2 micro-cards with inline SVG sparklines and up/down deltas
- **Closing icon strip** (`.s-icon-strip` + `.s-glyph-amber`) — 3-up contact/engagement tiles with soft amber rounded-square glyphs
- **SVG icon sprite** — 15 mono line icons (1.6px stroke, 24px viewBox): eye, database, bars, compass, shield, trend, alert, search, grid, layers, code, target, focus, handshake, mail. Defined inline in Visual Reference.html; copy the `<defs>` block into other decks that need them.

## Templates available

Core (in `index.html`):
1. **Title** — brand mark + eyebrow + display H1 (108px) + lede
2. **Section divider** — large kicker label + 128px section title, ambient glow bg
3. **Domain grid** — 4-up card grid, mono `01/02/03/04` indices (extends to 3 or 6)
4. **Stat split** — large figure ("$2m → $840k") + supporting list, 1.05/0.95 asymmetric grid
5. **Three-up stats** — MetricStrip equivalent for print; before→after figures
6. **Quote** — amber left-rule blockquote, mono attribution
7. **Chart slide** — 2.1/1 grid, live Plotly chart + flanking stat stack
8. **Chip list** — 10 domain chips for topic scope
9. **Closing** — big mark + availability framing

Technical / process (in `Platform Architecture.html`):
10. **Two-column split** (`.s-split` + `.s-panel`) — A/B service comparison, "Not this / This", etc. Accent the recommended panel with amber border.
11. **Layered diagram** (`.s-layers` + `.s-layer`) — stacked horizontal bands (Data Sources → Ingestion → Data Platform → App → Ops). Use `.s-layer.accent` to highlight.
12. **4-step flow** (`.s-flow` + `.s-flow-step`) — connected pipeline with arrows between. Max 4 steps; use for ETL, incident-replay, any linear process.
13. **Recovery tiers** (`.s-tiers` + `.s-tier`) — large left numeral + title/description cards. Good for escalation chains, fallback policies, step-wise anything.
14. **6-up grid** (`.s-grid-6` + `.s-card`) — denser variant of the 4-up grid for 5–9 principles or tenets. Smaller type, same card vocabulary.
15. **Outcomes pill row** (`.s-outcomes` + `.pill`) — horizontal strip with a mono label + pill tags. Use as a slide footer band to summarise design principles or outcomes of a process.
16. **Credential chips** (`.s-creds` + `.cred`) — amber outlined chips for closing-slide credentials / contact info.

## Typographic scale for 1920×1080

| Token           | Size   | Use                                      |
|-----------------|--------|------------------------------------------|
| `.s-title-xl`   | 108px  | Hero title slide                         |
| `.s-title-lg`   | 76px   | Major content slide title                |
| `.s-title-md`   | 52px   | Standard content slide title             |
| `.s-section-title` | 128px | Divider slides only                    |
| `.s-lede`       | 32px   | Subtitle / below-title lede              |
| `.s-body`       | 26px   | Body paragraphs                          |
| `.s-list li`    | 24px   | Bulleted list items                      |
| `.s-stat .figure` | 84px | Primary display figures                  |
| `.s-eyebrow`    | 17px   | Mono uppercase eyebrow (amber-tinted)    |
| `.s-kicker`     | 14px   | Mono uppercase kicker (above content titles) |
| `.s-chrome`     | 15px   | Top/bottom mono rails (muted)            |

All sizes are absolute px because the deck-stage component handles responsive scaling.

## Background variants

- `.s-bg-plain` — page base (`#0B1220`). Default.
- `.s-bg-surface` — `#0D1627`. Section bands, three-up stats.
- `.s-bg-title` — page + two radial glows (steel upper-right, amber lower-left). Title + closing.
- `.s-bg-section` — deeper base (`#0A1020`) + stronger amber glow. Divider slides only.

Commit to **one or two** backgrounds per deck. `s-bg-plain` plus `s-bg-section` at every divider is the default rhythm.

## Chrome

Every slide has a top and bottom rail with mono uppercase text. Left rail = brand/section label with mark. Right rail = page number (`03 / 09`) or section name. Kept at 15px and 55% opacity — present but quiet.

## Exporting

- **To PDF**: `Cmd/Ctrl+P` — `deck-stage` handles one-slide-per-page print layout.
- **To PPTX**: call the export skill with width: 1920, height: 1080, `resetTransformSelector: "deck-stage"`, and a slide entry per `section` selector. Fonts: Inter + Geist Mono Google imports.

## Adding new slides

1. Start from the closest existing `<section data-screen-label="…">` in `index.html`.
2. Pick a background class (default = none → page base).
3. Top chrome: mark + section label. Bottom chrome: page-number counter.
4. Use `.s-kicker` + `.s-title-md` for content slides; `.s-section-label` + `.s-section-title` for dividers.
5. For metrics, always prefer `.s-stat` with `.label` + `.figure` + `.sub`. Tabular-nums is inherited.
6. Update the page counter (`XX / NN`) everywhere — the chrome counter is hand-written per slide on purpose.

## Voice reminders for deck copy

- First-person singular. *"This practice…", "My work…"*. Never *"we"*.
- No exclamation marks. No emoji. No "unlock", "transform", "empower".
- Every figure is approximate (~$2m, ~$840k) unless defensibly exact.
- Prefer verbs of observation ("monitoring", "visibility") over verbs of action ("delivering", "solving").
