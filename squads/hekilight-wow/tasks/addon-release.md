---
task: WoW Addon Release
agent: wow-devops
atomic_layer: task
---

# addon-release

Full release pipeline for HekiLight. Run after `addon-review` passes.

## Steps

1. **Confirm QA gate passed** — do not release if `addon-review` has open items
2. **Determine version** — next semver from `git tag --sort=-version:refname | head -1`
3. **Bump TOC version** — update `## Version: X.Y.Z` in `HekiLight.toc`
4. **Commit** — `git add HekiLight.toc && git commit -m "chore: bump version to vX.Y.Z"`
5. **Tag** — `git tag vX.Y.Z`
6. **Push** — `git push origin master --tags`
7. **Verify** — confirm GitHub Actions triggered CurseForge upload workflow

## Version Bump Rules

| Change type | Version part |
|-------------|-------------|
| Bug fix / small tweak | PATCH (0.0.X) |
| New feature / new condition | MINOR (0.X.0) |
| Breaking SavedVariables schema change | MAJOR (X.0.0) |

## Checklist

- [ ] `addon-review` checklist fully green
- [ ] `HekiLight.toc` `## Version` updated
- [ ] Tag matches TOC version exactly (`v0.1.3` ↔ `## Version: 0.1.3`)
- [ ] Tag does not already exist on remote
- [ ] `git push --tags` confirmed
- [ ] GitHub Actions `.github/workflows/curseforge.yml` triggered
