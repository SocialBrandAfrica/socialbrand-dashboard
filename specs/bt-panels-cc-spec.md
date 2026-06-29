# Bonnie Tyler panels — CC wire brief

**SB-CD-WIRE-BT-001 · v1.0 · 29 Jun 2026 · CD → CC (relay via PM)**
**Scope:** L3 display only. CD owns the surface; CC owns the data + RPC shapes. Every panel reads
the `rpc_bt_*` engine outputs (SB-CC-BT-001) — display reads the engine, never computes.
**Reference renders (CD sandbox, project root):**
`BT Panel 1 - Scorecard.html` · `BT Panel 2 - Hero Availability.html` ·
`BT Panel 3 - Prune Monitor.html` · `BT Panel 4 - Buying Gauge.html` ·
`BT Panel 5 - Month-End Export.html`

All token-named, no raw hex. Build to the tokens in `dashboard.css` (live ground truth); where the
DS and the live repo disagree on a value, the live token wins.

---

## 0. Cross-cutting rules (apply to every panel except 5)

**Frost-reveal — use the component, NOT the sandbox veil.**
The mockups fake the Unfrost with an opacity-driven `.frost-veil` (a `backdrop-filter` overlay)
*because the `filter: blur → none` transition stalls in a plain static page.* **Do not port the
veil.** Bind the canonical contract instead:
- `loading={!dataReady}` on every `KpiCard` / `GlassCard`. While `true` the card is frosted
  (`--glass-blur-loading` 28px, `--glass-tint-frosted`) and content sits at opacity 0; flip `false`
  when the realtime value lands → it melts to `--glass-blur-rest` 14px over `--unfrost-duration`
  (800ms `--unfrost-ease`), border pulses Core Yellow once, content fades in on the same clock.
- Pass a placeholder during load: `R ——` for rand, `——%` for ratios, `———` for counts.
- Stagger `--unfrost-stagger` 80ms in reading order. Mobile (≤767px) drops per-element blur to the
  solid Charcoal Veld fallback (already in `glass.css`); reduced-motion → 150ms opacity only.

**Colour law.** Data colour (`--data-pos|neg|warn|neutral`) lives on marks, chips, lamps and
series strokes only — never on chrome or surfaces. Blue never touches a component or a line.

**Daisy CTA.** At most one `Button variant="daisy"` per view. Panels 1 and 4 use it for **Reload
data** (re-frosts then clears). Panels 2, 3, 5 have **no** daisy CTA.

**Type.** Fraunces hero/instrument numerals (`--font-display`), Geist Mono every figure/axis/code
(`--font-mono`), Geist chrome (`--font-ui`). `font-variant-numeric: tabular-nums` on every number.

---

## 1. Panel 1 — Scorecard (the spine)
**Feed:** `rpc_bt_scorecard` → basket gp + 12 sub-departments in 3 buckets (Groc Dly, HABA Dly,
HABA Roos) + per-row 13-month GP series + per-row delta vs baseline.

**Build from:** `GlassCard` (panel, `loading`) wrapping a 4-column grid:
`1fr 132px 104px 150px` → sub-dept name · GP rands (`--font-mono`, right) · delta chip · 13-month
sparkline.

- **Basket hero** = the odometer treatment: Fraunces numeral seated in a recessed well
  (`--well-shadow`), `--kpi-rail-focus` left rail, count-up 600ms on reveal. CD's mockup runs it
  oversized (~52px); **bring to the §6 hero spec ~32–36px** when you wire it (canon: hero numerals
  32px). Shows basket GP + a vs-baseline delta chip.
- **Delta chip — four-tone, reuse the Verdict Wall logic** (`kpiVerdict()` → tone): above baseline
  `pos`, flat (±1.5%) `neutral`, slipping (−1.5…−5%) `warn`, below baseline (<−5%) `neg`. Tone →
  `--data-*`. This is the same tone source the KPI numerals use; do not fork a second rule.
- **Sparkline:** thin 2px stroke coloured by the row's tone, 3px ringed live end-dot (continuous
  with the KPI sparkline idiom). 13 points = 13 months.
