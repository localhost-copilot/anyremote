#!/bin/zsh
# Releases the version in project.yml.
#
#   scripts/publish-release.sh          check, then tag the release commit and push the tag;
#                                       the Release workflow builds, signs and publishes it
#                                       once approved in the "release" environment
#   scripts/publish-release.sh --local  build, sign and publish from this Mac instead
#                                       (needs the signing identity here; GH = GitHub CLI)
set -euo pipefail
cd "${0:A:h}/.."

GH=${GH:-gh}
VERSION=$(awk -F'"' '/MARKETING_VERSION: "/ { print $2; exit }' project.yml)
TAG="v$VERSION"
fail() { echo "error: $*" >&2; exit 1; }

scripts/check-release-notes.sh
[[ -z $(git status --porcelain) ]] || fail "the working tree has changes; commit them first"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG exists already"
git fetch -q origin
git merge-base --is-ancestor HEAD origin/main || fail "push this commit to origin/main first"
git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 && fail "tag $TAG exists on origin"

if [[ "${1:-}" == "--local" ]]; then
    scripts/release-assets.sh
fi

git tag -a "$TAG" -m "AnyRemote $VERSION"
git push origin "$TAG"

if [[ "${1:-}" == "--local" ]]; then
    "$GH" release create "$TAG" "build/dist/AnyRemote-$VERSION.zip" build/dist/AnyRemote-update.json \
        --verify-tag --latest --title "AnyRemote $VERSION" --notes-file "build/dist/release-notes-$VERSION.md"
else
    echo "pushed $TAG: approve the Release workflow's deployment on GitHub to publish it"
fi
