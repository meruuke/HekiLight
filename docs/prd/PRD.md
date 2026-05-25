# Product Requirements Document — HekiLight

**Version:** 1.0 (retroactive, covering v0.0.1 → v0.3.2)
**Date:** 2026-04-19
**Author:** HekiLight Development
**Status:** Active

---

## 1. Product Overview

### 1.1 Problem Statement

World of Warcraft's built-in **Rotation Assistant (RA)** suggests the next spell to cast, but its display is locked to the action bar — it cannot be repositioned, resized, or styled. Players who use custom UI layouts (ElvUI, Bartender, 4K-scaled HUDs) often cannot see the RA button clearly, or cannot place it where their eyes naturally rest during combat.

Additionally, the RA button shows only the immediate next spell. No planning horizon exists for players who think several GCDs ahead.

### 1.2 Solution

**HekiLight** is a lightweight WoW addon for Midnight (Patch 12.0+) that reads Blizzard's Rotation Assistant output and re-displays it as a **movable, resizable, skinnable floating icon overlay**. It extends the single-icon RA display into a configurable **multi-slot suggestion strip** with keybind labels, proc-glow feedback, cooldown greying, and a dedicated proc-alert icon.

### 1.3 Non-Goals

- HekiLight does **not** compute its own rotation priority logic. It is a display layer on top of Blizzard's RA engine, not a rotation addon.
- HekiLight does **not** replace Hekili, WeakAuras, or TellMeWhen for users who want custom rotation logic.
- HekiLight does **not** modify, write to, or parent frames to any Blizzard-protected action bar frame.

---

## 2. User Personas

### 2.1 The Custom UI Player (Primary)

> "I rebuilt my entire UI from scratch. The RA button is buried in my action bar and I can never see it. I just want it somewhere visible, big enough to react to."

- Uses ElvUI, Bartender, or a fully custom layout
- Action bar in a non-standard position (corner, stacked, vertical)
- Wants a large, unmistakable icon overlay at a fixed position near their character
- Does not care about advanced features — just needs the icon visible

### 2.2 The Learning Player (Secondary)

> "I'm still learning Blood DK and I use RA to know what to press. But I also want to see what's coming next so I can get ready."

- Uses RA actively to learn the rotation
- Wants 2–3 upcoming spells visible simultaneously
- Needs keybind labels to connect what they see to what they press
- Needs proc-glow feedback to know when to prioritize a proc over the queue

### 2.3 The Experienced Min-Maxer (Tertiary)

> "I know the rotation cold but I use RA as a sanity check on fight mechanics. I want the overlay small, out of the way, and only visible in combat."

- Configures `showMode = "active"` (only visible in combat with a hostile target)
- Uses a small icon (32–64px)
- Relies on proc-alert as a secondary urgency signal
- Values zero addon overhead between pulls

---

## 3. Functional Requirements

### FR-1: Spell Suggestion Display

| ID | Requirement |
|----|-------------|
| FR-1.1 | The addon SHALL display the current RA suggestion as a spell icon in a floating, draggable frame |
| FR-1.2 | The icon texture SHALL always match what the player will actually cast (including talent overrides, e.g., Defile over Death and Decay) |
| FR-1.3 | The frame position and size SHALL persist across sessions via SavedVariables |
| FR-1.4 | The frame SHALL be draggable via left-click-drag (when unlocked) |
| FR-1.5 | The frame SHALL support both RA modes: action bar button mode and Assisted Highlight glow mode |

### FR-2: Multi-Slot Suggestion Strip

| ID | Requirement |
|----|-------------|
| FR-2.1 | The addon SHALL display up to 5 upcoming spell suggestions in a horizontal strip |
| FR-2.2 | The number of secondary slots SHALL be configurable from 1 to 5 |
| FR-2.3 | Secondary slots SHALL display spells in rotation queue order from `C_AssistedCombat.GetRotationSpells()` |
| FR-2.4 | Secondary slots SHALL be greyed out when the spell is on a real cooldown (>1500ms base CD) |
| FR-2.5 | The GCD (~1.5s) SHALL NOT trigger greying on secondary slots |
| FR-2.6 | The primary suggestion SHALL be deduplicated from the secondary strip |

### FR-3: Keybind Labels

| ID | Requirement |
|----|-------------|
| FR-3.1 | Each slot SHALL display the keybind for the suggested spell as overlaid text |
| FR-3.2 | Keybind lookup SHALL use a regular action bar slot for the spell (not the RA slot, which is taint-protected) |
| FR-3.3 | Keybind font size, color, outline style, and corner anchor SHALL be individually configurable |
| FR-3.4 | If no keybind is found, the label SHALL be silently hidden (no error, no placeholder text) |