- **Bucket subtotal rows:** shaded (`rgba(255,255,255,0.045)`), mono uppercase label, weight 600.
- **Over target:** `pos` chip **plus a 7px Core-Yellow daisy dot** beside the name — a lamp-scale
  cue, never a fill (stays inside yellow rationing).

**States:** loading → frost-reveal + `R ——`. Empty month → `neutral`, "no data yet". 
**Acceptance:** basket hero == `rpc_bt_scorecard` basket gp (R 76 515/mo baseline; parts round to
R 76 517 — R2 is source rounding) · bucket subtotals shaded & correct · frost-reveal, no spinner.
*Per-row deltas in the mock are illustrative — replace with real month-vs-baseline from the RPC.*

---

## 2. Panel 2 — Hero availability strip — ⛔ BLOCKED
**Feed:** `rpc_bt_availability` → per hero: name, category, SOH, days-cover, status.
**BLOCKER: SB-CC-BT-FIX-001.** `rpc_bt_availability()` throws every call —
`column reference "store_code" is ambiguous` in `INSERT INTO bt_out_events` (a PL/pgSQL variable
shadows the column). One-line fix: `#variable_conflict use_column` at the top of the function body,
or rename the shadowing vars to `v_store_code` / `v_product_code`. **Design is done and signed;
wiring waits on this fix.** Test against the sample in the render once patched.

**Build from:** a `GlassCard` strip, one row per hero, columns `26px 1fr 240px 78px`:
- **Status lamp** = recessed-key LED: 18px well (`--lamp-bezel`) holding a radial-gradient dot in
  the status colour, glowing at lamp scale — `--data-neg` OUT, `--data-warn` SHORT, `--data-pos` OK.
- **Days-cover gauge** = the mechanical well track (`--well-shadow`), fill to the cover value
  coloured by status, a dashed reorder-point tick at **4 days**, scale 0–14. Value in `--font-mono`.
- **Status chip** mirrors the lamp tone.
- **Sort:** OUT and SHORT to the top (priority OUT→SHORT→OK), then ascending cover (most urgent
  first). This is the Monday-morning glance.

**Acceptance:** OUT + SHORT sort first · lamp colour == `status` from `rpc_bt_availability`.

---

## 3. Panel 3 — Prune monitor
**Feed:** `rpc_bt_prune_list` → dead SKUs (line, category, status, SOH, cash, last-sale, note) +
per-category dead counts.

**Build from:** `GlassCard` (`loading`) + the existing **disclosure pattern** (`<details>` idiom),
one row per category: chevron · name · dead-count (Fraunces) · chip.
- **Dead-count tone:** `warn` when > 0, `neutral` at 0 (see Deo Male: 0 dead but one VSLOW line).
- **Hero odometer:** total dead lines in a recessed well, `--data-warn`, count-up on reveal,
  "target → 0". Baseline 271.
- **Expander body:** dead-SKU list — line (with a status dot: `--data-neg` dead / `--data-warn`
  vslow), SOH, cash (`--font-mono`), last-sale, note. **SKUs holding stock get a flag:**
  `MARKDOWN` (Core-Yellow outline chip) for dead-holding stock, `RECODE` (`--data-warn`) for the
  miscoded VSLOW line.
- **No daisy CTA.**

**Acceptance:** counts match `rpc_bt_prune_list` · total reads 271 at baseline.
*Counts Skincare F 47 / Baby Food 42 / Cereals 36 are real; mock rolls the remainder to 144 to tie
271 — replace with the live per-category rollup.*

---

## 4. Panel 4 — Controlled-buying gauge
**Feed:** `rpc_bt_buying` → per SPAR store: monthly purchase-as-%-of-sales series + build rands.

**Build from:** one card per store (`loading`), each with two instruments:
- **Current-ratio gauge** = horizontal mechanical well (`--well-shadow`): 80–86% band shaded
  `rgba(102,187,106,0.20)`, **85% dashed reference**, a raised needle/knob (`--knob-shadow`) on the
  current (latest month) ratio. Scale 65–110%.
