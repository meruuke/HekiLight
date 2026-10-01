# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this addon does

HekiLight is a World of Warcraft addon (Lua + TOC) for **Midnight 12.0+** (`## Interface: 120005`). It reads Blizzard's built-in **Rotation Assistant** and re-displays the suggested spell as a movable, skinnable icon overlay.

There is **no build system, no package manager, no test suite, and no linter**. "Running" the addon means loading it inside WoW. Reload with `/reload` in-game after changing any Lua file.

## File structure

```
HekiLight.toc   — load order: Locale.lua → HekiLight.lua → Settings.lua
Locale.lua      — HekiLightLocale global; identity-fallback metatable; ptBR block
HekiLight.lua   — core logic; ~2083 lines, sectioned by banner comments
Settings.lua    — BuildSettingsPanel() extracted from HekiLight.lua (EPIC-11)
```

Sections in `HekiLight.lua` (in order):

| Section | Contents |
|---|---|
| Defaults / State | `DEFAULTS`, module-level locals, `db`/`dbChar` forward declarations |
| Helpers | `InitDB`, `RebuildSlotBindings`, `FormatKey`, `GetSpellKeybind` |
| Visibility Gate | `ShouldShow()` — hard stops then positive conditions |
| UI Construction | `BuildSlots`, `BuildMinimapButton` |
| Settings Panel | Stub comment only — `BuildSettingsPanel` lives in `Settings.lua` |
| Spell Suggestion Detection | `GetActiveSuggestion`, `GetRealSlot`, `GetSuggestionQueue` |
| Core Update Logic | `Refresh`, `UpdateProcAlert`, glow pulse functions |
| Combat Polling | `StartPollLoop`, `StopPollLoop`, `IsAssistActive` |
| Edit Mode | `EditModeRender`, drag/unlock helpers |
| Event Handling | single `events` frame, `OnEvent` dispatch |
| Slash Commands | `/hkl` handler — `if/elseif` chain on `strtrim(msg:lower())` |

## Startup flow

```
ADDON_LOADED  → InitDB() → BuildSlots() → BuildMinimapButton()
              → populate HekiLightST → BuildSettingsPanel()
PLAYER_ENTERING_WORLD → RebuildSlotBindings() → IsAssistActive() → StartPollLoop() → Refresh()
```

## HekiLightST — shared-state namespace

`HekiLightST` is a global table (`{}` at file top of `HekiLight.lua`) that bridges module-level locals into `Settings.lua`. It is populated inside the `ADDON_LOADED` handler, after `InitDB()` and `BuildSlots()` complete and before `BuildSettingsPanel()` is called.

**Current keys (21):** `db`, `dbChar`, `display`, `slots`, `procAlertFrame`, `cachedRotSpells`, `Refresh`, `ApplySlotLayout`, `ApplyKeybindStyle`, `ApplyKeybindAnchor`, `ApplyProcAlertLayout`, `ApplyPosition`, `L`, `DEFAULTS`, `MAX_SLOTS`, `isEditMode` (getter fn), `EditModeRender`, `setSettingsCategory` (setter fn), `GetSlotKeybind`, `SetMinimapShown`, `StopGlowPulse`.

`Settings.lua` consumes these via local aliases at the top of `BuildSettingsPanel()`:
```lua
local db = HekiLightST.db   -- same table as HekiLightDB; mutations persist
local L  = HekiLightST.L
-- etc.
```

**When adding a new module-local that `Settings.lua` needs:** add it to the `HekiLightST` population block in the `ADDON_LOADED` handler (~line 1487). For mutable state, expose a getter/setter function rather than a raw value copy.

**Cross-chunk visibility rule:** Functions defined in `Settings.lua` that are called from `HekiLight.lua` **must be globals** (no `local`). WoW Lua files are separate chunks sharing `_G`; a `local function` in `Settings.lua` is invisible to `HekiLight.lua`'s event handlers.

## Core polling loop

`StartPollLoop()` sets an `OnUpdate` script on `display` that fires `Refresh()` every `db.pollRate` seconds (default 0.05 s). `StopPollLoop()` clears it. The loop runs only when Rotation Assistant is active and the player is in combat (or `showMode == "always"`).

`IsAssistActive()` — gates loop start: returns true if `HasAssistedCombatActionButtons()` OR `GetCVarBool("assistedCombatHighlight")`.

## Suggestion detection (`GetActiveSuggestion`)

Returns `spellID, realSlotID`:

1. **Primary**: `C_AssistedCombat.GetNextCastSpell(false)` — direct engine call, pcall-guarded
2. **Fallback**: `FindAssistedCombatActionButtons()` → `GetActionInfo(slot)` — for edge cases where primary returns nil

`realSlotID` is a **regular** action bar slot for the same spell (not an RA slot) — needed for `IsActionInRange` and keybind lookup because RA slots are taint-protected.

