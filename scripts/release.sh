#!/bin/bash
# End-to-end release pipeline. Reads the version from Resources/Info.plist,
# builds + notarizes the DMG, tags and publishes a GitHub release, and bumps
# the Homebrew cask at encore-ai-labs/homebrew-gsd.
#
# Usage: bash scripts/release.sh
#
# Preconditions:
#   - on main, clean working tree, synced with origin
#   - Resources/Info.plist and scripts/build-dmg.sh already bumped to the new version
#   - notarytool profile "GSD-NOTARY" exists in keychain
#   - `gh` authenticated with push rights on encore-ai-labs/homebrew-gsd
set -euo pipefail

TAP_REPO="encore-ai-labs/homebrew-gsd"
APP_REPO_SLUG="encore-ai-labs/gsd"

BRANCH="$(git branch --show-current)"
if [[ "${BRANCH}" != "main" ]]; then
    echo "error: must be on main, currently on '${BRANCH}'" >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is dirty" >&2
    exit 1
fi

git fetch origin main --quiet
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
    echo "error: local main is not in sync with origin/main" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v${VERSION}"
DMG=".build/GSD-${VERSION}.dmg"

if gh release view "${TAG}" --repo "${APP_REPO_SLUG}" >/dev/null 2>&1; then
    echo "error: release ${TAG} already exists on ${APP_REPO_SLUG}" >&2
    exit 1
fi

if git rev-parse "${TAG}" >/dev/null 2>&1; then
    echo "error: tag ${TAG} already exists locally" >&2
    exit 1
fi

echo "==> Releasing ${TAG}"

bash scripts/build-dmg.sh

SHA256="$(shasum -a 256 "${DMG}" | cut -d' ' -f1)"
echo "==> DMG sha256: ${SHA256}"

echo "==> Tagging and pushing ${TAG}..."
git tag "${TAG}"
git push origin "${TAG}"

echo "==> Creating GitHub release..."
gh release create "${TAG}" "${DMG}" \
    --repo "${APP_REPO_SLUG}" \
    --title "GSD ${TAG}" \
    --generate-notes

echo "==> Bumping cask in ${TAP_REPO}..."
TAP_DIR="$(mktemp -d)"
trap 'rm -rf "${TAP_DIR}"' EXIT

git clone --quiet "https://github.com/${TAP_REPO}.git" "${TAP_DIR}"

# BSD sed on macOS needs the empty -i '' argument.
sed -i '' -E "s|^  version \".*\"$|  version \"${VERSION}\"|" "${TAP_DIR}/Casks/gsd.rb"
sed -i '' -E "s|^  sha256 \".*\"$|  sha256 \"${SHA256}\"|" "${TAP_DIR}/Casks/gsd.rb"

(
    cd "${TAP_DIR}"
    git -c user.name="$(git -C "${OLDPWD}" config user.name)" \
        -c user.email="$(git -C "${OLDPWD}" config user.email)" \
        commit -am "Bump gsd to ${VERSION}"
    git push origin HEAD
)

echo ""
echo "==> Released ${TAG}"
echo "    App release:  https://github.com/${APP_REPO_SLUG}/releases/tag/${TAG}"
echo "    Cask updated: https://github.com/${TAP_REPO}/blob/main/Casks/gsd.rb"