- **5-month trend** in a chart well (`--chart-well-bg` 0.22): the store line + a horizontal band
  zone (80–86) + the 85 dashed rule, point lamps coloured by tone, alarm points (>95%) ringed.
  Build-rand callout chip on the month where build is positive (`+R …`, only when positive).
- **Tone:** in-band `pos` · under 80 `neutral` (lean) · 86–95 `warn` · **>95 `neg` alarm** (chip +
  ringed dot + red numeral).

**⚑ CANON FLAG (needs your nod):** spec asked for a **steel-sky** Delareyville line and a **clay**
Roosville line. Blue is forbidden on a chart line (atmosphere only), so CD mapped the cool/warm
intent onto sanctioned series tokens — **Delareyville `--series-4` (cyan)**, **Roosville
`--series-6` (orange)**. The Brand Bible v2.3 six-hue series palette explicitly sanctions both, so
this is compliant; flag is informational. Re-pair on request.

**Acceptance:** Delareyville (10116) Apr 105.8% / build R 1 354 833 · Roosville (80175) May 98.5% /
build R 465 783 — match `rpc_bt_buying`.

---

## 5. Panel 5 — Month-end export (the only shareable surface)
**Feed:** `rpc_bt_month_end`. **Standalone print document — not a dashboard card.**

**Hard guardrails (PM-ratified):**
1. **No platform or internal naming anywhere** — no app name, no architecture, no layer language,
   no `rpc_*`, no project codename. The artefact shows the result, never the machine. Store names
   (the operator's own) are fine.
2. **Lead with the month ratio, never the volatile weekly numbers.** Purchase-ratio block is the
   first block under the hero, labelled "the month, not the week."

**Build:** print palette only (NOT the dark glass tokens) — white/Leaf-Grey paper, Veld Green
`#1E3F20` Fraunces headers, Charcoal `#1A1F1A` text, hairlines, **print data colours on light**
(`pos #2E7D32 · neg #C62828 · warn #E65100 · neutral #616161`). `@page { size: A4; margin: 14mm }`,
fits one page. No glass, no gradients, no chrome.

**Blocks:** header (month + basket GP vs baseline as the Fraunces hero) → **month purchase ratio
(lead)** → category GP vs baseline (table, ties to basket) → DC deals won → gap lines & sell-through
→ tail count.

**May mock figures (live = `rpc_bt_month_end`):** basket GP R 81 820 vs baseline R 76 515 →
**+R 5 304** · buckets Groc Dly +R 1 297 / HABA Dly +R 3 166 / HABA Roos +R 841 (sum = +R 5 304) ·
ratios Delareyville 84.6 / Roosville 98.5 · tail 271 · DC deals + gap lines both "none logged yet".
**Acceptance:** prints to one page · hero + bucket deltas match `rpc_bt_month_end`.

---

## 6. Token / size reference (canon, from the Brand Bible v2.3 + dashboard.css)
- KPI hero numerals **32px** Fraunces SemiBold tabular (bring Panel 1 + 3 heroes to this).
- Wells: `--well-shadow`; chart wells `--chart-well-bg` / `--chart-well-shadow`; knobs `--knob-shadow`;
  lamp bezel `--lamp-bezel`.
- KPI deep glass `--kpi-glass`, rail `--kpi-rail` (focus `--kpi-rail-focus`).
- Series `--series-1..6` (green/amber/pink/cyan/violet/orange — never blue, never `--core-yellow`).
- Motion: `--unfrost-duration` 800ms, `--unfrost-stagger` 80ms, count-up 600ms, hover 150ms.

## 7. New tokens
**None.** Every panel builds from existing tokens. If the live `dashboard.css` lacks `--lamp-bezel`
or the chart-well trio, add them from Appendix A of the Brand Bible (labelled there) — otherwise no
additions required.

## 8. Dependency summary
- **Critical path:** SB-CC-BT-FIX-001 (availability `store_code` ambiguity). Clear it → Panel 2
  wires with zero design change. PM also flagged closing the `product_search_index` hole alongside.
- Panels 1, 3, 4, 5 are ready to wire now against their live `rpc_bt_*` feeds.