`resolveSecondary(sid)` wraps `GetRealSlot(sid)` and then reads `GetActionInfo(rslot)` (pcall-guarded) to resolve talent overrides — e.g. base Death and Decay resolves to Defile's spellID when talented. Returns `rslot, effectiveID`. Used by `GetSuggestionQueue` for all secondary slots so dedup and icon display are override-aware.

`GetSuggestionQueue(n)` builds up to `n` entries using `GetActiveSuggestion()` for slot 1, then `C_AssistedCombat.GetRotationSpells()` for slots 2–n. Two-pass: off-cooldown spells fill first, then on-CD spells (displayed greyed out). Both passes guard with `rslot and IsUsableAction(rslot)` to exclude form-restricted spells (e.g. Cat Form spells when not in Cat Form). A session-level copy of the queue is kept in `cachedRotSpells` for the Ignored Spells dropdown.

## SavedVariables pattern

- `DEFAULTS` — single source of truth for all settings
- `InitDB()` — fills `HekiLightDB` with missing keys only (never overwrites existing)
- `db` — module-level local pointing to `HekiLightDB` after `ADDON_LOADED`
- `dbChar` — points to `HekiLightDBChar` (per-character: `ignoredSpells`, `classDefaultsApplied`, `keybindOverrides`)
- `HekiLightDB.sessionLog` — ring buffer (max 500 entries) of `DLog()` events; survives until next `/reload`; previous session saved to `lastSessionLog`

## Key conventions

- **All state is module-level locals** — no OOP, no namespaces, no global table beyond `HekiLightDB` / `HekiLightDBChar` / `HekiLightST`
- **Taint-sensitive calls always in `pcall()`** — `GetActionInfo`, `C_Spell.GetSpellCooldown`, `C_AssistedCombat.*`, and anything touching action bar slots
- **`display` frame drives everything** — root `BackdropTemplate` frame; its `OnUpdate` is the poll loop; all child widgets are parented to it or to `procAlertFrame`
- **Pre-allocated queue** — `queueCache` and `queueCount` are module-level; `GetSuggestionQueue` wipes and repopulates in-place to avoid per-frame table allocation
- **Keybind lookup chain**: `spellID → FindSpellActionButtons() → filter RA slots → SLOT_BINDINGS[slot] → GetBindingKey() → FormatKey()`; last known good value cached in `keybindCache[spellID]`
- **`GetSpellBaseCooldown`** (not `GetSpellCooldown`) identifies real CDs (>1500 ms) vs GCD for the secondary-slot grey filter
- **Settings panels**: `Settings.RegisterCanvasLayoutCategory` / `RegisterCanvasLayoutSubcategory`; sliders built manually with `BackdropTemplate` (`OptionsSliderTemplate` is deprecated in 12.0)
- **Proc-glow**: tracked via `SPELL_ACTIVATION_OVERLAY_GLOW_SHOW/HIDE` events into `activeOverlaySpells`; also cross-checked with `C_SpellActivationOverlay.IsSpellOverlayed()` at render time to catch procs already active on `/reload`
- **Proc-glow rendering**: shared `ShowGlow(frame)`/`HideGlow(frame)` over a native overlay (`EnsureNativeAlert`, pcall-guarded, cached `frame.hklAlert`, sized `ALERT_SCALE = 1.4×` the icon, CENTER-anchored, `OnSizeChanged` hook for live `iconSize`). Prefers the **modern `ActionButtonSpellAlertTemplate`** (`overlay.hklKind = "flipbook"`) and plays its looping `ProcLoop` FlipBook for the travelling-wisp glow Blizzard's Cooldown Manager uses; falls back to the classic `ActionBarButtonSpellActivationAlert` (`animIn`/`animOut`, scale-in only), then to a self-drawn `UI-ActionButton-Border` `AnimationGroup` glow (`frame.hklGlow`). `frame.hklGlowMode` (`"native"`/`"fallback"`) tells `HideGlow` which to tear down. `db.showProcGlow` is the master on/off for the glow on **either** slot: `UpdateGlowState` gates the primary glow (`db.showProcGlow and not db.showProcAlert`), and `UpdateProcAlert` gates the proc-alert glow on `db.showProcGlow` (the proc-alert *icon* still shows — `showProcAlert` controls the icon, `showProcGlow` the glow). Routed per design: the glow lives on the **proc-alert slot when `showProcAlert` is enabled**, otherwise on the **primary slot**
- **Out-of-range**: `ApplyIconTint(slot, i, entry)` desaturates and red-tints (`SetVertexColor(1, 0.30, 0.30)`) the icon when `IsActionInRange(entry.realSlotID) == false`, combined with the on-cooldown desaturation. Applied to **every slot** in the render loop (not just the primary), so the whole strip fades to red like Blizzard's Cooldown Manager
- **Minimap button**: 80 px radius from `Minimap:GetCenter()` at `db.minimapAngle` degrees; drag recalculates angle with `math.atan2`
- **Locale**: `local L = HekiLightLocale`; identity-fallback metatable means untranslated keys return themselves (English). Add new strings as `L["key"] = "value"` in the language block inside `Locale.lua`.

