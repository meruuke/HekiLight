# Architecture Decision Records — HekiLight

Decisions extracted from git history (2026-03-03 → 2026-04-19).

---

## ADR-1: Single-File Addon with No Build System

**Date:** 2026-03-03  
**Status:** Accepted  
**Commit:** `a817b1a` Initial scaffold

**Context:** WoW addons are plain Lua files loaded directly by the game client. Every Lua change requires `/reload` in-game. There is no package ecosystem analogous to npm or Cargo.

**Decision:** All addon logic lives in `HekiLight.lua`. No build step, no bundler, no external library. A second file (`Locale.lua`) was added in v0.3.0 only to hold translation strings — loaded first by the TOC so the global is available when the main file initialises.

**Consequences:**
- Deployment is `/reload`; no CI artifact beyond the raw `.lua` files.
- The file grows large (~2400 lines); `-- ── Section Name ───` banner comments are the only navigation aid.
- Any future splitting must be done via TOC load order, not `require`.

---

## ADR-2: OnUpdate Polling for Spell Suggestion

**Date:** 2026-03-03  
**Status:** Accepted  
**Commit:** `a817b1a` → refined by `ca87c92`

**Context:** The Rotation Assistant suggestion can change on every game frame. No WoW event fires when the RA suggestion changes — only `ACTIONBAR_UPDATE_STATE` fires on highlight changes, which is too coarse and too latent for a smooth display.

**Decision:** Use an `OnUpdate` script on the root `display` frame that fires `Refresh()` every `db.pollRate` seconds (default 0.05 s = 20 Hz). The loop is gated: it only runs while `IsAssistActive()` is true. `StartPollLoop` / `StopPollLoop` toggle the `OnUpdate` script.

**Rejected alternative:** Pure event-driven refresh. `ACTIONBAR_UPDATE_STATE` misses many mid-rotation updates; the suggestion can change faster than any available event.

**Consequences:**
- Zero CPU cost when RA is inactive (`ca87c92`).
- Poll loop must be explicitly stopped when it is no longer needed (see ADR-8 for a bug that arose from not doing this).

---

## ADR-3: Two-Layer Spell Suggestion Detection

**Date:** 2026-03-07  
**Status:** Accepted  
**Commits:** `3024ed1` add Assisted Highlight support, `a817b1a` initial fallback

**Context:** Blizzard provides two rotation assistance modes: the Rotation Assistant action bar button (`HasAssistedCombatActionButtons`) and the Assisted Highlight glow (`GetCVarBool("assistedCombatHighlight")`). `GetNextCastSpell` (Midnight 12.0+) covers both. Older API paths using `GetActionInfo` on the RA slot were the only option before that API existed.

**Decision:** `GetActiveSuggestion()` uses a two-layer detection:
1. **Primary:** `C_AssistedCombat.GetNextCastSpell(false)` — direct engine query, works with both modes.
2. **Fallback:** `FindAssistedCombatActionButtons()` → `GetActionInfo(slot)` — for any edge case where the primary returns nil.

Both paths are pcall-guarded.

**Consequences:**
- Covers both RA modes without separate code paths in `Refresh`.
- The fallback adds one pcall per tick when the primary unexpectedly fails — acceptable overhead.

---

## ADR-4: realSlotID Pattern for Taint-Safe Range Checks and Keybind Lookup

**Date:** 2026-03-03  
**Status:** Accepted  
**Commits:** `b652df6` slot→binding map, `7a57e71` keybind fix, `749eb1f` keybind lookup

**Context:** Rotation Assistant slots are Blizzard-protected frames. Calling `IsActionInRange` or `GetActionInfo` on an RA slot in combat taints the protected frame subsystem and can lock out ability usage. Blizzard does not expose a taint-safe keybind or range API for RA slots directly.

**Decision:** After resolving the suggested `spellID`, find a **regular** action bar slot containing the same spell via `C_ActionBar.FindSpellActionButtons(spellID)`, filtering out RA slots with `IsAssistedCombatAction`. This `realSlotID` is used for all range checks and keybind lookups. RA slots are never read for range or binding data.

**Consequences:**
- Keybind lookup: `spellID → FindSpellActionButtons → SLOT_BINDINGS[slot] → GetBindingKey`.
- Range check: `C_ActionBar.IsActionInRange(realSlotID)` — safe on regular slots.
- If the spell is not on any regular bar, `realSlotID` is nil and range/keybind silently degrade.

