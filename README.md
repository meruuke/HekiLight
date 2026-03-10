# HekiLight

A lightweight WoW addon (Midnight 12.0+) that reads Blizzard's built-in **Single-Button Rotation Assistant (SBA)** and displays its suggestions as a **movable, skinnable icon strip** — inspired by Hekili.

## Why?

Hekili ended with the Midnight pre-patch because Blizzard removed the APIs needed for APL-based spell simulation. However, Blizzard's own SBA now handles rotation logic internally, and exposes just enough API for an addon to **read and re-display** that suggestion queue with a better UI.

## Features

- 🎯 Shows up to **N spell icons** from the SBA rotation queue (default: 3, configurable 1–5)
- 🥇 First icon is always the **currently highlighted suggestion** (the spell to cast right now)
- ⌨️ Displays the keybind for the primary spell (like Hekili did)
- ⏱️ Cooldown spiral overlay on the primary icon
- 🔴 Pulsing out-of-range tint when the suggested spell can't reach your target
- ✨ Proc-glow border pulse (gold) when the suggested spell has an active proc
- 📐 Movable and scalable — drag to reposition when unlocked
- 💾 Position and settings persist across sessions via `SavedVariables`
- 🗺️ Draggable minimap button — click to open the settings panel
- ⚙️ In-game settings panel (Interface → AddOns → HekiLight)
- 🔕 Automatically hidden in configurable situations: dead, during a cinematic, or no hostile target — each toggleable in Settings or via `/hkl`

## Limitations

- **Blizzard controls the logic** — spell selection is determined by Blizzard's internal rotation engine, not a community APL.

## Installation

1. Copy the `HekiLight` folder to `World of Warcraft/_retail_/Interface/AddOns/`
2. Enable the addon in the character select screen
3. Enable Blizzard's rotation assistant in **Interface → Combat → Rotation Assistant**

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
| `/hkl debug` | Toggle verbose debug output |
| `/hkl status` | Print SBA state and active suppression reason |

## Key APIs Used

These are official Blizzard APIs introduced in Midnight 12.0:

```lua
C_AssistedCombat.GetNextCastSpell(false)         -- primary spell suggestion (highlighted)
C_AssistedCombat.GetRotationSpells()             -- full rotation spell queue
C_ActionBar.HasAssistedCombatActionButtons()     -- is SBA active?
C_ActionBar.FindAssistedCombatActionButtons()    -- action slot IDs the SBA is using
C_ActionBar.IsAssistedCombatAction(slotID)       -- verify a slot is an SBA slot
C_ActionBar.FindSpellActionButtons(spellID)      -- real bar slots for a spell
C_ActionBar.IsActionInRange(slotID)              -- range check
C_Spell.GetSpellInfo(spellID)                    -- icon ID, spell name
C_Spell.GetSpellCooldown(spellID)                -- cooldown info
C_SpellActivationOverlay.IsSpellOverlayed(spellID) -- proc glow active?
```
