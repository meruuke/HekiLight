# EPIC-10: Keybind Override

**Status:** Done
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
| 10.1 | Per-Spell Keybind Slot Override (Slash Command) | Done |
| 10.2 | Keybind Override: Extend Ignored Spells Settings Section | Done (UI superseded by 10.3; data layer remains) |
| 10.3 | Keybind Override — Standalone Settings Section | Done |

---

## Option C — Future Upgrade Path (Smart Slot Priority)

Once Option A ships, a future story (appended to EPIC-10 or a new epic) can introduce a heuristic:

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

### ADR-10-3 — Dedicated "Keybind Overrides" standalone section (supersedes original)

**Decision:** Story 10.3 replaced the Story 10.2 approach. The keybind override UI lives in its own top-level `MakeSection(L["Keybind Overrides"])` collapsed section, appended after "Ignored Spells" in `BuildSettingsPanel`. It has its own spell dropdown (`kbSpellDD`), slot picker (`kbSlotDD`), pin button, and override row list. The Story 10.2 additions to `ignoreSec` were removed.

**Rationale:** In-game validation showed the feature was invisible when embedded in "Ignored Spells" — players had no reason to expand that section to find a keybind override tool. Discoverability requires its own entry point at the same level as every other HekiLight preference.

**Consequence:** `ignoreSec` reverts to its pre-10.2 simplicity. The two features (ignore list and keybind overrides) are now independent — selecting a spell in one section does not affect the other.

### ADR-10-2 — `dbChar`, not `db`

**Decision:** Overrides live in `HekiLightDBChar` (per-character).

**Rationale:** Action bar layouts and keybinds are per-character in WoW. A priest and a warrior sharing the same account have completely different bar configurations.

---

## Out of Scope

- Changing the rotation suggestion logic in any way
- Reading or writing RA slots
- A "best keybind" algorithm that ranks by slot position (deferred to Option C / future epic)
- Right-click context menus on the in-combat display frame (taint risk)
