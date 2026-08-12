# EPIC-12: ClassCodex Profile-Aware Rotation Integration

**Status:** Ready
**Goal:** When the ClassCodex addon is installed, allow HekiLight to use ClassCodex's community-curated rotation priority lists — with user-selectable profiles (Single Target, AOE, Opener, etc.) and hero talent variants — as a full alternative to Blizzard's Rotation Assistant.

---

## Motivation

Blizzard's Rotation Assistant (`C_AssistedCombat`) provides real-time spell suggestions, but its priority logic is opaque and may lag behind the current PvE meta. ClassCodex compiles rotation guides from top-tier sources (Archon, Wowhead, Murlok) into structured, per-spec priority lists with named profiles (Single Target, Multitarget, ST Opener, AOE Opener, and more).

Players who maintain ClassCodex already trust those guides. HekiLight can read ClassCodex's global data tables — no bridging API, no event system — and resolve the same priority list into live spell suggestions by checking mechanical castability (cooldown + usability) per slot.

**Value proposition:** Same HekiLight display experience, driven by the community's meta rotation order rather than Blizzard's RA. Both sources remain selectable with a single toggle.

---

## Research Findings (2026-05-24)

- `ClassCodexData[CLASS_TOKEN]` is a global Lua table readable by any addon — no API agreement needed
- Rotation data: `{ heroTalent, context, steps[] }` entries, spellIDs encoded as `{spellID}` within step strings
- Multiple profiles per spec — `context` values include "Single Target", "Multitarget", "ST Opener", "AOE Opener", "Wiggling", etc.
- Hero talent variants tracked per profile (e.g., "Void-Scarred", "Aldrachi Reaver" for Demon Hunter)
- ClassCodex provides no callback for data changes — HekiLight reads state directly each poll cycle
- Reading a plain Lua table has **zero combat taint risk**

Example data shape (Demon Hunter):
```lua
ClassCodexData["DEMONHUNTER"].rotation = {
  {
    heroTalent = "Void-Scarred",
    context    = "Single Target",
    steps = {
      "{1245412} if you are about to enter {1217607}",
      "{1226019} at 74 fury or with a {1238495} proc",
      "{1217607}",
    },
  },
  -- AOE Opener, Multitarget, etc.
}
```

**Outstanding gap:** The exact `ClassCodexData` key format for spec sub-entries (e.g., whether it is `ClassCodexData["DEMONHUNTER"]` flat or `ClassCodexData["DEMONHUNTER"]["havoc"]`) is confirmed at the class level but requires in-game inspection to confirm any sub-key structure. Story 12.1 is the spike that resolves this.

---

## Architectural Basis

The CC resolver runs in two layers, added in sequence across stories:

**Layer 1 — Mechanical castability (Story 12.2):**
1. Walk ClassCodex priority list (spellIDs extracted from step strings in order)
2. For each spellID → `GetRealSlot(spellID)` → `IsUsableAction(slot)` + cooldown check
3. First castable spell = primary suggestion; next N castable spells = queue

**Layer 2 — Tier-1 condition evaluation (Story 12.5):**
After the mechanical check passes, `EvalCCCondition(stepText)` is called on the original step string. It evaluates the subset of conditions that map cleanly to WoW 12.0 APIs (resource thresholds, buff/proc presence, debuff absence). Conditions it cannot parse are treated as `true` so the spell is never incorrectly suppressed. If the condition evaluates to `false`, the resolver advances to the next spell in the priority list.

Research (2026-05-24) confirmed that all required WoW APIs survived the Midnight 12.0 rewrite: `UnitPower`, `Enum.PowerType`, `C_UnitAuras.GetAuraDataBySpellID`, and `GetComboPoints` are all in active use by other installed addons.

---

## Existing System Context

- **Suggestion pipeline:** `GetActiveSuggestion()` → `GetSuggestionQueue(n)` → `Refresh()` → display
- **Slot resolution:** `GetRealSlot(spellID)` already maps spellIDs → action bar slots; reused unchanged
- **Cooldown check:** `C_Spell.GetSpellCooldown` + `GetSpellBaseCooldown` pattern already in `GetSuggestionQueue`; reused
- **Settings panel:** Lives in `HekiLight.lua` (pre-EPIC-11) or `Settings.lua` (post-EPIC-11) — Story 12.3 notes the conditional target
- **SavedVariables:** `DEFAULTS` is the single source of truth; new CC keys are additive

---

## Dependency Note

Stories 12.1 and 12.2 are independent of EPIC-11. Story 12.3 targets `Settings.lua` if EPIC-11 has shipped, or `HekiLight.lua` if not — the implementation note in Story 12.3 calls this out.

