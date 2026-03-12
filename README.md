# HekiLight

A lightweight WoW addon (Midnight 12.0+) that reads Blizzard's built-in **Rotation Assistant** (`C_AssistedCombat`) and displays its suggestions as a **movable, skinnable icon strip** — inspired by Hekili.

## Why?

Hekili ended with the Midnight pre-patch because Blizzard removed the APIs needed for APL-based spell simulation. However, Blizzard's own Rotation Assistant now handles rotation logic internally, and exposes just enough API for an addon to **read and re-display** that suggestion queue with a better UI.

## Features

- 🎯 Shows up to **N spell icons** from the Rotation Assistant queue (default: 3, configurable 1–5)
- 🥇 First icon is always the **currently highlighted suggestion** (the spell to cast right now)
- 🚫 Secondary slots automatically hide spells that are on cooldown — tracked per-cast, so pre-pull cooldowns are respected too
- 🙈 **Ignore list** — hide specific spells from the secondary list via the dedicated **Ignored Spells** settings sub-panel or `/hkl ignore` (only spells you have actually learned appear in the dropdown)
- ⌨️ Displays the keybind for the primary spell (like Hekili did)
- ⏱️ Cooldown spiral overlay on the primary icon — toggleable via Settings or `/hkl`
- 🔴 Pulsing out-of-range tint when the suggested spell can't reach your target
- ✨ Proc-glow border pulse (gold) when the suggested spell has an active proc
- 📐 Movable and scalable — drag to reposition when unlocked
- 💾 Position and settings persist across sessions via `SavedVariables`
- 🗺️ Draggable minimap button — click to open the settings panel
- ⚙️ In-game settings panel split into two canvas layout categories (Interface → AddOns → HekiLight):
  - **HekiLight** — general options: Appearance, Display, Minimap, Hide/Show conditions
  - **Ignored Spells** (sub-category) — ignore-list management with dropdown, add, and remove controls
- 🔕 Automatically hidden in configurable situations: dead, during a cinematic, or no hostile target — each toggleable in Settings or via `/hkl`

## Limitations

- **Blizzard controls the logic** — spell selection is determined by Blizzard's internal rotation engine, not a community APL.

## Installation

1. Copy the `HekiLight` folder to `World of Warcraft/_retail_/Interface/AddOns/`
2. Enable the addon in the character select screen
3. Enable **Rotation Assistant** in **Interface → Combat**

## Commands

| Command | Description |
|---|---|
| `/hkl` | Show help |
| `/hkl lock` / `/hkl unlock` | Lock or unlock the display position |
| `/hkl reset` | Reset position to default |
| `/hkl scale <0.2–3.0>` | Set display scale |
| `/hkl size <16–256>` | Set icon size in pixels |
| `/hkl suggestions <1–5>` | Set number of icon slots (default `3`) |
| `/hkl spacing <0–32>` | Set pixel gap between icons |
| `/hkl poll <seconds>` | Set combat poll rate (default `0.05`) |
| `/hkl keybind on\|off` | Toggle keybind text |
| `/hkl range on\|off` | Toggle out-of-range red tint |
| `/hkl procglow on\|off` | Toggle proc glow border pulse |
| `/hkl sounds on\|off` | Toggle combat-entry sound |
| `/hkl minimap on\|off` | Toggle minimap button |
| `/hkl hide dead on\|off` | Toggle hide when dead |
| `/hkl hide cinematic on\|off` | Toggle hide during cinematics |
| `/hkl show combat on\|off` | Toggle show when in combat |
| `/hkl show target on\|off` | Toggle show when target is attackable |
| `/hkl ignore <spellID>` | Hide a spell from the secondary list |
| `/hkl unignore <spellID>` | Restore a spell to the secondary list |
| `/hkl ignorelist` | List all currently ignored spells |
| `/hkl debug` | Toggle verbose debug output |
| `/hkl status` | Print Rotation Assistant state and active suppression reason |

## Key APIs Used

These are official Blizzard APIs introduced in Midnight 12.0:

```lua
C_AssistedCombat.GetNextCastSpell(false)         -- primary spell suggestion (highlighted)
C_AssistedCombat.GetRotationSpells()             -- full rotation spell queue
C_ActionBar.HasAssistedCombatActionButtons()     -- Rotation Assistant button active?
C_ActionBar.FindAssistedCombatActionButtons()    -- Rotation Assistant slot IDs
C_ActionBar.IsAssistedCombatAction(slotID)       -- verify a slot belongs to the Rotation Assistant
C_ActionBar.FindSpellActionButtons(spellID)      -- real bar slots for a spell
C_ActionBar.IsActionInRange(slotID)              -- range check
C_Spell.GetSpellInfo(spellID)                    -- icon ID, spell name
C_Spell.GetSpellCooldown(spellID)                -- cooldown info
C_SpellActivationOverlay.IsSpellOverlayed(spellID) -- proc glow active?
IsPlayerSpell(spellID)                           -- filter unlearned spells from GetRotationSpells results
```