---

## ADR-5: Secret-Number pcall Trick for Cooldown Detection

**Date:** 2026-03-10  
**Status:** Accepted  
**Commits:** `92e8310` wrap cooldown in pcall, `1b843ab` use GetSpellBaseCooldown, `3abde4d` false-positive fix

**Context:** `C_Spell.GetSpellCooldown` returns a table with a `duration` field. In combat, this `duration` is a Blizzard "secret number" — a userdata value that intentionally throws a Lua error if compared arithmetically (to prevent addons from reading cooldown data during combat via taint pathways). The GCD returns a valid `duration` of ~1.5 s; real cooldowns return the secret value.

**Decision:** Wrap the cooldown comparison in `pcall`. If `duration == 0` succeeds without error, the spell is available (off cooldown or has a charge). If the pcall catches an error, the spell is on a real cooldown. `GetSpellBaseCooldown` (not `GetSpellCooldown`) is used separately to identify whether a spell has a real cooldown at all (threshold: > 1500 ms), so GCD-only spells are never entered into the tracking table.

**Consequences:**
- Zero false-positives from GCD: the secret-number pcall only returns `available = true` when `duration` is a plain `0`, which only happens when truly off cooldown.
- **Amended by ADR-13:** the `duration == 0` test was widened to `duration < 1.55` so the GCD (a plain ~1.5 s number) reads as available while only real cooldowns (secret numbers) throw. The old cast-tracking table `recentlyCastSpells` and its `UNIT_SPELLCAST_SUCCEEDED` handler were removed — cooldown state is now read live.

---

## ADR-6: Defensive Floater — Built and Reverted

**Date:** 2026-03-07  
**Status:** Reverted  
**Commits:** `6730f8f` add, `3b4a109` fix taint, `f898c67` revert

**Context:** A request to show a secondary "defensive cooldown" floater using `C_CooldownViewer` Essential cooldowns was implemented. The feature was functional out of combat but produced taint errors during combat that cascaded into blocking ability usage.

**Decision:** Feature reverted entirely. `C_CooldownViewer` APIs touch protected frame internals during combat in a way that cannot be safely isolated with pcall. The risk of blocking player abilities outweighs the benefit of the floater.

**Lesson recorded:** `C_CooldownViewer` is not safe to read from addon Lua during combat. Do not attempt to reintroduce a defensive floater using this API.

---

## ADR-7: Visibility Logic — Two Reversals

**Date:** 2026-03-07 → 2026-03-21 → 2026-04-19  
**Status:** Accepted (current two-tier model)  
**Commits:** `dd8629d` hide conditions, `a4c9c1a` positive-conditions refactor, `a90f6f0` all conditions removed, `48e6914` conditions restored

**Context:** The addon went through three distinct visibility philosophies:

1. **v0.1 (hide conditions):** Show always; suppress when dead / in vehicle / cinematic / resting / no target.
2. **v0.1.5 (positive conditions):** `a4c9c1a` replaced the hide-list with positive show conditions — must be in combat OR have an attackable target. This made the logic more explicit but over-suppressed the display in edge cases.
3. **v0.1.9 (no conditions):** `a90f6f0` removed `ShouldShow()` entirely — the icon is always visible whenever RA has a suggestion. Simplest possible logic; polling starts at world entry regardless of combat.
4. **v0.3.0 (two-tier restored):** `48e6914` restored `ShouldShow()` with hard stops (dead, vehicle, cinematic) separated from soft `showMode` conditions (always vs. active). User-configurable.

**Decision:** Current `ShouldShow()` is a two-tier gate:
- **Hard stops** (always suppress): dead, in vehicle, in cinematic.
- **Show mode** (user-configured): `"always"` shows whenever RA has a suggestion; `"active"` requires combat or an attackable target.

**Consequences:**
- Hard stops cannot be bypassed by show mode.
- All conditions are toggleable via settings panel and slash commands.

---

## ADR-8: Poll Loop Lifetime Tied to Combat State

**Date:** 2026-04-19  
**Status:** Accepted  
**Commits:** `a90f6f0` loop starts at world entry (no guard), `272c3fe` stop on PLAYER_REGEN_ENABLED