---

## Stories

| Story | Title | Status | Executor | Quality Gate |
|-------|-------|--------|----------|--------------|
| 12.1 | ClassCodex Data Reader & Spec Key Spike | Ready | `@wow-dev` | `@qa` |
| 12.2 | CC Rotation Resolver | Ready | `@wow-dev` | `@qa` |
| 12.3 | CC Settings Section | Ready | `@wow-dev` | `@qa` |
| 12.4 | Slash Commands & Polish | Ready | `@wow-dev` | `@qa` |
| 12.5 | Tier-1 Condition Evaluator | Ready | `@wow-dev` | `@qa` |

---

## Story Summaries

### Story 12.1 — ClassCodex Data Reader & Spec Key Spike

```yaml
executor: "@wow-dev"
quality_gate: "@qa"
quality_gate_tools: ["/hkl ccdata", "in-game /reload", "Lua error frame"]
```

**Objective:** Confirm the exact `ClassCodexData` key structure for the current player's spec, parse spellIDs from rotation steps, and expose the resolved priority list via a slash command for in-game validation. This story is a spike — no CC mode is active yet.

**What to build:**
- `GetCCRotationData(profile, heroTalent)` — reads `ClassCodexData`, maps `UnitClassBase("player")` + `GetSpecialization()` to ClassCodex's key format; returns ordered `{spellID}` list for the selected profile. Returns `nil` if ClassCodex not installed or no data for spec.
- `ParseCCSteps(steps)` — extracts ordered spellID list from `{ "{123456} condition text", ... }` using `step:match("{(%d+)}")`. Returns a flat array of integers.
- `/hkl ccdata` slash command — calls `GetCCRotationData` with default profile, prints spell names (`C_Spell.GetSpellInfo(id).name`) and spellIDs to chat for in-game validation. Prints "ClassCodex not installed" or "No data for current spec" on failure.

**Acceptance criteria:**
- [ ] `/hkl ccdata` prints an ordered spell list for the current spec's default profile
- [ ] Output shows both spell name and spellID for each entry
- [ ] "ClassCodex not installed" message when `ClassCodexData` is nil
- [ ] "No data for spec" message when current spec has no CC entry
- [ ] No Lua errors on `/reload` regardless of whether ClassCodex is installed

---

### Story 12.2 — CC Rotation Resolver

```yaml
executor: "@wow-dev"
quality_gate: "@qa"
quality_gate_tools: ["/hkl cc on", "combat display observation", "/hkl log", "Lua error frame"]
```

**Objective:** `GetCCSuggestion()` and `GetCCSuggestionQueue(n)` — CC-mode counterparts to `GetActiveSuggestion()` and `GetSuggestionQueue(n)`. Route `Refresh()` through CC variants when `db.ccEnabled` is true.

**What to build:**
- `GetCCSuggestion()` — walks `ParseCCSteps()` output in priority order; for each spellID calls `GetRealSlot(spellID)` (pcall-guarded) and checks `IsUsableAction(slot)` + `C_Spell.GetSpellCooldown` (pcall-guarded); returns `spellID, realSlotID` for the first mechanically castable spell. Returns `nil, nil` if list exhausted.
- `GetCCSuggestionQueue(n)` — builds up to `n` entries using the same two-pass pattern as existing `GetSuggestionQueue`: off-cooldown spells fill first, then on-CD spells (greyed out). Guards with `rslot and IsUsableAction(rslot)` to exclude form-restricted spells.
- Routing in `Refresh()`: when `db.ccEnabled == true` and `GetCCRotationData()` returns non-nil, call CC variants instead of RA variants. When CC data unavailable, silently fall through to RA pipeline and DLog `CC_FALLBACK`.

**New `DEFAULTS` keys added (consumed by Story 12.3 UI, stubbed here):**
```lua
ccEnabled    = false,
ccProfile    = "Single Target",
ccHeroTalent = "",   -- empty string = auto-select first available heroTalent
```

**Acceptance criteria:**
- [ ] In CC mode, HekiLight display shows spells from ClassCodex priority order
- [ ] Greyed secondary slots (on-cooldown) work correctly
- [ ] In-range tinting, proc glow, and keybind labels all continue to work (same `realSlotID` pipeline)
- [ ] When CC data unavailable for current spec, silently falls back to RA mode
- [ ] `DLog("CC_FALLBACK", ...)` fires on fallback (change-detection guard: only log on spec change, not every frame)
- [ ] No Lua errors during normal combat

---

### Story 12.3 — CC Settings Section

