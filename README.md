# HekiLight

A lightweight WoW addon (Midnight 12.0+) that reads Blizzard's built-in **Single-Button Rotation Assistant (SBA)** and displays its suggestion as a **movable, skinnable icon overlay** — inspired by Hekili.

## Why?

Hekili ended with the Midnight pre-patch because Blizzard removed the APIs needed for APL-based spell simulation. However, Blizzard's own SBA now handles rotation logic internally, and exposes just enough API for an addon to **read and re-display** that suggestion with a better UI.

## Features

- 🎯 Shows the SBA's current spell recommendation as a floating icon
- ⌨️ Displays the keybind for that spell (like Hekili did)
- ⏱️ Cooldown spiral overlay
- 🔴 Pulsing out-of-range tint when the suggested spell can't reach your target
- 📐 Movable and scalable — drag to reposition when unlocked
- 💾 Position and settings persist across sessions via `SavedVariables`
- 🖼️ Tooltip-style border via `BackdropTemplate`
- 🗺️ Draggable minimap button — click to open the settings panel
- ⚙️ In-game settings panel (Interface → AddOns → HekiLight)
- 🔕 Automatically hidden when dead, mounted, in a vehicle, during a cinematic, resting, or when you have no hostile target

## Limitations

- **Single spell only** — Blizzard's SBA only exposes one suggestion at a time; multi-step look-ahead (like Hekili's queue of 3–6 spells) is not possible with the current API.
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
| `/hkl poll <seconds>` | Set combat poll rate (default `0.05`) |
| `/hkl keybind on\|off` | Toggle keybind text |
| `/hkl range on\|off` | Toggle out-of-range red tint |
| `/hkl sounds on\|off` | Toggle combat-entry sound |
| `/hkl minimap on\|off` | Toggle minimap button |
| `/hkl debug` | Toggle verbose debug output |
| `/hkl status` | Print SBA state and active suppression reason |

## Key APIs Used

These are official Blizzard APIs introduced in Midnight 12.0:

```lua
C_ActionBar.HasAssistedCombatActionButtons()  -- is SBA active?
C_ActionBar.FindAssistedCombatActionButtons() -- action slot IDs the SBA is using
C_ActionBar.IsAssistedCombatAction(slotID)    -- verify a slot is an SBA slot
C_ActionBar.GetActionTexture(slotID)          -- spell icon
C_ActionBar.GetActionCooldown(slotID)         -- cooldown info
C_ActionBar.IsActionInRange(slotID)           -- range check
```
