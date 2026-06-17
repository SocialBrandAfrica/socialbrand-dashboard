---
name: feedback_confront_on_ambiguous_terms
description: When Pieter uses a project term with multiple defined variants (ROS, SOH, qty, capital) and context doesn't pin which, clarify instead of assuming — but only when material
metadata:
  type: feedback
---

2026-06-13 (Pieter). Some project terms are FAMILIES, not single values (pantry-and-recipe model: L2 holds the pure variants, the branch/recipe picks which). When Pieter (or a brief) uses one without enough context, do NOT silently pick one.

**Confront trigger (narrow, do not hinder flow):** the word maps to >1 real variant in the dictionary AND context doesn't disambiguate AND the choice changes the answer materially. If a scenario default is obvious, state the assumption in one line and proceed instead of stopping. Hard-stop only when it matters. Ordinary words just flow.

**Phrase to teach, not to jargon-dump:** offer the choice in plain terms ("the rate we order on vs the rate we judge a season on"), not column names.

**Dictionary = the trigger list, canonical in RULE-BOOK §2/§3 (no new file).** Current families: Rate of sale (ordering ~28d units / 91d / by-weight / seasonal ~52w), Stock on hand (ledger=source of truth / snapshot / floor-counted), Quantity (selling-units EA vs weight KG — never a bare cross-unit sum), Capital tied (purified engine ~R10m vs raw soh×cost ~R21m).

**Why:** a rule written in one scenario doesn't hold across the bank; a bare term hides which assumption is in play (the qty +20% weighed-unit case is the live proof). Stops a branch masquerading as a fact. Applies to CC and PM both. See project_dash_source_migration.md, feedback_main_road_no_scope_drift.md.