```yaml
executor: "@wow-dev"
quality_gate: "@qa"
quality_gate_tools: ["/reload", "Settings panel open/close", "profile dropdown population", "enable toggle", "Lua error frame"]
```

**Objective:** "ClassCodex" section in the Settings panel for full UI control of the integration.

**Implementation note:** Target `Settings.lua` if EPIC-11 has shipped; target `HekiLight.lua → BuildSettingsPanel` otherwise. The section structure is identical either way.

**What to build:**
- New `MakeSection(L["ClassCodex"])` collapsed section, appended after Keybind Overrides
- **Enable toggle** — on/off dropdown or checkbox; writes `db.ccEnabled`; triggers immediate re-route in `Refresh()` (no `/reload` required)
- **Profile dropdown** — lists all unique `context` values from `ClassCodexData` for current spec (e.g., "Single Target", "Multitarget", "AOE Opener"); writes `db.ccProfile`; repopulates on spec change
- **Hero Talent dropdown** — lists `heroTalent` values available for the selected profile; writes `db.ccHeroTalent`; empty option = "Auto (first available)"
- **Source badge** — small label on the main HekiLight display (positioned near keybind text, same font) showing "CC" or "RA" indicating the active suggestion source; visible only when `db.showKeybind == true` or a new `db.showSource` flag (decide in implementation)
- **Not-installed state** — when `ClassCodexData` is nil, the section renders a single line "ClassCodex not installed" and the enable toggle is greyed out

**New locale keys (added to `Locale.lua`):**
- `L["ClassCodex"]`
- `L["CC Profile"]`
- `L["Hero Talent"]`
- `L["ClassCodex not installed"]`
- `L["Auto"]`
- `L["Source"]`

**Acceptance criteria:**
- [ ] Enabling CC mode in settings immediately switches suggestion source (no `/reload`)
- [ ] Profile dropdown populates dynamically from live `ClassCodexData`
- [ ] Hero Talent dropdown updates when profile changes
- [ ] Settings persist across `/reload`
- [ ] "ClassCodex not installed" message renders correctly; no Lua errors
- [ ] Source badge ("CC" / "RA") visible on display

---

### Story 12.4 — Slash Commands & Polish

```yaml
executor: "@wow-dev"
quality_gate: "@qa"
quality_gate_tools: ["/hkl cc on|off", "/hkl ccprofile", "/hkl ccstatus", "/hkl log"]
```

**Objective:** Chat-accessible controls, DLog integration, and edge case hardening.

**What to build:**
- `/hkl cc on|off` — toggle `db.ccEnabled`; prints confirmation
- `/hkl ccprofile <name>` — set `db.ccProfile` by partial case-insensitive match; prints "Profile set: Single Target" or "Unknown profile; available: ..." 
- `/hkl ccstatus` — prints current CC mode state, active profile, hero talent, spec, and spell count in active priority list
- DLog tags:
  - `CC_SUGGEST` — fires when CC resolver produces a suggestion (change-detection guard: only log when suggestion changes)
  - `CC_FALLBACK` — fires when falling back to RA (change-detection guard: only log on spec change)
  - `CC_PROFILE` — fires on profile or hero talent change
- `/hkl status` output extended — adds "CC mode: on/off (profile: Single Target)" line

**Acceptance criteria:**
- [ ] All new slash commands produce correct output from chat
- [ ] `/hkl log` shows CC tags interspersed with existing tags
- [ ] DLog CC_SUGGEST does not flood the 500-entry buffer (fires at most once per suggestion change, not every poll frame)
- [ ] `/hkl status` includes CC state line
- [ ] `/hkl reset` resets `ccEnabled`, `ccProfile`, `ccHeroTalent` to `DEFAULTS`

---

### Story 12.5 — Tier-1 Condition Evaluator

```yaml
executor: "@wow-dev"
quality_gate: "@qa"
quality_gate_tools: ["/hkl cc on", "combat display with resource-gated spells", "/hkl ccstatus", "/hkl log", "Lua error frame"]
```

**Objective:** Add a second gate in the CC resolver that evaluates the high-feasibility subset of ClassCodex condition text against live game state, so HekiLight skips a spell whose resource or buff condition is not yet met rather than suggesting it prematurely.

**Tier-1 conditions in scope (confirmed feasible against WoW 12.0 API):**

| Condition type | Pattern example | API used |
|----------------|----------------|----------|
| Resource threshold | "at 74 fury", "over 100 rage", "50 energy" | `UnitPower("player", Enum.PowerType.*)` |
| Buff / proc active | `{spellID} proc`, `?{spellID}:` prefix | `C_UnitAuras.GetAuraDataBySpellID("player", id)` |
| Debuff absent on target | `{spellID} is missing`, `not active` | `C_UnitAuras.GetAuraDataBySpellID("target", id)` |