**Context:** In v0.1.9, the poll loop was started at `PLAYER_ENTERING_WORLD` unconditionally and never stopped. After `ShouldShow()` was restored in v0.3.0, the loop continued running at 50 ms out of combat — calling `GetNextCastSpell`, `GetRotationSpells`, and `GetSpellInfo` on every tick even with the display hidden.

**Decision:** `PLAYER_REGEN_ENABLED` (combat end) calls `StopPollLoop()` before `Refresh()`. `PLAYER_REGEN_DISABLED` (combat start) and `ACTIONBAR_SLOT_CHANGED` restart the loop when `IsAssistActive()` returns true. For `showMode = "always"`, RA is still only meaningful in combat — polling out of combat adds CPU cost for no visible benefit.

**Consequences:**
- Zero polling overhead between fights.
- The loop restarts instantly on combat re-entry (elapsed is pre-seeded to `db.pollRate` so the first frame fires immediately).

---

## ADR-9: Talent Override Icon Resolution

**Date:** 2026-04-19  
**Status:** Accepted  
**Commit:** `7ac1a21`

**Context:** `C_AssistedCombat.GetNextCastSpell` returns the **base** spellID for talent-replaced abilities (e.g., Death and Decay `43265` even when Defile `152280` is talented). `C_Spell.GetSpellInfo(43265)` returns the Death and Decay icon, not Defile's — confusing for Blood DK players.

**Decision:** After resolving `realSlotID`, call `GetActionInfo(realSlotID)` in a pcall. The action bar slot returns the talent-override spellID (e.g., `152280` for Defile). If the returned ID differs from the base ID, substitute it. The `OVERRIDE` DLog tag records every substitution for debugging.

**Consequences:**
- Icon and spell name now match what the player will actually cast.
- Secondary slot deduplication must compare against the override ID, not the base ID (open bug as of v0.3.0 — `GetRotationSpells` returns base IDs and the `sid ~= primaryID` check may miss them).
- Keybind lookup via `FindSpellActionButtons(overrideID)` may not find the slot if Blizzard indexes it under the base ID; `keybindCache` mitigates this for subsequent frames.

---

## ADR-10: Pre-Allocated Suggestion Queue

**Date:** 2026-03-10  
**Status:** Accepted  
**Commits:** `f09711c` multi-suggestion strip, refined in `48e6914`

**Context:** `GetSuggestionQueue` is called every 50 ms. Allocating a new table each call creates garbage that the Lua GC must eventually collect — GC pauses are visible as frame drops, especially in WoW's Lua 5.1 incremental collector.

**Decision:** `queueCache` is a module-level table pre-allocated at startup with `MAX_SLOTS` (5) entries, each a fixed `{spellID, realSlotID, onCooldown}` table. `GetSuggestionQueue` wipes and repopulates these entries in-place. `queueCount` tracks how many are valid.

**Consequences:**
- Zero per-frame allocation from the suggestion queue.
- Callers must not retain references to `queueCache` entries across frames.

---

## ADR-11: Per-Character vs Account-Wide SavedVariables

**Date:** 2026-03-10  
**Status:** Accepted  
**Commit:** `24df7f4` per-character ignored spells

**Context:** `HekiLightDB` (account-wide `SavedVariables`) stores display settings: position, scale, icon size, show mode, etc. These are deliberately shared across all characters on the account — one set of UI preferences for everything.

The `ignoredSpells` list is inherently class-specific: a spell ignored on a Warlock is meaningless on a Death Knight.

**Decision:** `ignoredSpells` and `classDefaultsApplied` live in `HekiLightDBChar` (`SavedVariablesPerCharacter`). All other settings remain account-wide.

**Consequences:**
- `db` → `HekiLightDB` (account), `dbChar` → `HekiLightDBChar` (character).
- Class-specific maintenance spells (pet summons, Revive Pet) are auto-added to `ignoredSpells` on first load via `CLASS_DEFAULT_IGNORED`.

---

## ADR-12: Session Log as Ring Buffer in SavedVariables

**Date:** 2026-04-19  
**Status:** Accepted  
**Commit:** `48e6914`

**Context:** WoW addons cannot write to disk directly; the only persistence mechanism is `SavedVariables`, flushed by the game on `/reload` or logout. Diagnosing suggestion pipeline bugs (wrong icons, wrong spells) required a way to capture what Blizzard actually returned during a fight and inspect it after.

