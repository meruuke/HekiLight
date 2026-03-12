# HekiLight Code Review Checklist

Run after every feature implementation, before release.

## Taint Safety
- [ ] All `C_ActionBar.*` in pcall
- [ ] All `C_Spell.GetSpellCooldown` in pcall
- [ ] All `GetActionInfo` in pcall
- [ ] `realSlotID` used for range checks (not Rotation Assistant slot)
- [ ] No Blizzard protected frame parenting

## Lua 5.1
- [ ] No `//` operator
- [ ] No `&|~` bitwise (use bit library)
- [ ] No `goto`
- [ ] No `table.unpack` (use `unpack`)

## State & Globals
- [ ] All new vars are `local`
- [ ] All new persistent state is in `HekiLightDB` via `db.*`
- [ ] All new `db.*` keys present in `DEFAULTS`
- [ ] `wipe(db)` called in reset before re-applying DEFAULTS

## Visibility Logic
- [ ] `ShouldShow()` called before API work in `Refresh()`
- [ ] Hard stops precede positive conditions in `ShouldShow()`
- [ ] New hide conditions in DEFAULTS (default false), ShouldShow, settings panel, ALWAYS_HIDE_FLAGS, help text
- [ ] New events registered if needed (e.g., ZONE_CHANGED_NEW_AREA for resting)

## Performance
- [ ] No table allocation in `OnUpdate` / `Refresh()` hot path
- [ ] `queueCache` reused (not recreated)
- [ ] `StopPollLoop()` exits polling when Rotation Assistant inactive
