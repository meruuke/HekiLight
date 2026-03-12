# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this addon does

HekiLight is a single-file World of Warcraft addon (Lua + TOC) for **Midnight 12.0+** (`## Interface: 120001`). It reads Blizzard's built-in **Rotation Assistant** and re-displays the suggested spell as a movable, skinnable icon overlay — similar to how Hekili used to work.

There is **no build system, no package manager, no test suite, and no linter**. "Running" the addon means loading it inside WoW. Reload with `/reload` in-game after changing the Lua file.

## Architecture

Everything lives in `HekiLight.lua`. Sections are separated by `-- ── Section Name ───` banner comments.

### Startup flow

```
ADDON_LOADED → InitDB() → BuildSlots() → BuildMinimapButton() → BuildSettingsPanel() → BuildIgnorePanel()
PLAYER_ENTERING_WORLD → RebuildSlotBindings() → Refresh()
```

### Core loop

An **OnUpdate polling loop** (not purely event-driven) because the Rotation Assistant suggestion can change every frame:

- `StartPollLoop()` — sets `OnUpdate` on `display`; fires `Refresh()` every `db.pollRate` seconds (default 0.05 s)
- `StopPollLoop()` — clears the script on combat-end or when Rotation Assistant is inactive
- `Refresh()` — central render: queries suggestion, updates icon texture, keybind text, range overlay, cooldown, proc-glow, calls `ShouldShow()`

### Suggestion detection (two-layer)

`GetActiveSuggestion()` returns `spellID, realSlotID`:

1. **Primary**: `C_AssistedCombat.GetNextCastSpell(false)` — direct engine call
2. **Fallback**: derive spellID via `GetActionInfo` on the Rotation Assistant slot from `C_ActionBar.FindAssistedCombatActionButtons()` / `IsAssistedCombatAction()`

`realSlotID` is a **regular** action bar slot for the same spell — needed for `IsActionInRange` and keybind lookup, since Rotation Assistant slots are taint-protected.

### Visibility logic (`ShouldShow`)

Two-tier: **hard stops** first (always suppress), then **positive show conditions** (OR-ed, any one allows display).

### SavedVariables / database pattern

`DEFAULTS` is the single source of truth. `InitDB()` fills `HekiLightDB` with missing keys. Module-level `db` points to `HekiLightDB` after `ADDON_LOADED`. All runtime settings use `db.*`.

## Key conventions

- **All state is module-level locals** — no OOP, no namespaces, no global table beyond `HekiLightDB`
- **Wrap taint-sensitive calls in `pcall()`** — APIs touching the action bar (cooldown reads, `GetActionInfo`) can taint Blizzard protected frames
- **`display` frame drives everything** — root `BackdropTemplate` frame hosts all child widgets; its `OnUpdate` is the poll loop
- **Keybind lookup**: `spellID → FindSpellActionButtons() → filter Rotation Assistant slots → SLOT_BINDINGS[slot] → GetBindingKey() → FormatKey()`
- **Slash commands**: `if/elseif` chains on `strtrim(msg:lower())`; bulk toggles are data-driven via `ALWAYS_HIDE_FLAGS` / `SHOW_FLAGS` tables
- **Settings panels**: two canvas layout categories via `Settings.RegisterCanvasLayoutCategory` / `Settings.RegisterCanvasLayoutSubcategory`. `OptionsSliderTemplate` is deprecated — sliders are built manually with `BackdropTemplate`
- **Proc-glow**: driven by `SPELL_ACTIVATION_OVERLAY_GLOW_SHOW/HIDE` events and `C_SpellActivationOverlay.IsSpellOverlayed()`; animates backdrop border gray → gold via `C_Timer.NewTicker`
- **Minimap button**: positioned at a configurable angle (degrees) at 80px radius from `Minimap:GetCenter()`; drag recalculates with `math.atan2`
- **GetSpellBaseCooldown** (not `GetSpellCooldown`) is used to identify real CDs (vs GCD) for greying out secondary icons

## WoW API surface

```lua
C_AssistedCombat.GetNextCastSpell(false)           -- primary spell suggestion
C_AssistedCombat.GetRotationSpells()               -- full rotation queue
C_ActionBar.HasAssistedCombatActionButtons()       -- Rotation Assistant button active?
C_ActionBar.FindAssistedCombatActionButtons()      -- Rotation Assistant slot IDs
C_ActionBar.IsAssistedCombatAction(slotID)         -- slot is a Rotation Assistant slot?
C_ActionBar.FindSpellActionButtons(spellID)        -- real bar slots for spell
C_ActionBar.IsActionInRange(slotID)                -- range check
C_Spell.GetSpellInfo(spellID)                      -- icon ID, spell name
C_Spell.GetSpellCooldown(spellID)                  -- cooldown (pcall-guarded)
C_SpellActivationOverlay.IsSpellOverlayed(spellID) -- proc glow active?
IsPlayerSpell(spellID)                             -- filter unlearned spells
Settings.RegisterCanvasLayoutCategory(panel, name)
Settings.RegisterCanvasLayoutSubcategory(parent, panel, name)
```
