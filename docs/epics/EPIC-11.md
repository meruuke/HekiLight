# EPIC-11: Codebase Modularization — Settings Extraction

**Status:** Ready
**Goal:** Split `HekiLight.lua` into focused files by extracting the Settings Panel into a dedicated `Settings.lua`, reducing the monolith from ~2476 lines to ~1650 lines without changing any runtime behavior.

---

## Motivation

`HekiLight.lua` has grown to ~2476 lines across 13 named sections. All code shares a flat module-level local scope, which is correct for a single-file WoW addon — but it creates friction for story-scoping, code review, and navigation:

- A story that touches only the Settings Panel (e.g., EPIC-10 Story 10.3) still requires reviewers to reason about the entire file.
- Merge conflicts are more likely when multiple stories touch the same file in parallel.
- The Settings Panel (~812 lines, lines 717–1529) is the single largest section and is the most isolated from the hot-path (it runs only at addon startup, never during combat).

The WoW addon runtime has no module system (`require()` does not exist). Splitting files means shared state must be exposed via an addon-global namespace table rather than Lua module closures. This is a well-established WoW pattern.

---

## Architectural Basis

@architect's analysis (2026-05-03) charted the full shared-local dependency graph. Key findings:

- The hot path (`Refresh` → `GetSuggestionQueue` → poll loop → event handlers) is entirely within `HekiLight.lua` and is **not touched by this epic**.
- `BuildSettingsPanel` and `BuildIgnorePanel` read six module-level values at startup: `db`, `dbChar`, `slots`, `display`, `procAlertFrame`, `cachedRotSpells`, and five `Apply*` callback functions plus `Refresh`.
- These can be exposed via a `HekiLightST` (State) addon-global table populated in `InitDB()` — the same pattern WoW addons use for inter-file communication.
- TOC load order: `Locale.lua` → `HekiLight.lua` → `Settings.lua` (Settings reads from `HekiLightST` which `HekiLight.lua` populates at `ADDON_LOADED`).

---

## Existing System Context

- **Stack:** Lua 5.1 (WoW runtime), no build system, no package manager
- **Load order:** Declared in `HekiLight.toc`; files execute top-to-bottom at login/reload
- **Shared state today:** ~25 module-level locals in `HekiLight.lua`; no existing namespace
- **Integration point:** `BuildSettingsPanel()` is called from `events:SetScript("OnEvent", ...)` at `ADDON_LOADED`

---

## Stories

| Story | Title | Status | Executor | Quality Gate |
|-------|-------|--------|----------|--------------|
| 11.1 | Introduce `HekiLightST` shared-state namespace | Ready | `@wow-dev` | `@architect` |
| 11.2 | Extract `Settings.lua` from `HekiLight.lua` | Ready | `@wow-dev` | `@architect` |

---

## Story Summaries

### Story 11.1 — Introduce `HekiLightST` Namespace

```yaml
executor: "@wow-dev"
quality_gate: "@architect"
quality_gate_tools: ["in-game /reload", "/hkl status", "Settings panel open/close cycle"]
```

**What:** Declare `HekiLightST = {}` as an addon global (top of `HekiLight.lua`, before all locals). At the end of `InitDB()`, populate it with references to the shared locals that `Settings.lua` will need:

```lua
HekiLightST = {}  -- declared at top of file, before locals

-- Inside InitDB(), after all locals are assigned:
HekiLightST.db             = db
HekiLightST.dbChar         = dbChar
HekiLightST.display        = display
HekiLightST.slots          = slots
HekiLightST.procAlertFrame = procAlertFrame
HekiLightST.cachedRotSpells = cachedRotSpells
HekiLightST.Refresh        = function() Refresh() end
HekiLightST.ApplySlotLayout      = ApplySlotLayout
HekiLightST.ApplyKeybindStyle    = ApplyKeybindStyle
HekiLightST.ApplyKeybindAnchor   = ApplyKeybindAnchor
HekiLightST.ApplyProcAlertLayout = ApplyProcAlertLayout
HekiLightST.ApplyPosition        = ApplyPosition
HekiLightST.L                   = L
```