### FR-4: Proc-Glow Feedback

| ID | Requirement |
|----|-------------|
| FR-4.1 | When the primary suggested spell has an active proc glow, the icon border SHALL pulse gold |
| FR-4.2 | When the proc ends, the border SHALL return to its default color |
| FR-4.3 | A dedicated proc-alert icon slot SHALL appear separately from the primary icon when a proc is active |
| FR-4.4 | Proc state SHALL be detected via `SPELL_ACTIVATION_OVERLAY_GLOW_SHOW/HIDE` events |
| FR-4.5 | Proc state on `/reload` SHALL be recovered via `C_SpellActivationOverlay.IsSpellOverlayed()` |

### FR-5: Range Feedback

| ID | Requirement |
|----|-------------|
| FR-5.1 | When the suggested spell is out of range, the icon alpha SHALL reduce (configurable pulse) |
| FR-5.2 | Range check SHALL use `C_ActionBar.IsActionInRange(realSlotID)` — never an RA slot |
| FR-5.3 | Range feedback SHALL be toggleable per user preference |

### FR-6: Visibility Gating

| ID | Requirement |
|----|-------------|
| FR-6.1 | Hard stops SHALL always suppress display: player dead, in vehicle, cinematic active |
| FR-6.2 | Hard stops SHALL be individually toggleable |
| FR-6.3 | Show mode SHALL be configurable: `"always"` (whenever RA has a suggestion) or `"active"` (combat or attackable target) |
| FR-6.4 | An attackable target SHALL override soft suppression conditions |
| FR-6.5 | Being in combat SHALL override soft suppression conditions |

### FR-7: Performance

| ID | Requirement |
|----|-------------|
| FR-7.1 | When RA is inactive, the poll loop (`OnUpdate`) SHALL NOT run (zero CPU overhead) |
| FR-7.2 | The poll loop SHALL stop on `PLAYER_REGEN_ENABLED` (combat end) |
| FR-7.3 | The poll loop SHALL restart immediately on `PLAYER_REGEN_DISABLED` (combat start) |
| FR-7.4 | The suggestion queue SHALL produce zero per-frame Lua table allocations (pre-allocated `queueCache`) |

### FR-8: Ignored Spells

| ID | Requirement |
|----|-------------|
| FR-8.1 | Players SHALL be able to ignore specific spells from the secondary suggestion strip |
| FR-8.2 | Ignored spells SHALL be stored per-character (`HekiLightDBChar`) |
| FR-8.3 | Class-specific maintenance spells SHALL be auto-ignored on first load per character |
| FR-8.4 | The ignored spells list SHALL be manageable from the Settings panel and via slash commands |

### FR-9: Settings & Configuration

| ID | Requirement |
|----|-------------|
| FR-9.1 | All settings SHALL be configurable from Game Menu → Interface → AddOns → HekiLight |
| FR-9.2 | All settings SHALL also be configurable via `/hkl` slash commands without reload |
| FR-9.3 | The settings panel SHALL use collapsible sections, all collapsed by default |
| FR-9.4 | Account-wide settings SHALL persist in `HekiLightDB`; character settings in `HekiLightDBChar` |

### FR-10: Diagnostics & Logging

| ID | Requirement |
|----|-------------|
| FR-10.1 | `DLog(tag, msg)` SHALL write timestamped entries to a persistent ring buffer (500 entries max) |
| FR-10.2 | The ring buffer SHALL survive `/reload` and WoW crashes that flush SavedVariables |
| FR-10.3 | The previous session's log SHALL be preserved at `/reload` in `lastSessionLog` |
| FR-10.4 | `/hkl log [N]` SHALL print the last N entries from the current or previous session |
| FR-10.5 | Every talent override substitution SHALL be logged with the `OVERRIDE` tag |

---

## 4. Non-Functional Requirements

### NFR-1: Taint Safety

> No addon action SHALL cause combat taint that blocks player ability usage.

- All action bar slot APIs (`GetActionInfo`, `IsActionInRange`, `C_Spell.GetSpellCooldown`) MUST be wrapped in `pcall()`
- RA slots MUST NEVER be used as source for range checks or keybind lookups — only `realSlotID` (a regular bar slot for the same spell)
- No addon frame MUST be parented to a Blizzard-protected frame

### NFR-2: Lua 5.1 Compatibility

> All code MUST run on WoW's embedded Lua 5.1 runtime without modification.

