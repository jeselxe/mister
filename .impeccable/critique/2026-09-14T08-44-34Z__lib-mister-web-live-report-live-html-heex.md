---
target: the player rows
total_score: 25
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
timestamp: 2026-09-14T08-44-34Z
slug: lib-mister-web-live-report-live-html-heex
---
⚠️ DEGRADED: single-context (no sub-agent/Task tool exposed; detector parser modules and Puppeteer unavailable)

# Critique: the player rows

Target: `lib/mister_web/live/report_live.html.heex` (clausulazo, bid, watch, sell, sell-hint and checklist rows) · Mode: Operate · Surface: daily report dashboard

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Loading/`phx-click-loading` and live slider added; no global "analysis running" progress beyond a flash |
| 2 | Match System / Real World | 3 | Domain-accurate (clausulazo, media, valor) but `ratio pts/M€`, `banca`, and the 95–105% band assume expertise |
| 3 | User Control and Freedom | 3 | Checklist undo/dismiss and offer "mantener en venta"; **Aceptar oferta is final with no undo** |
| 4 | Consistency and Standards | 3 | Row anatomy is consistent (photo, position, name, chips, meta); sell rows diverge with the range grid + offer panel (justified) |
| 5 | Error Prevention | 3 | Accept is gated by the advice and disabled otherwise; still one click, no confirmation |
| 6 | Recognition Rather Than Recall | 3 | Points, price, band and gain are in-row; `title` tooltips only |
| 7 | Flexibility and Efficiency | 2 | No batch actions, no keyboard shortcuts, 26 checklist clicks, no anchor nav on a ~2.5k px page |
| 8 | Aesthetic and Minimalist Design | 2 | Up to ~13 fields + a slider per fichaje row; the checklist duplicates every section |
| 9 | Error Recovery | 2 | Failed actions surface as a flash and a list reload; no inline retry or preserved context |
| 10 | Help and Documentation | 1 | Only `title` tooltips; no inline explanation of ratio, band or premium |
| **Total** | | **25/40** | **Acceptable (62.5%)** |

## Design Specificity Verdict

**This is authored for Mister, not category-interchangeable.** The clause row compares the clause price to the player's market value and colours the premium; the fichaje row models the bank's 95–105% resale band and computes gain against the bid; the sell row crosses "en venta" with the optimal XI and blocks an offer on a starter. A generic roster table cannot produce any of those.

**LLM assessment**: The row *families* are coherent and the information is product-true. What is less authored is the *row anatomy*: it has accreted into a flat one-liner plus badges plus a slider, so every field competes at roughly the same weight. The composition is "everything visible at once", which is the safe default rather than a decided hierarchy. The strongest authored moment (the bid slider) is also the most under-signposted: it has no visible endpoints, so the market-price-to-break-even story only reads if the user already knows the band.

**Deterministic scan**: unavailable. `detect.mjs` loaded but ran DEGRADED (missing `htmlparser2`, `css-select`, `css-tree`, `domutils`), so custom properties, selector matching and computed contrast were not evaluated; it returned `[]` as an undercount, not a clean bill. No user-visible overlay: browser injection is unavailable (no Puppeteer).

## Overall Impression

The rows are honest and information-complete, which is rare in a fantasy-football tool, and the polish pass already lifted contrast, focus and states. The problem is no longer correctness, it is that the rows refuse to rank their own contents. Each fichaje row asks the eye to weigh points, media, price, seller, growth, a resale band, a gain, a bid and a slider at once, and then the same decision reappears in the checklist. The biggest single opportunity: **make the row's primary decision loud and demote the supporting numbers**, and stop duplicating decisions across sections and checklist.

## What's Working

1. **Product-grounded signals.** Clause premium over market value, the bank resale band, `banca` vs `usuario`, and the `titular` conflict badge are decisions, not decoration. They encode rules only this league has.
2. **The bid slider.** Turning a static recommendation into an explorable market-price-to-break-even range with live gain is a genuinely good idea, and it is keyboard-operable.
3. **Consistent row skeleton.** Photo, position badge, name, trend/source chips and a numeric meta line repeat across all five families, so the lists are learnable even when the data differs.

## Priority Issues

