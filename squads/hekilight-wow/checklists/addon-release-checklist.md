# HekiLight Release Checklist

Run before every version tag.

## Quality Gate (wow-qa)
- [ ] `addon-review` checklist fully green
- [ ] No open taint risks
- [ ] No Lua 5.1 incompatibilities
- [ ] No global leaks

## Version Bump (wow-devops)
- [ ] `## Version` in `HekiLight.toc` updated to new version
- [ ] Version follows semver (PATCH for fixes, MINOR for features, MAJOR for schema breaks)
- [ ] TOC version matches intended git tag exactly

## Git (wow-devops)
- [ ] `git status` clean (only intended files staged)
- [ ] Commit message follows conventional commits format
- [ ] Tag `vX.Y.Z` does not already exist
- [ ] `git push origin master --tags` completed successfully

## Post-Release
- [ ] GitHub Actions CurseForge workflow triggered
- [ ] Tag visible on GitHub releases page
