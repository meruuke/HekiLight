# HekiLight WoW Squad

Specialized AIOX agent squad for the **HekiLight** World of Warcraft addon.

## Agents

| Agent | Persona | Role | Activate with |
|-------|---------|------|---------------|
| `@wow-dev` | Kael 🧙 | Lua development, WoW API, rotation AI design, UI frames | `@.claude/commands/AIOX/agents/wow-dev.md` |
| `@wow-qa` | Lyra 🔍 | Code review, taint audit, Lua 5.1 compat, pre-release gate | `agents/wow-qa.md` |
| `@wow-devops` | Gage 🚀 | Git push, tagging, TOC version bump, CurseForge release | `agents/wow-devops.md` |

## Workflow: Adding a Feature

```
@wow-dev → design & implement
    ↓
@wow-qa → run addon-review checklist
    ↓
@wow-devops → addon-release (bump TOC, tag, push)
```

Or run the full workflow: `*workflow addon-feature`

## Tasks

| Task | Agent | Purpose |
|------|-------|---------|
| `addon-review` | wow-qa | Full code quality gate |
| `addon-release` | wow-devops | Release pipeline |
| `addon-debug` | wow-dev | Diagnose WoW error messages |
| `api-lookup` | wow-dev | WoW API reference with taint risk |

## Checklists

- `addon-review-checklist.md` — pre-release code review
- `addon-release-checklist.md` — release gate

## Key Rules (always apply)

1. **Lua 5.1 only** — no `//`, no `goto`, no bitwise operators
2. **pcall everything taint-sensitive** — `C_ActionBar.*`, `C_Spell.GetSpellCooldown`, `GetActionInfo`
3. **`realSlotID` for range checks** — never use Rotation Assistant slots directly
4. **`ShouldShow()` before API work** in `Refresh()` — hard stops first
5. **All new `db.*` keys in `DEFAULTS`** with sane defaults
6. **`/reload` is deployment** — the only way to apply Lua changes in-game
