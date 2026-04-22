# Marketing UI Kit

A React recreation of the `rmckinley.net` marketing site, built on the shared design tokens in `colors_and_type.css`. Source: `myweb/opus/` (Next.js 15 + shadcn/ui + Tailwind v4). This kit is cosmetic-only — no Next.js, no real backend, no YouTube embeds — but every visual decision is lifted from the source.

## Structure

```
index.html       ← composed page (Header + Hero + ... + Footer)
marketing.css    ← scoped styles (imports ../../colors_and_type.css)
Primitives.jsx   ← FadeIn, SectionShell, Button, SectionHeading, DomainCard,
                   MetricCard, PrincipleCard, Mark
Header.jsx       ← fixed header + brand + nav + cta mark
Hero.jsx         ← H1, subhead, credibility line, cta, domain chips
Capabilities.jsx ← 5-domain grid with 7/5/4/4/4 column spans
Outcomes.jsx     ← 3 metric cards (from → to) + additional benefits list
Engagement.jsx   ← 2-col narrative + numbered principle cards
Background.jsx   ← narrative column + credentials panel (hairline accents)
Contact.jsx      ← form with mono uppercase labels
```

## Design decisions worth preserving

- **Principal voice.** Every copy string is first-person singular (*"I build…", "My work…"*) — see `CONTENT FUNDAMENTALS` in the root README.
- **5-step surface hierarchy.** All surfaces live in `#0B1220 → #1E2B42`. No pure black.
- **Accent used sparingly.** Amber (`--cta`, `--cta-strong`) appears only on: CTA buttons, `01/02/03` card indices, credential bullet dots, hairline left-edge accents, the logo drop-shadow, focus rings.
- **Card grid rhythm.** Lead card spans `7/12`; follower spans `5/12`; remaining three span `4/12` each. This is the signature layout move.
- **Ambient background glows.** `Background.jsx` uses two large radial gradients (steel + amber) at 12% opacity — imperceptible individually, atmospheric together.
- **Hairline accents.** Cards can carry a 1px top gradient (`via-border`) or a 1px-wide left gradient (`via-cta/55` with soft amber shadow). These replace the forbidden "rounded-card with colored left-border" anti-pattern.

## What's missing (intentional)

- Video modal (YouTube embed).
- Mobile layouts. The marketing codebase ships separate `md:hidden` / `hidden md:block` trees for most sections; this kit ships the desktop layouts only. Ping me if you need mobile too.
- The `system-diagram.tsx`, `exponent-diagram.tsx`, `orca-diagram.tsx` SVG system diagrams. These are bespoke per-protocol schematic components; reach for the source if you need them.