### [P1] The checklist duplicates every section
**What**: The 26-row "Tareas del día" repeats each clausulazo, puja, venta, `unsell` and `list` that already appears above.
**Why it matters**: The user reconciles two sources of the same decision, the page doubles in height, and a dismissed section row can still live on as a pending checklist row.
**Fix**: Make the checklist the only action surface for decisions (inline checkboxes on the rows) or collapse it to a compact strip that mirrors section counts, not full sentences.
**Suggested command**: `$impeccable distill`

### [P1] Fichaje rows carry too many equally weighted numbers
**What**: A bid row shows position, name, trend, source, total points, media, price, seller, 7-day growth, resale band, gain, suggested bid and a slider.
**Why it matters**: The primary decision (what to bid) competes with metadata; scanning seven bid rows means parsing ~90 numbers.
**Fix**: Keep name, price, expected gain and `pujar hasta` as the row face; move band, ratio and seller to a second muted line or a tooltip; put the slider behind an "ajustar puja" disclosure.
**Suggested command**: `$impeccable distill`

### [P2] No efficiency path for a power user
**What**: No batch "marcar todas", no keyboard shortcuts, no section anchors or sticky summary, 26 one-by-one checklist clicks.
**Why it matters**: The daily loop is ~30 decisions; the interface makes each one a pointer trip down a 2.5k px page.
**Fix**: Add a "hecho todo lo pendiente" action, `j`/`k`-style row traversal for the checklist, and a sticky count strip with anchors to each section.
**Suggested command**: `$impeccable layout`

### [P2] Accepting an offer is irreversible and unconfirmed
**What**: "Aceptar oferta" completes a final sale in one click, with no confirm step and no undo window.
**Why it matters**: A misclick loses a player permanently; the advice gating reduces but does not remove the risk, especially on the narrow sell card where accept/keep sit adjacent.
**Fix**: Add a lightweight confirm ("¿Aceptar 12.3M?") or a 5-second undo toast that reverses the request.
**Suggested command**: `$impeccable harden`

### [P3] Domain terms have no inline help
**What**: `ratio pts/M€`, `banca`, `premium sobre valor` and the 95–105% band are used without a key.
**Why it matters**: The rows are opaque to anyone but the author, and even the author will forget the score formula.
**Fix**: One-line inline hints on the column labels or a collapsible legend at the top of each list.
**Suggested command**: `$impeccable clarify`

## Persona Red Flags

**Alex (Power User)**: Cannot complete the daily loop efficiently. 26 checklist items must be clicked individually, there is no "mark all", no keyboard shortcut for complete/dismiss, and no way to jump to fichajes or ventas without scrolling ~2.5k px. The slider is his one accelerator, and it is buried inside each row.

**Sam (Accessibility-Dependent)**: Focus rings and contrast are now themed (good). Remaining: icon-only buttons (`complete-action-*`, `dismiss-action-*`, `refresh-offers`) carry only `title`, which is announced inconsistently; `aria-label` is more robust. The `·` separators are announced as "middle dot" noise on every meta line. Sliders have an `aria-label` but no visible min/max, so the "price to break-even" range is invisible to sighted and screen-reader users alike.

**Riley (Stress Tester)**: Player names arrive with `💥` and accents, and the sell card shows pessimistic/expected/optimistic as three equal cells, so a negative `projected_value` reads as a normal range. Missing CDN images fall back to alt text with no placeholder shape. With `growth_7d` nil the row prints "sin datos" but still shows a slider, implying a projection that does not exist.

## Minor Observations

- The "sin puja" badge and the "pujar hasta" badge are the only structural difference between the Seguir and Pujar lists besides the subhead; a stronger visual split (muted vs accent) would separate them at a glance.
- `title` tooltips on the source and clause-premium badges are invisible on touch.
- The sell-hint reason is plain red text; a small severity chip would rank multiple hints.
- Watch rows at `xl` sit two-up, so their sliders are narrower than the bid rows above them, breaking column rhythm inside the same card.
- Money uses dot thousands while growth percentages use dot decimals (`+12.5%`), which is internally consistent but not Spanish convention.

## Questions to Consider

- If the checklist and the sections are the same decisions, which one deserves to exist?
- What is the single number a bid row must communicate, and can the other ten move behind one disclosure?
- Does the slider belong on every fichaje row, or only where the market-price margin is close to the bid?
- Would a sticky "hoy: 3 clausulazos, 2 pujas, 2 ventas" strip remove the need to read the page top to bottom?
