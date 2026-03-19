# Website color reference

Key colours for the risk dashboard UI (HTMX app), in **dark** and **light** modes.  
Defined in `static/css/theme.css` via CSS custom properties.

---

## Dark mode (`:root` / default)

| Variable | Hex / value | Usage |
|----------|-------------|--------|
| `--bg` | `#0a1020` | Page background |
| `--panel` | `#0f1a2d` | Cards, panels, inputs |
| `--panel-2` | `#101f35` | Topbar, bottombar, secondary surfaces |
| `--text` | `#d7def0` | Primary text |
| `--muted` | `#8ea1c7` | Secondary text, labels, placeholders |
| `--border` | `#20314d` | Borders, dividers |
| `--accent` | `#4bb7ff` | Links, buttons, focus, highlights |
| `--good` | `#36c96a` | Success, positive states |
| `--bad` | `#f65f74` | Error, negative states |
| `--table-link` | `#8fb7ff` | Table link default |
| `--table-link-hover` | `#b8d2ff` | Table link hover |
| `--scrollbar-track` | `rgba(255, 255, 255, 0.03)` | Scrollbar track |
| `--scrollbar-thumb` | `rgba(142, 161, 199, 0.28)` | Scrollbar thumb |
| `--scrollbar-thumb-hover` | `rgba(142, 161, 199, 0.42)` | Scrollbar thumb hover |

**Tooltip (dark theme)** — `[data-theme="dark"]`:

| Variable | Value | Usage |
|----------|--------|--------|
| `--tooltip-bg` | `rgba(240, 243, 255, 0.97)` | Tooltip background |
| `--tooltip-fg` | `#141828` | Tooltip text |
| `--tooltip-border` | `rgba(80, 100, 160, 0.2)` | Tooltip border |

---

## Light mode (`html[data-theme="light"]`)

| Variable | Hex / value | Usage |
|----------|-------------|--------|
| `--bg` | `#eef2f9` | Page background |
| `--panel` | `#ffffff` | Cards, panels, inputs |
| `--panel-2` | `#f8fbff` | Topbar, bottombar, secondary surfaces |
| `--text` | `#11203a` | Primary text |
| `--muted` | `#5f7396` | Secondary text, labels, placeholders |
| `--border` | `#d7e0ef` | Borders, dividers |
| `--accent` | `#0a78f0` | Links, buttons, focus, highlights |
| `--good` | `#1f9d52` | Success, positive states |
| `--bad` | `#d83455` | Error, negative states |
| `--table-link` | `#2e6fd8` | Table link default |
| `--table-link-hover` | `#1f5fc8` | Table link hover |
| `--scrollbar-track` | `rgba(12, 25, 47, 0.06)` | Scrollbar track |
| `--scrollbar-thumb` | `rgba(32, 49, 77, 0.26)` | Scrollbar thumb |
| `--scrollbar-thumb-hover` | `rgba(32, 49, 77, 0.4)` | Scrollbar thumb hover |

**Tooltip (light theme)** — `[data-theme="light"]`:

| Variable | Value | Usage |
|----------|--------|--------|
| `--tooltip-bg` | `rgba(18, 22, 38, 0.96)` | Tooltip background |
| `--tooltip-fg` | `#e4e9f4` | Tooltip text |
| `--tooltip-border` | `rgba(180, 195, 220, 0.18)` | Tooltip border |

---

## Cover page accent (both modes)

Used for section titles and welcome panel on the cover page (`body[data-current-page-slug="cover"]`):

| Variable | Hex | Usage |
|----------|-----|--------|
| `--cv-accent` | `#f0a020` | Primary warm accent |
| `--cv-accent-soft` | `#f8a94a` | Softer accent (section titles in dark mode) |
| `--cv-accent-dim` | `#e8853d` | Dimmer variant |

**Light mode overrides (cover):**

- Section title colour: `#1a2f5a` (replaces `--cv-accent-soft` for section headers).
- Section header underline uses `color-mix(in srgb, #1a2f5a 30%, var(--border))`.

---

## Other hardcoded colours (theme.css)

| Hex | Context |
|-----|---------|
| `#f0a020` | Pipeline switcher border/label (matches `--cv-accent`) |
| `#2fbf71` | One-off success/green (e.g. health) |
| `#36c96a` | Health dot green (same as `--good` in dark) |
| `#f65f74` | Health dot red (same as `--bad` in dark) |
| `#141828` | Tooltip text (dark theme tooltip) |
| `#e4e9f4` | Tooltip text (light theme tooltip) |
| `#1a2f5a` | Cover section title in light mode |

---

## Summary swatches

**Dark mode:**  
`#0a1020` · `#0f1a2d` · `#101f35` · `#d7def0` · `#8ea1c7` · `#20314d` · `#4bb7ff` · `#36c96a` · `#f65f74`

**Light mode:**  
`#eef2f9` · `#ffffff` · `#f8fbff` · `#11203a` · `#5f7396` · `#d7e0ef` · `#0a78f0` · `#1f9d52` · `#d83455`

**Cover / pipeline accent:**  
`#f0a020` · `#f8a94a` · `#e8853d` · `#1a2f5a` (light cover titles)