**Decision:** `DLog(tag, msg)` appends timestamped entries to `HekiLightDB.sessionLog` (a module-level reference set up in `InitDB`). The buffer is capped at 500 entries (ring: oldest entry removed when full via `table.remove(t, 1)`). On each `/reload`, the current session is moved to `HekiLightDB.lastSessionLog` and a fresh log starts. `/hkl log [N]` prints the last N entries from whichever log is non-empty.

**Consequences:**
- Log survives `/reload` and WoW crashes that flush SavedVariables.
- `table.remove(t, 1)` is O(n) — at 500 entries this is negligible but would degrade if `MAX_LOG` were significantly increased; a circular index would be O(1).
- Change-detection guards (`lastLogSuggID`, `lastSlotSpellID`, `lastSkippedAlertID`) prevent high-frequency events from flooding the buffer.

---

## ADR-13: Availability-Based Cooldown Greying with GCD Window

**Date:** 2026-09-30  
**Status:** Accepted (amends ADR-5)

**Context:** `IsSpellOnCooldown` originally returned `true` only for spells present in `recentlyCastSpells` — i.e. spells the addon had *witnessed the player cast* (`UNIT_SPELLCAST_SUCCEEDED`, base CD > 1500 ms). This missed every cooldown the addon never observed: abilities used before combat/before the poll loop started, proc-triggered cooldowns, and anything cast while the addon was reloaded mid-fight. Those spells fell into pass 1 of `GetSuggestionQueue` and rendered at full brightness. Observed live on Aug Evoker: the secondary strip showed on-cooldown spells (including a major winged-dragon cooldown) never greying — captured on video 2026-09-30.

**Decision:** `IsSpellOnCooldown(sid)` (gated on base CD > 1500 ms) reads the live cooldown directly: `not (IsSpellAvailable(sid) or HasChargeReady(sid))`. The key is that `IsSpellAvailable` is now **GCD-aware** — it treats `C_Spell.GetSpellCooldown.duration < 1.55 s` as available, not just `== 0`. Per ADR-5, Blizzard returns a **plain ~1.5 s number for the GCD** but a **secret number for a real cooldown**; so an off-CD spell sitting on the GCD reads as available (duration ~1.5 < 1.55), while a spell on its real CD makes the `<` comparison throw under taint → pcall catches it → unavailable. `HasChargeReady` (pcall-guarded `C_Spell.GetSpellCharges`) keeps charge-based spells with a banked charge from greying.

**Rejected alternative:** a `gcdUntil` window refreshed from `GetHaste()` on `UNIT_SPELLCAST_SUCCEEDED`. In combat, under addon-tainted execution, `GetHaste()` returns a **secret number** and any arithmetic on it throws (`attempt to perform arithmetic on ... a secret number value`). The GCD-aware duration check needs no haste, no time window, and no cast tracking — so `recentlyCastSpells` and the `UNIT_SPELLCAST_SUCCEEDED` handler were removed entirely.

**Consequences:**
- Secondary slots grey for *any* on-cooldown real-CD spell, not just witnessed casts — the reported bug is fixed, with no per-cast state to maintain.
- Also tightens the proc-alert gate (`UpdateProcAlert` uses `IsSpellOnCooldown`): a real-CD proc on cooldown is now correctly suppressed (consistent with the intent of stories 9.2/9.3).
- Out of combat, real cooldowns return plain numbers, so a real-CD spell with < 1.55 s remaining briefly reads as available. Harmless — greying is a combat feature and the poll loop is combat-gated.
- Primary slot (slot 1) still never desaturates by design (`i > 1 and entry.onCooldown`, render loop) — a separate decision if that should change.

**Follow-up (same day):** the check must run on the **override** spellID, not the base ID `GetRotationSpells()` returns. Evoker empower spells with Font of Magic (Fire Breath `357208` → `382266`, Eternity Surge `359073` → `382411`) track their cooldown on the override, so `IsSpellOnCooldown(sid)` never saw the CD and those spells never greyed. `GetSuggestionQueue` now calls `IsSpellOnCooldown(effectiveID)` (from `resolveSecondary`, the same source ADR-9 uses for icons/dedup). Added a `CDCHECK` DLog tag (change-detected) to confirm the resolved ID and cooldown state in-game.
