# EPIC-9: Proc Slot Reliability

**Status:** InProgress
**Goal:** Ensure the proc alert slot only shows spells that are actually on the player's action bar, eliminating phantom-spell appearances on specs like Marksman Hunter.

## Motivation

`UpdateProcAlert` selects candidates from `activeOverlaySpells` (GLOW_SHOW events) and `GetRotationSpells()`. Neither source requires the spell to have an action bar slot. On Marksman Hunter (and potentially other specs) the rotation engine emits overlay events for talent or passive spells that are never slotted by the player. This causes the proc icon to display an unrecognizable spell with no keybind, which is confusing and not actionable.

The keybind gate (`GetSpellKeybind(spellID) != ""`) is the correct proxy for "spell is on the bar and is actionable". If a spell has no keybind, the player cannot act on the alert — so the proc slot should remain hidden.

## Stories

| Story | Title | Status |
|-------|-------|--------|
| 9.1 | Proc Slot: Require Keybind Before Showing | Ready for Review |
| 9.2 | Proc Slot: Hide When Spell Is On Cooldown | Ready |

## Out of Scope

- Changes to the primary suggestion slot filtering logic
- Changes to keybind display settings (showKeybind toggle)
- New UI for "ignored proc spells"
