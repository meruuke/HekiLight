# EPIC-13: Logging & Observability Improvements

**Status:** Planned
**Version range:** TBD
**Depends on:** None

## Goal

Improve the DLog session log so that diagnostic data survives character switches and is accessible for post-session analysis without requiring the player to stay on the same character or avoid reloading.

## Business Value

When diagnosing bugs (e.g. keybind resolution after shapeshifting), the session log is the primary tool. Currently it is lost whenever the player switches characters, because `HekiLightDB.sessionLog` is account-level and rolls into `lastSessionLog` on every new session — discarding all previous data. This makes it impossible to verify fixes that span multiple characters or require cross-session comparison.

## Stories

| ID   | Title                                         | Status |
|------|-----------------------------------------------|--------|
| 13.1 | Per-character session log with history retention | Draft  |

## Key Technical Context

- `HekiLightDB.sessionLog` is account-wide (lives in the global `HekiLightDB`)
- On every `ADDON_LOADED`, the previous `sessionLog` is moved to `lastSessionLog` and a fresh ring buffer starts — only one previous session is kept
- `HekiLightDBChar` is per-character — moving the log there would preserve each character's history independently
- The ring buffer cap is 500 entries; with per-character logs this could be kept the same or reduced
- `/hkl log [N]` and `/hkl log last [N]` would need to be updated to read from the correct table

## Acceptance Criteria (Epic-Level)

- [ ] Each character's DLog session log is stored in `HekiLightDBChar` instead of `HekiLightDB`
- [ ] Switching characters does not overwrite or discard another character's log
- [ ] At least the current and one previous session are retained per character
- [ ] `/hkl log [N]` still works correctly after the migration
- [ ] No regression in log output format or DLog tag behaviour