**Tier-2+ conditions explicitly deferred (not evaluated in this story):**
- Pandemic timing ("within pandemic", "2 seconds remaining")
- Stack counts ("3 stacks of {id}")
- Talent checks (`?(H"TalentName")`)
- Charge availability ("capped on charges")
- Enemy count ("more than 6 targets")
- Complex boolean logic (`?(!(A|B)&C)`)
- Target health % ("at or below 20%")
- Movement / positional conditions

**What to build:**
- `EvalCCCondition(stepText)` — parses `stepText` for Tier-1 patterns and evaluates against live game state. Returns `true` if the condition is met OR if the condition is not parseable (fail-open: never incorrectly suppresses a spell). Returns `false` only when a Tier-1 condition is confidently detected and not satisfied.
- Power keyword table (module-level, not per-frame): maps resource name strings → `Enum.PowerType` values:
  ```lua
  local CC_POWER_MAP = {
      fury        = Enum.PowerType.Fury,
      rage        = Enum.PowerType.Rage,
      energy      = Enum.PowerType.Energy,
      mana        = Enum.PowerType.Mana,
      ["soul shards"]   = Enum.PowerType.SoulShards,
      ["runic power"]   = Enum.PowerType.RunicPower,
      insanity    = Enum.PowerType.Insanity,
      maelstrom   = Enum.PowerType.Maelstrom,
      ["astral power"]  = Enum.PowerType.LunarPower,
      ["combo points"]  = Enum.PowerType.ComboPoints,
  }
  ```
- `ParseCCSteps` extended — in addition to extracting the primary spellID, also stores the full raw step string alongside it so `EvalCCCondition` has the text available without re-reading the table.
- Integration in `GetCCSuggestion()`: after `IsUsableAction(slot)` passes, call `EvalCCCondition(stepText)` (pcall-guarded); if false, advance to next spell.
- New `DEFAULTS` key: `ccConditions = true` — allows the player to disable Tier-1 evaluation and revert to priority-order-only behavior (useful for debugging or if a condition is misread).
- `/hkl ccstatus` output extended — shows "Conditions: on (Tier 1)" or "Conditions: off".

**Acceptance criteria:**
- [ ] A Fury-gated spell (e.g., DH ability requiring 74+ Fury) is skipped when Fury is below threshold and the next eligible spell is shown instead
- [ ] A proc-gated spell is skipped when the proc buff is not active
- [ ] A "debuff missing" spell is skipped when the debuff IS active on target (condition not met)
- [ ] Unparseable conditions default to `true` — spell is never incorrectly suppressed due to an unrecognised condition
- [ ] `EvalCCCondition` is pcall-guarded — a Lua error inside it never crashes the poll loop
- [ ] `db.ccConditions = false` disables all condition evaluation and restores priority-order-only behavior
- [ ] No Lua errors during normal combat
- [ ] DLog `CC_COND_SKIP` fires when a spell is skipped due to a failed Tier-1 condition (change-detection guard)

---

## Compatibility Requirements

- ClassCodex not installed → HekiLight behaves identically to today; no UI change; no Lua error
- CC mode disabled → Blizzard RA pipeline is entirely unchanged
- All existing slash commands continue to function identically
- `SavedVariables` schema additions are additive only (`InitDB` fills missing keys, never overwrites)
- No changes to `HekiLightDBChar` (CC settings are account-wide in `HekiLightDB`)

---

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| ClassCodex spec key format unknown until in-game spike | Story 12.1 resolves this before any resolver code ships |
| CC priority list contains spells not on any action bar | `GetRealSlot()` returns nil → spell skipped silently (same guard as existing fallback) |
| ClassCodex addon updates change data format | `ParseCCSteps` is one isolated function; one place to update if format changes |
| Taint from reading ClassCodexData during combat | Plain Lua table read — zero taint risk |
| Player switches spec mid-session | `UnitClassBase` + `GetSpecialization()` evaluated each call; profile dropdown repopulates on `PLAYER_SPECIALIZATION_CHANGED` event |
| `EvalCCCondition` misreads a condition and incorrectly suppresses a spell | Fail-open design: unparseable patterns return `true`; `db.ccConditions = false` disables evaluator as escape hatch |
| `UnitPower` / `C_UnitAuras` calls add per-frame overhead | Called only for the first castable candidate per poll tick, not the entire list; pcall-guarded |
| Condition text wording changes in a ClassCodex update | Pattern matching is keyword-based (e.g., "fury", "rage", "proc"), not exact string matching; resilient to minor wording changes |

---