**Why now:** Story 11.1 ships and is verified in-game before 11.2 begins. This ensures the namespace is correct before the extraction refactor.

**Scope:** Changes only `HekiLight.lua`. No behavioral change. No new files.

---

### Story 11.2 — Extract `Settings.lua`

```yaml
executor: "@wow-dev"
quality_gate: "@architect"
quality_gate_tools: ["in-game /reload", "Settings panel full cycle", "Ignored Spells add/remove", "Keybind Overrides pin/clear", "all /hkl commands", "DLog inspection"]
```

**What:** Move `BuildSettingsPanel` and `BuildIgnorePanel` (lines 717–1529, ~812 lines) out of `HekiLight.lua` into a new `Settings.lua`. Inside `Settings.lua`, replace all direct references to shared locals with `HekiLightST.*` equivalents. Add `Settings.lua` to `HekiLight.toc` after `HekiLight.lua`.

**Scope:** Two files change — `HekiLight.lua` (section removed) and `HekiLight.toc` (one line added). One new file — `Settings.lua`.

**No behavioral change:** `BuildSettingsPanel()` and `BuildIgnorePanel()` are still called at `ADDON_LOADED` from the event handler in `HekiLight.lua`. The call sites are unchanged.

---

## Compatibility Requirements

- All existing slash commands (`/hkl`) continue to function identically
- `SavedVariables` schema (`HekiLightDB`, `HekiLightDBChar`) is unchanged
- Settings panel behavior is pixel-for-pixel identical after extraction
- No new addon-load-order dependency beyond the TOC declaration

---

## Risk Mitigation

- **Primary Risk:** A shared local referenced in `Settings.lua` is missed during the extraction, causing a `nil` error at addon load.
- **Mitigation:** Story 11.1 ships the complete namespace first. Story 11.2 does a grep pass against all locals used within lines 717–1529 before moving any code.
- **Rollback Plan:** `Settings.lua` can be deleted and its contents pasted back into `HekiLight.lua` without touching `HekiLightST` (the namespace is inert if `Settings.lua` is absent).

---

## Definition of Done

- [ ] `HekiLight.lua` is ≤ ~1670 lines after Story 11.2
- [ ] `Settings.lua` contains `BuildSettingsPanel` and `BuildIgnorePanel` verbatim (logic unchanged)
- [ ] All settings panel features verified in-game: Appearance, Display, Keybind, Ignored Spells, Keybind Overrides
- [ ] All `/hkl` commands verified
- [ ] No Lua errors on `/reload`
- [ ] `HekiLight.toc` updated with `Settings.lua` entry

---

## Out of Scope

- Extracting `Detection.lua` or `Events.lua` (deferred — future epic if needed)
- Changing any settings UI behavior or layout
- The smart-slot-priority heuristic mentioned in EPIC-10 § Option C (unrelated; can be its own story appended to EPIC-10 or a new epic)

---

## Architecture Decisions

### ADR-11-1 — `HekiLightST` as a reference table, not a copy

**Decision:** `HekiLightST` holds references to the same tables/functions that the module-level locals point to (`db`, `slots`, etc.) — not copies.

**Rationale:** `db` and `dbChar` are tables; assigning them to `HekiLightST.db` gives `Settings.lua` a reference to the same table `HekiLight.lua` reads. Writes to `HekiLightST.db.iconSize` are immediately visible to `Refresh()` with no synchronization needed.

**Consequence:** `HekiLightST` must be populated after `InitDB()` runs (i.e., at `ADDON_LOADED`). Accessing it before that point would yield `nil`. Since `Settings.lua` only runs `BuildSettingsPanel` and `BuildIgnorePanel` at `ADDON_LOADED`, this is not a concern.

### ADR-11-2 — TOC load order: `HekiLight.lua` before `Settings.lua`

**Decision:** `HekiLight.lua` is listed before `Settings.lua` in `HekiLight.toc`.

**Rationale:** `Settings.lua` reads `HekiLightST`, which is declared at the top of `HekiLight.lua`. The TOC load order guarantees this declaration exists before `Settings.lua` executes. Reversing the order would cause a `nil global` error at load time.
