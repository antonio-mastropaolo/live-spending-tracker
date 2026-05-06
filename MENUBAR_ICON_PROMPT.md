# Menu-Bar Icon Design Prompt (reusable)

Use this prompt to generate **40 candidate icons** for any macOS menu-bar app, rendered as an interactive HTML preview matching the format of `icon-preview.html`.

---

## Prompt template

> Design 40 candidate menu-bar icons for **{{APP_NAME}}** ({{ONE_LINE_DESCRIPTION}}).
>
> **App context**
> - Domain: {{DOMAIN}} (e.g., AI cost tracking, network intelligence, productivity, security)
> - Status surfaced in the menu bar: {{LIVE_VALUE}} (e.g., dollar amount, alert count, status dot, none)
> - Mood: {{MOOD}} (e.g., neon/flashy, sober/professional, futuristic, organic)
>
> **Symbolic vocabulary** — draw concepts from at minimum these themes: {{THEMES_LIST}}
>
> **Color palette** — primary: {{PRIMARY_HEX}}, accents: {{ACCENT_HEXES}}, alert: {{ALERT_HEX}}, neutral: `#f5f5f7` on `#1c1c1e` background.
>
> **Output**: a single self-contained HTML file (`{{slug}}-icon-preview.html`) with:
> 1. **Sticky menu-bar strip** (top, 28pt high) showing all 40 options inline at 14pt size, each clickable.
> 2. **Card grid** of all 40, split into two sections — `Static (1–10)` and `Animated / Color (11–40)`. Each card: number badge, large 52pt icon, SF Symbol-style label, one-line description.
> 3. **1:1 preview row** at the bottom showing each icon at exact menu-bar size (14pt).
> 4. Click any item (strip / card / row) → highlights all three locations and scrolls the corresponding card into view.
>
> **Categorization (40 total)**
> - **1–10 Static** — single SF-Symbol-style glyphs, monochrome or single-tint, no animation. These are the "always works in any context" candidates.
> - **11–25 Animated** — pure-monochrome SVG with `<animate>`/CSS animations: spin, pulse, sweep, blink, draw-on, count-up.
> - **26–35 Color-rich** — gradients, multi-tone palettes, neon glows, shimmer effects.
> - **36–40 Conceptual** — playful / brand-forward (mascot, monogram, abstract logo).
>
> **SVG conventions**
> - All icons drawn in a `0 0 20 20` viewBox so they scale identically.
> - Use SF Symbol naming where a real symbol exists (`shield.fill`, `eye.circle`, etc.); use `anim.*`, `color.*`, `concept.*` prefixes for invented ones.
> - Animations defined via inline `<style>` keyframes attached by class — keep them subtle (1–3s loops, eased).
> - Glows = `filter: drop-shadow(0 0 Npx color)` or stacked `<feGaussianBlur>`; never use heavy drop shadows that simulate Y-offset depth (menu-bar icons should look flat-glow, not skeuomorphic).
>
> **Layout style** (from `icon-preview.html`):
> - Background `#1c1c1e`, text `#f5f5f7`.
> - Menu-bar strip: `#2d2d2f` with subtle bottom shadow, sticky, items have `border-radius: 5px`, `:hover` lifts background to `rgba(255,255,255,0.12)`, `.active` to `rgba(255,255,255,0.16)`. Number badge `mb-num` floating top-left.
> - Cards: 4-column grid, each card `aspect-ratio: 1.3`, dark gradient, `border-radius: 12px`. Hover scale 1.04. Selected: 2px blue outline (`#0a84ff`).
> - Preview row: horizontal scroll, each item shows the icon at 14pt with a status sample to the right.
>
> **Selection logic** (single source of truth via `selectOption(num)`):
> - Toggling selection updates classes on `card-{num}`, `mb-{num}`, and outline on `preview-{num}`.
> - Both card and menu-bar item scroll into view on select.
>
> Render the file. Open it in a browser; the user picks a number, then I update `AppDelegate.renderIcon(...)` to draw it.

---

## Mapping the chosen icon to `AppDelegate.renderIcon`

Once the user picks option N:

1. Locate `S.<svgFn>` in the HTML — that defines the geometry.
2. Translate the geometry to AppKit drawing primitives in `renderIcon(total:stale:)`:
   - `<path>` / `<rect>` / `<circle>` → `NSBezierPath`
   - SVG fill colors → `NSColor.setFill()`
   - SVG `<animate>` → drive via the existing 30fps Timer in `AppDelegate.tick()`, using `pulsePhase` and `flashIntensity`.
3. Always finish with `img.isTemplate = false` so colors survive (see `feedback_menubar_template_rendering.md`).
4. Re-run `xcodegen generate && xcodebuild ... build && cp -R ... /Applications/`.

---

## Quick recipe to apply to a new app

1. Copy this file into the new project as `MENUBAR_ICON_PROMPT.md`.
2. Fill in `{{APP_NAME}}`, `{{ONE_LINE_DESCRIPTION}}`, `{{DOMAIN}}`, `{{LIVE_VALUE}}`, `{{MOOD}}`, `{{THEMES_LIST}}`, `{{PRIMARY_HEX}}`, `{{ACCENT_HEXES}}`, `{{ALERT_HEX}}`, `{{slug}}`.
3. Hand the filled-in prompt back to Claude and ask it to render the HTML.
4. Open the resulting file, click your favorite, and ask Claude to wire it into the menu-bar code.
