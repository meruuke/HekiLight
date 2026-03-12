# HekiLight — Copilot Instructions

## What this addon does

HekiLight is a single-file World of Warcraft addon (Lua + TOC) for **Midnight 12.0+** (`## Interface: 120001`). It reads Blizzard's built-in **Rotation Assistant** and re-displays the suggested spell as a movable, skinnable icon overlay — similar to how Hekili used to work.

There is no build system, no package manager, no test suite, and no linter. "Running" the addon means loading it inside WoW.

## Architecture

Everything lives in `HekiLight.lua`. The file is structured in clearly labelled sections separated by `-- ── Section Name ───` banner comments.

### Startup flow

```
ADDON_LOADED → InitDB() → BuildSlots() → BuildMinimapButton() → BuildSettingsPanel() → BuildIgnorePanel()
PLAYER_ENTERING_WORLD → RebuildSlotBindings() → Refresh()
```

### Core loop

The addon uses an **OnUpdate polling loop** rather than a purely event-driven approach, because the Rotation Assistant suggestion can change every frame during combat:

- `StartPollLoop()` — sets `OnUpdate` on the `display` frame; fires `Refresh()` every `db.pollRate` seconds (default 0.05 s).
- `StopPollLoop()` — clears the script; called on combat-end and when Rotation Assistant is inactive.
- `Refresh()` — the central render function: queries the current suggestion, updates the icon texture, keybind text, range overlay, cooldown, and proc-glow, then calls `ShouldShow()` to decide whether to actually show the frame.

### Suggestion detection (two-layer)

`GetActiveSuggestion()` returns `spellID, realSlotID`:

1. **Primary**: `C_AssistedCombat.GetNextCastSpell(false)` — direct engine call; works regardless of whether the Rotation Assistant button is on a bar.
2. **Fallback**: derive spellID via `GetActionInfo` on the Rotation Assistant slot found through `C_ActionBar.FindAssistedCombatActionButtons()` / `IsAssistedCombatAction()`.

`realSlotID` is a **regular** action bar slot for the same spell — needed for `IsActionInRange` and keybind lookup, since Rotation Assistant slots are taint-protected.

### Visibility logic (`ShouldShow`)

Two-tier model — **hard stops** first, then **positive show conditions**:

- Hard stops (`hideWhenDead`, `hideWhenCinematic`) always suppress the icon.
- Show conditions (`showWhenInCombat`, `showWhenAttackableTarget`) are OR-ed; any one being true allows the icon to appear.

### SavedVariables / database pattern

`DEFAULTS` table is the single source of truth for default values. `InitDB()` fills `HekiLightDB` with any missing keys by iterating over `DEFAULTS`. The module-level `db` variable is set to point at `HekiLightDB` after `ADDON_LOADED`.

All runtime settings are read/written through `db.*`.

## Key conventions

- **All state is module-level locals** — no OOP, no namespaces, no global table beyond `HekiLightDB`.
- **Wrap taint-sensitive calls in `pcall()`** — APIs that touch the action bar (cooldown reads, `GetActionInfo`) can taint Blizzard protected frames and must be guarded.
- **`display` frame drives everything** — the root `BackdropTemplate` frame hosts all child widgets (icon, cooldown, range overlay, keybind label). Its `OnUpdate` script is the poll loop.
- **Keybind lookup path**: `spellID → FindSpellActionButtons() → filter out Rotation Assistant slots → SLOT_BINDINGS[slot] → GetBindingKey() → FormatKey()`
- **Slash command pattern**: simple `if/elseif` chains on `strtrim(msg:lower())`. Bulk hide/show toggles are data-driven via `ALWAYS_HIDE_FLAGS` and `SHOW_FLAGS` tables.
- **Settings panels**: two canvas layout categories registered via `Settings.RegisterCanvasLayoutCategory` / `Settings.RegisterCanvasLayoutSubcategory` (10.x+ API).
  - `BuildSettingsPanel()` — main "HekiLight" category; two-column layout (Appearance / Display / Minimap / Hide-Show). Panel height set once from column extent. Registers `settingsCategory` then calls `BuildIgnorePanel(settingsCategory)`.
  - `BuildIgnorePanel(parentCategory)` — "Ignored Spells" sub-category; registered as a child of the main category. Rows parented directly to `subPanel`; `RefreshIgnoreList` calls `subPanel:SetHeight(...)` so the canvas measures the correct scroll extent. Sliders are built manually with `BackdropTemplate` — `OptionsSliderTemplate` is deprecated and not used. Columns are tracked with a simple `cols` table that advances `y` after each widget.
- **Proc-glow**: driven by `SPELL_ACTIVATION_OVERLAY_GLOW_SHOW/HIDE` events and `C_SpellActivationOverlay.IsSpellOverlayed()`; animates the backdrop border from gray → gold using `C_Timer.NewTicker`.
- **Minimap button**: positioned at a configurable angle (degrees) at a fixed 80px radius from `Minimap:GetCenter()`. Drag recalculates angle with `math.atan2`.

## WoW API surface used

```lua
C_AssistedCombat.GetNextCastSpell(false)          -- primary spell suggestion
C_ActionBar.HasAssistedCombatActionButtons()       -- Rotation Assistant button active?
C_ActionBar.FindAssistedCombatActionButtons()      -- Rotation Assistant slot IDs
C_ActionBar.IsAssistedCombatAction(slotID)         -- slot is a Rotation Assistant slot?
C_ActionBar.FindSpellActionButtons(spellID)        -- real bar slots for spell
C_ActionBar.IsActionInRange(slotID)                -- range check
C_Spell.GetSpellInfo(spellID)                      -- icon ID, spell name
C_Spell.GetSpellCooldown(spellID)                  -- cooldown (pcall-guarded)
C_SpellActivationOverlay.IsSpellOverlayed(spellID) -- proc glow active?
IsPlayerSpell(spellID)                             -- guard: skip spells not yet learned (C_AssistedCombat.GetRotationSpells returns all spec spells, learned or not)
Settings.RegisterCanvasLayoutCategory(panel, name)           -- main settings category
Settings.RegisterCanvasLayoutSubcategory(parent, panel, name) -- child category (Ignored Spells)
```
