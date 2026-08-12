# EPIC-1: Core Spell Display

**Status:** Done
**Version range:** v0.0.1 → v0.0.6
**Commits:** `a817b1a` → `bb0a1c7`

## Goal

Build a functional, taint-safe floating icon overlay that re-displays Blizzard's Rotation Assistant suggestion as a movable, configurable frame — covering the full display pipeline: icon, keybind label, range feedback, visibility gating, and proc-glow border.

## Business Value

Blizzard's RA button is embedded in the action bar. It cannot be repositioned, resized, or styled. Players who use a custom UI layout (ElvUI, custom art, 4K scaling) cannot move the RA button to a convenient position and often cannot even see it clearly. HekiLight makes the suggestion visible anywhere on screen, at any size, with any style.

## Stories

| ID | Title | Status |
|----|-------|--------|
| 1.1 | Core Spell Suggestion Display | Done |
| 1.2 | Keybind Lookup Pipeline | Done |
| 1.3 | UI Polish — Backdrop, Minimap, Settings | Done |
| 1.4 | Configurable Visibility Conditions | Done |
| 1.5 | Zero CPU Cost When RA Inactive + Assisted Highlight | Done |
| 1.6 | Proc-Glow Border Pulse | Done |

## Key Technical Decisions

- **ADR-1:** ~~Single-file addon~~ Multi-file addon (Settings.lua extracted in EPIC-11); no build system — deployed via `/reload`. See ADR-11-2 for load-order rules.
- **ADR-2:** OnUpdate polling at 50ms (the only way to catch suggestion changes frame-by-frame)
- **ADR-3:** Two-layer suggestion detection: `GetNextCastSpell` primary, `GetActionInfo` fallback
- **ADR-4:** `realSlotID` pattern — never use RA slots for range/keybind data (taint-protected)
- **ADR-7:** Visibility went through three reversals; settled on two-tier `ShouldShow()` (hard stops + show mode)

## Acceptance Criteria (Epic-Level)

- [x] Icon appears as a movable, resizable frame whenever RA has an active suggestion
- [x] Keybind text overlaid on icon, taint-safe, covers both RA modes
- [x] Out-of-range alpha pulse via `C_ActionBar.IsActionInRange(realSlotID)`
- [x] Proc-glow border pulse driven by `SPELL_ACTIVATION_OVERLAY_GLOW_SHOW/HIDE` events
- [x] Hard visibility stops: dead, vehicle, cinematic — always enforced
- [x] Soft visibility: configurable (always / active-only)
- [x] Zero CPU cost when RA is inactive
- [x] All settings persist via `HekiLightDB` (SavedVariables)

## What Was NOT Built (Reverted)

- Defensive floater via `C_CooldownViewer` — causes combat taint, permanently reverted (see Story 3.3, ADR-6)
