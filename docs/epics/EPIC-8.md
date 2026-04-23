# EPIC-8: Addon Branding & UI Polish

**Status:** Done
**Goal:** Give HekiLight a consistent visual identity across all WoW UI surfaces where addons appear — the AddOn list icon, the minimap button icon, and the minimap button tooltip.

## Motivation

EPICs 1–7 focused on correctness, robustness, and UX of the core overlay. By v0.6.0 the addon shipped with no icon in the AddOn list (generic `?`) and a generic `ability_whirlwind` spell icon on the minimap button — giving no visual identity. The minimap button also triggered Blizzard's "use LibDBIcon" tooltip warning, which is jarring for players and undermines trust in the addon.

## Stories

| Story | Title | Status |
|-------|-------|--------|
| 8.1 | Addon Icon & Minimap Button Branding | InReview |

## Out of Scope

- LibDBIcon dependency (intentionally avoided — HekiLight has no LibStub)
- New art assets beyond resizing the existing `assets/logo.png`
- Minimap button feature changes (drag, click, visibility toggle unchanged)
