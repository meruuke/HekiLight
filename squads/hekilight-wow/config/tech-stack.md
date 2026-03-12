# HekiLight Tech Stack

## Runtime
- **World of Warcraft Retail** — Midnight 12.0+ (`## Interface: 120001`)
- **Lua 5.1** — WoW's embedded scripting engine
- No external dependencies, no build system, no package manager

## Files
| File | Purpose |
|------|---------|
| `HekiLight.lua` | Entire addon — all logic, UI, events, slash commands |
| `HekiLight.toc` | Addon metadata — Interface version, SavedVariables declaration |

## WoW API Namespaces Used
- `C_AssistedCombat` — Rotation Assistant spell suggestions
- `C_ActionBar` — Action slot queries, Rotation Assistant slot detection
- `C_Spell` — Spell info, cooldown data
- `C_SpellActivationOverlay` — Proc glow state
- `C_Timer` — Ticker for glow/range pulse animations
- `Settings` — WoW Settings panel integration

## Frame API
- `CreateFrame("Frame", ..., "BackdropTemplate")` — root container
- `SetPoint` / `ClearAllPoints` — anchoring
- Textures: `frame:CreateTexture` with `SetTexture(iconID)`
- Font strings: `frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")`

## SavedVariables
- `HekiLightDB` — per-account settings (all `db.*` keys)
- `HekiLightDBChar` — per-character data (`dbChar.ignoredSpells`)

## Events Used
| Event | Purpose |
|-------|---------|
| `ADDON_LOADED` | Init DB, build frames |
| `PLAYER_ENTERING_WORLD` | Rebuild bindings, initial refresh |
| `PLAYER_REGEN_DISABLED/ENABLED` | Combat state tracking |
| `UNIT_FLAGS`, `UNIT_HEALTH` | Dead/vehicle state changes |
| `PLAYER_MOUNT_DISPLAY_CHANGED` | Mount state |
| `PLAYER_TARGET_CHANGED` | Target visibility condition |
| `ZONE_CHANGED_NEW_AREA` | Resting area detection |
| `CINEMATIC_START/STOP`, `PLAY_MOVIE/STOP_MOVIE` | Cinematic suppression |
| `ACTIONBAR_SLOT_CHANGED`, `UPDATE_BINDINGS` | Keybind rebuild |
| `SPELL_ACTIVATION_OVERLAY_GLOW_SHOW/HIDE` | Proc glow |
| `UNIT_SPELLCAST_SUCCEEDED` | Cooldown tracking |

## Release Pipeline
- **Git** — version control on GitHub (`mauro-pinheiro/HekiLight`)
- **GitHub Actions** — `.github/workflows/curseforge.yml` auto-uploads on tag push
- **CurseForge** — primary addon distribution platform
- **Tags** — semver `vX.Y.Z` triggers release
