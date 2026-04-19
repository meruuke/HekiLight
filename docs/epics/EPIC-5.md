# EPIC-5: Correctness Hardening

**Status:** Done
**Version range:** v0.4.0 → current
**Depends on:** EPIC-4 (Done)

## Goal

Fix the three correctness bugs carried out of EPIC-4 that affect secondary slot rendering when talent override spells are involved. All three bugs share the same root cause: the secondary spell pipeline (`GetSuggestionQueue` → `GetRotationSpells`) operates on **base spellIDs** while the primary pipeline works with **override spellIDs**, creating mismatches at deduplication, range-check, and icon-resolution steps.

## Business Value

These bugs are most visible to talent-heavy specs (Blood DK with Defile, any spec with proc-based talent replacements). The secondary suggestion strip shows incorrect or duplicate spells, undermining player trust in the addon's accuracy. Fixing the full pipeline consistency closes the gap between what Blizzard's RA engine knows and what HekiLight displays.

## Stories

| ID | Title | Status |
|----|-------|--------|
| 5.1 | Override-aware secondary slot deduplication | Done |
| 5.2 | `IsActionInRange` pcall guard | Done |
| 5.3 | `GetRealSlot` for secondary spells | Done |

## Key Technical Context

- `GetRotationSpells()` returns **base spellIDs** — e.g., Death and Decay (`43265`), not Defile (`152280`)
- `GetNextCastSpell(false)` returns the **override spellID** — what will actually be cast
- `primaryID` set in `GetSuggestionQueue` is therefore an override ID
- `sid ~= primaryID` dedup comparison is base-vs-override — always misses the match
- `FindSpellActionButtons(baseID)` in `GetRealSlot` may return nil if the bar slot is indexed under the override spellID
- `C_ActionBar.IsActionInRange` at ~line 1743 in `Refresh` is the only remaining un-pcall-guarded taint-sensitive call

## Acceptance Criteria (Epic-Level)

- [ ] Secondary slots never duplicate the primary suggestion, even when the primary is a talent override
- [ ] Range tint applies correctly to secondary slots (or safely skips if no real slot found)
- [ ] No taint errors from `IsActionInRange` regardless of slot type
- [ ] `OVERRIDE` DLog entries fired for secondary spell resolution, matching the primary pipeline behavior
- [ ] `/hkl log 20` after a fight shows consistent base/override IDs with no mismatch artifacts

## Forbidden APIs

- `C_CooldownViewer` — permanently off-limits (ADR-6, combat taint)
- Direct write to any action bar slot — taint violation