## Definition of Done

- [ ] `/hkl ccdata` prints a valid spell list for at least one tested spec
- [ ] CC mode resolver produces suggestions visible on the HekiLight display matching ClassCodex profile order
- [ ] Profile and hero talent dropdowns populate dynamically from live CC data
- [ ] Graceful fallback to RA when CC not installed or no spec data (no error, no blank display)
- [ ] All settings persist across `/reload`
- [ ] Source badge visible on display when CC mode is active
- [ ] Tier-1 condition evaluator skips resource-gated spells when the threshold is not met
- [ ] Tier-1 condition evaluator skips proc-gated spells when the buff is not active
- [ ] `db.ccConditions = false` reverts to priority-order-only behavior
- [ ] No Lua errors in Blizzard error frame during normal use or `/reload`
- [ ] DLog captures `CC_SUGGEST`, `CC_FALLBACK`, `CC_PROFILE`, `CC_COND_SKIP` without buffer flooding

---

## Out of Scope

**Condition evaluation — Tier 2+ (deferred to future epic):**
- Pandemic timing ("within pandemic", "2 seconds remaining on DOT")
- Stack counts ("3 stacks of {id}")
- Talent checks (`?(H"TalentName")`)
- Charge availability ("capped on charges")
- Enemy count ("more than 6 targets")
- Complex boolean logic (`?(!(A|B)&C)` DSL)
- Target health % ("at or below 20% health")
- Movement / positional conditions ("when kiting", "when moving")
- Pre-pull timing ("2s before pull")

**Other:**
- Auto-switching profiles based on number of enemies (deferred — future story)
- Syncing CC profile selection back to ClassCodex's own UI panel
- PvP builds, stat priorities, talent builds, or BiS gear from ClassCodex (rotation data only)
- Offline/cached CC data (HekiLight reads live `ClassCodexData`; if ClassCodex is not loaded, there is no data)

---

## Architecture Decisions

### ADR-12-1 — Read `ClassCodexData` directly; no event bridge

**Decision:** HekiLight reads `ClassCodexData` as a plain global Lua table on each `GetCCSuggestion()` call.

**Rationale:** ClassCodex exposes no write-back or subscription API. A plain Lua table read during the poll loop (every `db.pollRate` seconds, default 0.05 s) is zero-cost and zero-taint. If ClassCodex updates its data mid-session the change is picked up automatically on the next `Refresh()`.

### ADR-12-2 — Store `ccProfile` as context name string, not list index

**Decision:** `db.ccProfile = "Single Target"` (the `context` string).

**Rationale:** Index positions in ClassCodex's rotation array are not stable across addon updates. The context name string is resilient to reordering. If the stored name is absent from current data, `GetCCRotationData` falls back to the first available context and DLogs `CC_PROFILE`.

### ADR-12-3 — Tier-1 condition evaluation; complex conditions fail-open

**Decision:** HekiLight evaluates a defined subset of ClassCodex condition text (Tier 1: resource thresholds, buff/proc presence, debuff absence) using WoW 12.0 APIs confirmed in active use. All other condition patterns are treated as `true` (fail-open) and do not suppress the spell. A `db.ccConditions` flag allows the player to disable all condition evaluation and revert to priority-order-only behavior.

**Rationale:** Research (2026-05-24) confirmed `UnitPower`, `Enum.PowerType`, `C_UnitAuras.GetAuraDataBySpellID`, and `GetComboPoints` all survive the Midnight 12.0 API surface. The Tier-1 patterns (resource keyword + number, `{spellID} proc`, `{spellID} is missing`) appear in the majority of rotation steps across all four tested classes and map to unambiguous API calls. Tier-2+ conditions (pandemic timing, talent checks, stack counts, enemy count, complex boolean logic) require either a DSL parser, DOT duration tracking, or APIs with no simple read-path — these are deferred to a future epic.

**Fail-open is the safety invariant:** `EvalCCCondition` must never return `false` for a condition it does not recognise. Incorrectly suppressing a valid spell is worse than occasionally suggesting a spell whose non-Tier-1 condition is not met.

**Supersedes:** Original ADR-12-3 ("condition text discarded"), recorded here for history — that decision predated the API feasibility research.

### ADR-12-4 — CC settings in `HekiLightDB`, not `HekiLightDBChar`

**Decision:** `ccEnabled`, `ccProfile`, and `ccHeroTalent` live in account-wide `HekiLightDB`.

**Rationale:** Rotation profile preference (Single Target vs AOE) is a session-level choice, not character-specific. Unlike keybind overrides (which vary per character's action bar layout), the same player uses the same ClassCodex profile preference across all characters on an account.
