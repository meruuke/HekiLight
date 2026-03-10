## What is HekiLight?

HekiLight is a lightweight World of Warcraft addon for **Midnight (12.0+)** that reads Blizzard's built-in **Rotation Assistant** and re-displays its spell suggestions as a **movable, scalable icon strip** — giving you the familiar Hekili-style overlay, powered entirely by Blizzard's own engine.

Enable it in **Interface → Combat → Rotation Assistant**, then let HekiLight show you what to cast and when.

---

## Features

- 🎯 Shows up to **5 spell icons** from the rotation queue (default: 3, configurable)
- 🥇 First icon is always the **currently highlighted suggestion** — the spell to cast right now
- 🚫 Secondary slots automatically hide spells that are on cooldown
- 🙈 **Ignore list** — permanently hide specific spells from the secondary slots via the settings panel or `/hkl ignore`
- ⌨️ Displays the **keybind** for the primary spell (just like Hekili did)
- ⏱️ **Cooldown spiral** overlay on the primary icon
- 🔴 **Pulsing out-of-range tint** when the suggested spell can't reach your target
- ✨ **Proc-glow border** — pulses gold when the suggested spell has an active proc
- 📐 **Movable and scalable** — drag to reposition when unlocked
- 💾 Position and all settings **persist across sessions**
- 🗺️ **Draggable minimap button** — click to open the settings panel
- ⚙️ Full **in-game settings panel** (Interface → AddOns → HekiLight):
  - **HekiLight** — Appearance, Display, Minimap, Hide/Show conditions
  - **Ignored Spells** — manage your ignore list with a dropdown, Add, and Remove controls

---

## Installation

1. Download and unzip — you should get a `HekiLight` folder
2. Copy `HekiLight` into `World of Warcraft/_retail_/Interface/AddOns/`
3. Enable the addon at the character select screen
4. In-game, enable **Interface → Combat → Rotation Assistant**
5. Enter combat — the icon strip appears automatically

---

## Slash Commands

| Command | Description |
|---|---|
| `/hkl` | Show help |
| `/hkl lock` / `/hkl unlock` | Lock or unlock the display position |
| `/hkl reset` | Reset position to default |
| `/hkl scale <0.2–3.0>` | Set display scale |
| `/hkl size <16–256>` | Set icon size in pixels |
| `/hkl suggestions <1–5>` | Set number of icon slots |
| `/hkl spacing <0–32>` | Set pixel gap between icons |
| `/hkl poll <seconds>` | Set combat poll rate (default `0.05`) |
| `/hkl keybind on\|off` | Toggle keybind text |
| `/hkl range on\|off` | Toggle out-of-range tint |
| `/hkl procglow on\|off` | Toggle proc glow |
| `/hkl sounds on\|off` | Toggle combat-entry sound |
| `/hkl minimap on\|off` | Toggle minimap button |
| `/hkl hide dead on\|off` | Toggle hide when dead |
| `/hkl hide cinematic on\|off` | Toggle hide during cinematics |
| `/hkl show combat on\|off` | Toggle show when in combat |
| `/hkl show target on\|off` | Toggle show when target is attackable |
| `/hkl ignore <spellID>` | Hide a spell from secondary slots |
| `/hkl unignore <spellID>` | Restore a spell |
| `/hkl ignorelist` | List all ignored spells |
| `/hkl status` | Print Rotation Assistant state |
| `/hkl debug` | Toggle debug output |

---

## Limitations

- **Blizzard controls the rotation logic.** Spell selection is determined by Blizzard's internal engine — HekiLight only reads and displays it. You cannot customise the APL or rotation order.
- Requires Blizzard's Rotation Assistant to be enabled in Interface options.

---

## Credits

HekiLight was inspired by [**Hekili**](https://www.curseforge.com/wow/addons/hekili) — the beloved priority helper that guided countless players through their rotations. Hekili stopped working after the Midnight pre-patch removed the APIs it relied on for APL-based spell simulation.

**HekiLight shares no code with Hekili.** It is a new addon built from scratch on top of Blizzard's own `C_AssistedCombat` API, introduced in Midnight 12.0.

Thank you to the Hekili team for years of excellent work. This addon exists because of the gap they left.

---

## Bugs & Feedback

Please report issues and suggestions on the [GitHub Issues page](https://github.com/mauro-pinheiro/HekiLight/issues).