## Slash commands reference

`/hkl` (or `/hekilight`):

| Command | Effect |
|---|---|
| `lock` / `unlock` | Toggle drag on main display |
| `scale <0.2–3.0>` | Overall scale |
| `size <16–256>` | Icon pixel size |
| `suggestions <1–5>` | Number of icon slots |
| `spacing <0–32>` | Pixel gap between slots |
| `poll <0.016–1.0>` | Refresh rate in seconds |
| `keybind` | Toggle keybind text |
| `range` | Toggle out-of-range tint |
| `proc` | Toggle proc-glow border |
| `procalert` | Toggle proc-alert icon |
| `procalert lock` / `unlock` | Anchor proc slot to main display or free it |
| `show always\|active` | Visibility mode |
| `hide dead\|vehicle\|cinematic on\|off` | Hard-stop toggles |
| `minimap on\|off` | Minimap button |
| `kbsize <8–24>` | Keybind font size |
| `kbcolor <r> <g> <b>` | Keybind color (0–1 each) |
| `kboutline outline\|thick\|none` | Keybind outline style |
| `kbanchor bottomright\|bottomleft\|topright\|topleft\|center` | Keybind corner |
| `ignore <spellID>` / `unignore <spellID>` | Per-character secondary-list filter |
| `ignorelist` | Print currently ignored spells |
| `kb slots <spellID>` | List all non-RA bar slots and keybinds for a spell |
| `kb pin <spellID> <slot>` | Pin a bar slot as the keybind source for a spell |
| `kb clear <spellID>` | Remove a keybind slot override |
| `kb list` | Print all current keybind overrides |
| `edit` | Toggle Edit Mode (drag to reposition both frames) |
| `status` | Print detection mode, current suggestion, display state |
| `debug` | Toggle verbose `Log()` output to chat |
| `log [N]` | Print last N (default 30) `DLog` events from session log |
| `reset` | Reset all settings to `DEFAULTS` |

## Logging system

Two levels:

- `Log(...)` — debug-only (`DEBUG = true` via `/hkl debug`); prints to chat immediately
- `DLog(tag, msg)` — always active; writes timestamped entries to `HekiLightDB.sessionLog`; read with `/hkl log [N]`

`DLog` tags in use: `SUGGEST`, `SLOT`, `RAW_SUGG`, `SUPPRESS`, `ALERT_SHOW`, `ALERT_HIDE`, `ALERT_GLOW`, `OVERRIDE`, `KEYBIND`

`OVERRIDE` fires every time a talent-override substitution occurs (e.g., base Death and Decay → Defile). Change-detection guards (`lastLogSuggID`, `lastSlotSpellID`, `lastSkippedAlertID`) prevent high-frequency events from flooding the 500-entry buffer.

## Project documentation

`docs/` contains the product artifacts for this addon:

```
docs/prd/PRD.md          — full product requirements (FRs, NFRs, constraints, roadmap)
docs/epics/EPIC-{n}.md   — per-epic goals, stories, ADRs, and acceptance criteria
docs/stories/{n}.{m}.story.md — individual story files with AC and implementation notes
```

EPICs 1–11 are **Done** (EPIC-11 = Settings extraction; `BuildSettingsPanel` now in `Settings.lua`).

Do **not** add `C_CooldownViewer` calls — permanently off-limits, causes combat taint (ADR-6).

## WoW API surface

```lua
C_AssistedCombat.GetNextCastSpell(false)           -- primary spell suggestion (pcall)
C_AssistedCombat.GetRotationSpells()               -- full rotation queue (pcall)
C_ActionBar.HasAssistedCombatActionButtons()       -- RA button active?
C_ActionBar.FindAssistedCombatActionButtons()      -- RA slot IDs
C_ActionBar.IsAssistedCombatAction(slotID)         -- is slot a RA slot?
C_ActionBar.FindSpellActionButtons(spellID)        -- real bar slots for spell
C_ActionBar.IsActionInRange(slotID)                -- range check (use realSlotID, not RA slot)
C_Spell.GetSpellInfo(spellID)                      -- .iconID, .name
C_Spell.GetSpellCooldown(spellID)                  -- cooldown (pcall)
GetSpellBaseCooldown(spellID)                      -- base CD in ms; >1500 = real CD not GCD
C_SpellActivationOverlay.IsSpellOverlayed(spellID) -- proc glow active?
IsPlayerSpell(spellID)                             -- filter unlearned spells
IsUsableAction(slotID)                             -- false if form/stance requirement unmet; used to filter secondary slots
GetCVarBool("assistedCombatHighlight")             -- Assisted Highlight feature enabled?
Settings.RegisterCanvasLayoutCategory(panel, name)
Settings.RegisterCanvasLayoutSubcategory(parent, panel, name)
```
