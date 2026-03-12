---
task: WoW API Lookup
agent: wow-dev
atomic_layer: task
---

# api-lookup

Look up a WoW API function and return: signature, return values, taint risk, and usage example for HekiLight.

## Input

API function name (e.g., `C_Spell.GetSpellInfo`, `IsActionInRange`, `UnitInVehicle`)

## Output Format

```
### <API Name>

**Signature:** `<returnType> = ApiName(arg1, arg2, ...)`
**Returns:** description of return values
**Taint risk:** None | Low | HIGH — reason
**pcall required:** yes / no
**Usage in HekiLight:**
  <code example>
**Notes:** edge cases, nil returns, version notes
```

## HekiLight API Surface (quick reference)

| API | Taint | Returns |
|-----|-------|---------|
| `C_AssistedCombat.GetNextCastSpell(false)` | None | spellID or nil |
| `C_AssistedCombat.GetRotationSpells()` | None | table of spellIDs |
| `C_ActionBar.HasAssistedCombatActionButtons()` | None | bool |
| `C_ActionBar.FindAssistedCombatActionButtons()` | None | table of slotIDs |
| `C_ActionBar.IsAssistedCombatAction(slotID)` | None | bool |
| `C_ActionBar.FindSpellActionButtons(spellID)` | LOW | table of slotIDs |
| `C_ActionBar.IsActionInRange(slotID)` | HIGH | bool (pcall!) |
| `C_Spell.GetSpellInfo(spellID)` | None | table {name, iconID, ...} |
| `C_Spell.GetSpellCooldown(spellID)` | HIGH | table (pcall!) |
| `C_SpellActivationOverlay.IsSpellOverlayed(spellID)` | None | bool |
| `GetSpellBaseCooldown(spellID)` | None | ms as number |
| `IsPlayerSpell(spellID)` | None | bool |
| `UnitIsDeadOrGhost("player")` | None | bool |
| `IsMounted()` | None | bool |
| `IsResting()` | None | bool |
| `UnitInVehicle("player")` | None | bool |
| `UnitCanAttack("player", "target")` | None | bool |
| `UnitExists("target")` | None | bool |
