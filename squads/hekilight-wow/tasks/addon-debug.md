---
task: WoW Addon Error Diagnosis
agent: wow-dev
atomic_layer: task
---

# addon-debug

Diagnose a WoW addon error from the Lua error dialog or `/hkl debug` output.

## Input

Paste the full error including:
- Message line (`attempt to call global 'X' (a nil value)`)
- Stack trace (file:line references)
- Locals dump (variable state at crash point)

## Diagnosis Framework

### Common Error Patterns

| Error message | Likely cause | Fix |
|---------------|-------------|-----|
| `attempt to call global 'X' (a nil value)` | Forward declaration missing or function defined after call site | Add `local X` forward declaration before first use |
| `attempt to index global 'db' (a nil value)` | `ADDON_LOADED` not yet fired, `db` not set | Guard with `if not db then return end` |
| `attempt to call a nil value` on WoW API | API removed or renamed in patch | Check API name against current WoW API docs |
| `script ran too long` | Infinite loop or expensive operation in `OnUpdate` | Profile `Refresh()` — check for O(n²) loops |
| `action blocked by interface action` | Taint — addon touched protected frame | Wrap in `pcall()`, use `realSlotID` not Rotation Assistant slot |
| `table index is nil` | Indexing with a nil key | Add nil guard before table access |

## Steps

1. Identify error type from message
2. Locate file:line in HekiLight.lua
3. Read the Locals dump — identify nil or unexpected values
4. Trace back to root cause
5. Propose minimal fix
6. Note if a pcall wrapper is needed
