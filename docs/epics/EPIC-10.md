# EPIC-10: Keybind Override

**Status:** Draft
**Goal:** Allow players to pin a preferred action bar slot (and therefore a specific keybind) for any spell that appears on multiple bars, and provide a clear upgrade path to a smart slot-priority heuristic.

---

## Motivation

`GetSpellKeybind(spellID)` calls `C_ActionBar.FindSpellActionButtons(spellID)`, which returns every bar slot containing the spell. The implementation picks the **first non-RA slot** from that list — deterministic but not user-controlled. Players who bind the same spell on multiple bars (a common pattern: same ability on both the primary bar and a class-specific bar) consistently see the keybind for whichever slot the API returns first, which is often not the one they visually associate with that spell.

This is a display correctness issue, not a rotation correctness issue, but it erodes trust in the keybind label feature and creates confusion during fast-paced combat.

---

## Problem in Code

`HekiLight.lua` — `GetSpellKeybind` (line ~264):

```lua
local actionSlots = C_ActionBar.FindSpellActionButtons(spellID)
if actionSlots then
    for _, slot in ipairs(actionSlots) do
        if not C_ActionBar.IsAssistedCombatAction(slot) then
            local key = GetSlotKeybind(slot)
            if key ~= "" then
                keybindCache[spellID] = key  -- returns on first hit
                ...
```

No way exists today for a player to influence which slot wins.

---

## Stories

| Story | Title | Status |
|-------|-------|--------|
| 10.1 | Per-Spell Keybind Slot Override (Slash Command) | Draft |
| 10.2 | Keybind Override: Extend Ignored Spells Settings Section | Draft |

---

## Option C — Future Upgrade Path (Smart Slot Priority)

Once Option A ships, EPIC-11 (or a story appended here) can introduce a heuristic:

> When multiple bar slots contain the same spell and **no manual override exists**, prefer the slot whose action bar page is currently visible/active.

Implementation sketch:
- After `FindSpellActionButtons`, filter to slots on the currently active page (`GetActionBarPage()` → slots `(page-1)*12+1` to `page*12`)
- If exactly one slot remains after filtering → use it (no override needed)
- If still ambiguous → fall through to current first-hit behaviour
- Manual override (Option A) always wins regardless

This is deliberately **not** in this EPIC — it should be validated against real player feedback from Option A first.

---

## Architecture Decisions

### ADR-10-1 — Store preferred `slotID`, not the key string

**Decision:** `dbChar.keybindOverrides[spellID] = slotID` (integer).

**Rationale:** Storing the slot ID lets `GetSlotKeybind(slotID)` resolve the live binding key at render time. If the player later rebinds that slot, the display updates automatically. Storing a static key string would go stale silently.

**Consequence:** If the player removes the spell from the pinned slot, the override becomes a graceful no-op — `GetSpellKeybind` falls through to the normal multi-slot scan.

### ADR-10-3 — Extend the existing Ignored Spells section; do not register a new subpanel

**Decision:** Story 10.2 modifies the inline `ignoreSec` block inside `BuildSettingsPanel`, adding a second dropdown (slot picker) and a "Pin keybind" button alongside the existing "Add to ignore list" button. A separate keybind-overrides row list is appended within the same collapsed section.

**Rationale:** The Ignored Spells section already has a spell-selection dropdown that is populated live from `C_AssistedCombat.GetRotationSpells()` — exactly the right source for the keybind problem (only spells currently in the rotation are candidates). Building a second subpanel would duplicate that infrastructure and split per-spell preferences across two Settings pages. One section for all per-spell settings is a better UX.

**Consequence:** `BuildSettingsPanel` grows slightly. The two-step flow shares `selectedIgnoreSpellID` state — selecting a spell activates both the existing ignore button and the new slot picker controls simultaneously.

### ADR-10-2 — `dbChar`, not `db`

**Decision:** Overrides live in `HekiLightDBChar` (per-character).

**Rationale:** Action bar layouts and keybinds are per-character in WoW. A priest and a warrior sharing the same account have completely different bar configurations.

---

## Out of Scope

- Changing the rotation suggestion logic in any way
- Reading or writing RA slots
- A "best keybind" algorithm that ranks by slot position (deferred to Option C / future epic)
- Right-click context menus on the in-combat display frame (taint risk)
