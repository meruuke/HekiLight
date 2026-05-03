# EPIC-6: Keybind Robustness

**Status:** In Progress
**Version range:** v0.5.0 → current
**Depends on:** EPIC-5 (Done)

## Goal

Fix a class-specific keybind display regression triggered by shapeshifting (Balance Druid Travel Form, Feral forms, any form-shifting class). Keybinds are blank when a target is acquired out of combat after a shapeshift because `keybindCache` is wiped by `ACTIONBAR_SLOT_CHANGED` and only a single `Refresh()` fires before the transient `FindSpellActionButtons` window closes. Once combat starts the poll loop resolves the lookup, making the bug appear combat-gated.

## Business Value

Players who use Travel Form or other shapeshift abilities between pulls see no keybind text on the suggestion icon when they engage a target. This erodes trust in the addon's correctness and disproportionately affects Druid players, one of the most popular classes.

## Stories

| ID  | Title                                        | Status  |
|-----|----------------------------------------------|---------|
| 6.1 | Shapeshift-resilient keybind cache repopulation | Draft |

## Key Technical Context

- `ACTIONBAR_SLOT_CHANGED` fires on shapeshift → `wipe(keybindCache)` runs (line ~1991)
- Out of combat, `Refresh()` only fires on `ACTIONBAR_UPDATE_STATE` — no poll loop
- `FindSpellActionButtons` has a transient nil window immediately after a slot change
- `keybindCache` fallback is the defence for this window, but it was just wiped
- Fix strategy: schedule a one-shot deferred `Refresh()` (e.g., 0.3 s) after `ACTIONBAR_SLOT_CHANGED` so the lookup runs after the transient window closes

## Acceptance Criteria (Epic-Level)

- [ ] Keybind text visible immediately when a target is acquired after shapeshifting, before combat
- [ ] No regression for classes that do not shapeshift
- [ ] `KEYBIND` DLog tag emitted on lookup success and cache-miss for observability
- [ ] Deferred Refresh does not fire in combat (poll loop already handles that path)

## Forbidden APIs

- Do NOT add `C_CooldownViewer` calls (ADR-6 — permanent ban, causes combat taint)
