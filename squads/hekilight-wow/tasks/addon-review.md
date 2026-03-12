---
task: WoW Addon Code Review
agent: wow-qa
atomic_layer: task
---

# addon-review

Full quality review of HekiLight.lua covering all critical WoW addon concerns.

## Checklist

### Taint Safety
- [ ] All `C_ActionBar.*` calls wrapped in `pcall()`
- [ ] All `C_Spell.GetSpellCooldown` calls wrapped in `pcall()`
- [ ] All `GetActionInfo` calls wrapped in `pcall()`
- [ ] No direct writes to Blizzard-protected frames
- [ ] `realSlotID` (not Rotation Assistant slot) used for `IsActionInRange`

### Lua 5.1 Compatibility
- [ ] No integer division operator `//`
- [ ] No bitwise operators `&`, `|`, `~` (use `bit.band` etc.)
- [ ] No `goto` statements
- [ ] No `table.unpack` (use `unpack`)
- [ ] String patterns use `%` not `\` for escapes

### Global Hygiene
- [ ] Every variable is `local` or stored in `HekiLightDB`
- [ ] No accidental global writes (missing `local` keyword)
- [ ] `HekiLightDB` is the only addon global

### SavedVariables
- [ ] Every `db.*` key used in code exists in `DEFAULTS`
- [ ] `InitDB()` only adds missing keys, never overwrites existing values
- [ ] `/hkl reset` calls `wipe(db)` before re-applying DEFAULTS

### ShouldShow Logic
- [ ] Hard stops checked before positive conditions
- [ ] `ShouldShow()` called at the top of `Refresh()` before any API work
- [ ] All new hide conditions in both `DEFAULTS` and `ShouldShow`
- [ ] All new hide conditions registered in `ALWAYS_HIDE_FLAGS` for slash commands

### Poll Loop
- [ ] No table construction inside `OnUpdate` / `Refresh()` hot path
- [ ] `queueCache` pre-allocated and reused
- [ ] `StopPollLoop()` called when Rotation Assistant is inactive

### Forward Declarations
- [ ] `local Refresh` forward-declared before `BuildSettingsPanel()`
- [ ] `Refresh = function()` assignment (not `local function Refresh()`)
