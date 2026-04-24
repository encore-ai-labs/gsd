# CLAUDE.md

Project-specific instructions for Claude Code.

## Project

GSD — a macOS menu bar todo app. Single-file Swift app at `Sources/GSD/GSD.swift`. Distributed as a notarized DMG via GitHub Releases and a Homebrew cask at `encore-ai-labs/homebrew-gsd`.

## Cutting a release

When the user asks for a new release (e.g. "ship 1.0.3", "cut a release", "release it"):

### 1. Pick the version
Use SemVer against the previous tag:
- Bug fix only → patch bump (1.0.2 → 1.0.3)
- New feature, backward-compatible → minor bump (1.0.2 → 1.1.0)
- Breaking change → major bump (unlikely for this app)

Confirm the version with the user if ambiguous.

### 2. Open a version-bump PR
`Resources/Info.plist` is the single source of truth — `scripts/build-dmg.sh` reads the version from it via `PlistBuddy`. Edit both keys:
- `CFBundleVersion`
- `CFBundleShortVersionString`

Branch name: `release/X.Y.Z`. PR title: `Bump to X.Y.Z`. In the PR body, list the feature/fix PRs that ship in this release.

### 3. After the user merges, run the release script
```
git checkout main && git pull origin main
bash scripts/release.sh
```

`scripts/release.sh` handles the whole pipeline:
1. Preconditions (on main, clean tracked files, in sync with origin, tag doesn't exist).
2. Reads the version from `Info.plist`.
3. Runs `scripts/build-dmg.sh` — builds universal binary, signs with Developer ID, notarizes via `notarytool --keychain-profile GSD-NOTARY`, staples the app and the DMG.
4. Tags the current commit, pushes the tag.
5. `gh release create vX.Y.Z .build/GSD-X.Y.Z.dmg --generate-notes`.
6. Clones `encore-ai-labs/homebrew-gsd`, rewrites `version` and `sha256` in `Casks/gsd.rb`, commits, pushes.

After it finishes, users can `brew upgrade --cask gsd` to pick it up.

### 4. Notable gotchas
- **`main` is branch-protected.** All changes must go through a PR. Never try to push directly to main — it will fail and the user will have to lift protection.
- **`Resources/AppIcon.iconset/` is intentionally untracked** (source material for `AppIcon.icns`). `release.sh` uses `git diff-index --quiet HEAD` so it ignores untracked files — do not "fix" this by committing the iconset or by making the cleanliness check stricter.
- **Notarization credentials are stored in the keychain** under profile `GSD-NOTARY`. If a release fails on notarization, check `xcrun notarytool history --keychain-profile GSD-NOTARY`. The credentials themselves (Apple ID, app-specific password) must never be hardcoded in any script or committed file.
- **Team ID `96R8Y9KHJP`** is the Developer ID Application cert for Encore AI Labs. It's public (embedded in every signed binary).

### 5. What not to do
- Do not use `git commit --amend` on a published commit; always create a new commit.
- Do not use `git push --no-verify` or skip hooks.
- Do not submit to the main `Homebrew/homebrew-cask` upstream — the app doesn't meet the notability threshold yet (<75 stars). The tap at `encore-ai-labs/homebrew-gsd` is the distribution path.

## Storage layout

User notes live at `~/.gsd/<notebook>/YYYY-MM-DD.md` — plain markdown files, no database. Uninstalling the app does not delete notes. `brew uninstall --cask gsd --zap` is what removes them.

## Testing UI changes

This is a native macOS menu-bar app, not a web app. `swift build -c release` verifies compilation but not visual behavior. For UI changes, build locally and ask the user to click through the change — don't claim the UI works based on a clean build alone.

Quick-test recipe:
```
swift build -c release --arch arm64
# Bundle into a throwaway .app for launch (Info.plist + icon are needed)
# Then `open` it and ask the user to verify
```

If a change requires the global Cmd+0 hotkey to be re-registered or the popover to reinitialize, quitting the running GSD (`osascript -e 'tell application "GSD" to quit'`) and launching the test build is required.
