# EPIC-7: Secondary Slot Active-Bar Filtering

**Status:** Done
**Version range:** v0.6.0 → current
**Depends on:** EPIC-6 (Done — keybind cache robustness)

## Goal

Filter secondary slot suggestions so that only spells present on the player's currently-active action bars are shown. Spells that live exclusively on a form-specific bar (e.g., Cat Form bar for a Restoration Druid) must not appear in secondary slots when the player is not in that form. Additionally, when the primary suggestion is nil out of combat (RA does not pre-activate for secondary forms), fall back to `GetRotationSpells()` so Cat Form players see suggestions on target acquisition.

## Business Value

Restoration Druids with Wildstalker hero talents use Cat Form for damage. Two problems were found:
1. Secondary slots showed Cat Form spells (Rip, Rake) while in caster/tree form — spells that cannot be cast.
2. When entering Cat Form and selecting a target out of combat, no suggestions appeared until combat started.

Both erode trust in the addon and affect a common Mythic+ and raid build.

## Stories

| ID  | Title                                              | Status    |
|-----|----------------------------------------------------|-----------|
| 7.1 | Filter secondary slots to current-bar spells only  | Done      |
| 7.2 | Cat Form out-of-combat suggestion display          | Done      |

## Key Technical Context

- `GetRotationSpells()` returns the full cross-form rotation queue regardless of current form
- Cat Form bar occupies WoW action bar slots 73–84 — `FindSpellActionButtons` returns those slots even when not in Cat Form, so `rslot == nil` is not a reliable filter
- `IsUsableAction(rslot)` returns `false` for form-restricted spells when the form requirement is unmet — this is the correct filter for story 7.1
- `GetNextCastSpell(false)` returns nil for secondary-form spells (Cat Form for Resto) out of combat — RA only pre-activates primary-form suggestions; story 7.2 adds a `GetRotationSpells()` fallback
- `PLAYER_TARGET_CHANGED` is not registered — in Cat Form the action bar state may not change on target acquisition, so `ACTIONBAR_UPDATE_STATE` may not fire reliably; story 7.2 adds this registration

## Acceptance Criteria (Epic-Level)

- [x] Secondary slots never show spells that cannot be cast in the current form
- [x] Resto Druid in Cat Form with a target sees Cat Form suggestions before combat
- [x] No regression for caster-form suggestions
- [x] No regression for non-shapeshifting classes
- [x] SLOT2 diagnostic DLog removed (flood introduced during 7.1 debugging)

## Forbidden APIs

- Do NOT add `C_CooldownViewer` calls (ADR-6 — permanent ban, causes combat taint)