- No `//` integer division, `&|~` bitwise operators, `goto`, or `table.unpack`
- Use `math.floor()` for integer division; `bit.band/bor/bxor` for bitwise ops
- String escape patterns use `%` not `\`

### NFR-3: No Build System

> The addon MUST be deployable via `/reload` with no compilation, bundling, or external tooling.

- All logic in `HekiLight.lua` (and `Locale.lua` for translations)
- TOC load order is the only module system available

### NFR-4: Memory Efficiency

> The poll loop runs at 20Hz during combat. Per-frame allocation MUST be minimized.

- `queueCache` pre-allocated at startup; repopulated in-place per tick
- Change-detection guards prevent flooding the session log ring buffer
- `keybindCache` avoids redundant `GetBindingKey` calls across frames

### NFR-5: API Stability

> Every WoW API call MUST be validated with `pcall` or nil-check before use.

- Optional APIs (Edit Mode, `GetNextCastSpell`) degrade silently if unavailable
- Addon MUST load and function correctly even if RA is not configured by the player

---

## 5. Constraints

| Constraint | Detail |
|------------|--------|
| **CON-1** | Target client: World of Warcraft Midnight, Interface 120001+ |
| **CON-2** | No external Lua libraries — WoW provides only the standard Lua 5.1 stdlib plus its own API |
| **CON-3** | No network calls — all data is local to the game session |
| **CON-4** | SavedVariables are the only persistence — flushed on `/reload` and logout |
| **CON-5** | `C_CooldownViewer` is permanently off-limits — causes combat taint (see ADR-6) |
| **CON-6** | RA slots are taint-protected — never read range or keybind data from them |

---

## 6. Epics & Roadmap

| Epic | Title | Status |
|------|-------|--------|
| EPIC-1 | Core Spell Display | Done (v0.0.1–v0.0.6) |
| EPIC-2 | Multi-Suggestion Queue | Done (v0.1.0–v0.1.3) |
| EPIC-3 | Settings, Polish & Customization | Done (v0.1.4–v0.2.1) |
| EPIC-4 | Diagnostics, Proc Alert & Correctness | Done (v0.3.0–v0.3.2) |
| EPIC-5 | Correctness Hardening | Done (v0.4.0) |
| EPIC-6 | Keybind Robustness | In Progress |
| EPIC-7 | Secondary Slot Active-Bar Filtering | Done (v0.6.0) |
| EPIC-8 | Addon Branding & UI Polish | Done (v0.6.1) |
| EPIC-9 | Proc Slot Reliability | Done |
| EPIC-10 | Keybind Override | Done (v0.6.5) |
| EPIC-11 | Codebase Modularization — Settings Extraction | Ready |
| EPIC-12 | ClassCodex Profile-Aware Rotation Integration | Ready |

### In Progress

**EPIC-6 — Keybind Robustness:** Fixes a shapeshift-triggered keybind cache miss. When a player exits a form (e.g., Druid Travel Form) and acquires a target out of combat, keybind text is blank until combat starts. Fix: one-shot deferred `Refresh()` after `ACTIONBAR_SLOT_CHANGED` to re-populate the cache after the transient `FindSpellActionButtons` nil window closes. See `docs/epics/EPIC-6.md`.

---

## 7. Out of Scope (Permanently)

| Feature | Reason |
|---------|--------|
| Defensive floater via `C_CooldownViewer` | Combat taint — permanently reverted (ADR-6) |
| Custom rotation priority engine | Out of scope — HekiLight is a display layer, not a rotation advisor |
| Multi-target / AoE suggestion mode | RA does not expose multi-target queues via a public API |
| Network sync / shared profiles | No network capability in WoW addon Lua |
| Automated test suite | No test runner exists in the WoW Lua environment; `/reload` is the only execution path |

---

## 8. Glossary

| Term | Definition |
|------|-----------|
| **RA** | Rotation Assistant — Blizzard's built-in spell suggestion system |
| **realSlotID** | A regular (non-RA) action bar slot containing the same spell; used for taint-safe range and keybind lookups |
| **Taint** | WoW's security model flag that prevents addon code from accessing or modifying protected UI elements during combat |
| **pcall** | Lua protected call — catches runtime errors so taint violations don't crash the addon |
| **DLog** | Diagnostic log function; writes tagged timestamped entries to `HekiLightDB.sessionLog` |
| **queueCache** | Pre-allocated module-level table repopulated in-place each tick to avoid per-frame Lua GC pressure |
| **keybindCache** | Module-level table caching last-known-good keybind strings by spellID |
| **Override spellID** | The talent-replaced spellID (e.g., Defile `152280`) vs the base spellID (Death and Decay `43265`) returned by `GetNextCastSpell` |
| **Hard stop** | A visibility condition that always suppresses the display regardless of `showMode` (dead, vehicle, cinematic) |
| **Soft condition** | A visibility condition governed by `showMode` (combat, attackable target) |
