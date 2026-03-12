# HekiLight Coding Standards

## Language & Runtime
- **Lua 5.1** only — WoW's embedded Lua runtime
- No `//`, `&`, `|`, `~`, `goto`, `table.unpack`
- Use `math.floor()` for integer division
- Use `bit.band/bor/bxor` for bitwise operations if needed

## File Structure
- **Single file**: all code in `HekiLight.lua`
- Sections separated by `-- ── Section Name ───` banner comments
- Section order: Defaults → State → Frames → Helpers → UI Construction → Core Loop → Events → Slash Commands

## State Management
- All state in **module-level locals** — no OOP, no namespaces
- Only global: `HekiLightDB` (SavedVariables) and `HekiLightDBChar` (per-character)
- `local db` points to `HekiLightDB` after `ADDON_LOADED`
- `DEFAULTS` is the single source of truth for all settings

## Taint Rules
- Wrap in `pcall()`: `C_ActionBar.*`, `C_Spell.GetSpellCooldown`, `GetActionInfo`
- Never use Rotation Assistant slot IDs for range checks — use `realSlotID`
- Never parent addon frames to Blizzard protected frames
- Never write to Rotation Assistant action bar slots

## Naming
- Functions: `PascalCase` for module-level named functions (`ShouldShow`, `Refresh`)
- Variables: `camelCase` for locals, `UPPER_CASE` for constants
- Frame children: descriptive names on slot tables (`slot.iconTexture`, `slot.keybindText`)

## Comments
- Add comments only where logic is non-obvious
- Taint risks must be commented with `-- pcall: taint risk`
- Event handlers comment what state they update

## Deployment
- `/reload` in-game is the only deployment mechanism
- Test with `/hkl debug` for verbose logging
- Use `/hkl status` to inspect Rotation Assistant state
