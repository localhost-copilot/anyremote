#!/bin/zsh
# Publishes the version in project.yml as a GitHub release, with the zip and
# the update manifest the app reads (AnyRemote-update.json).
#
#   scripts/publish-release.sh            check, build, sign, write the manifest; publish nothing
#   scripts/publish-release.sh --publish  then tag the release commit, push the tag, create the release
#
# Needs docs/releases/<version>.md (the release page, English) and
# docs/releases/<version>.json (the short in-app notes:
# {"en": ["…"], "zh-Hans": ["…"]}). Set GH to the GitHub CLI to use.
set -euo pipefail
cd "${0:A:h}/.."

GH=${GH:-gh}
VERSION=$(awk -F'"' '/MARKETING_VERSION: "/ { print $2; exit }' project.yml)
PROTOCOL=$(sed -n 's/^public let anyRemoteProtocolVersion: UInt16 = \([0-9]*\).*/\1/p' \
    Packages/AnyRemoteKit/Sources/AnyRemoteWire/ControlMessage.swift)
MINIMUM_SYSTEM=$(awk -F'"' '/macOS: "/ { print $2; exit }' project.yml)
TAG="v$VERSION"
NOTES="docs/releases/$VERSION.md"
SUMMARY="docs/releases/$VERSION.json"
SLUG=$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
ZIP="build/dist/AnyRemote-$VERSION.zip"
MANIFEST="build/dist/AnyRemote-update.json"
BODY="build/dist/release-notes-$VERSION.md"

fail() { echo "error: $*" >&2; exit 1; }

[[ -f $NOTES ]] || fail "$NOTES is missing"
[[ -f $SUMMARY ]] || fail "$SUMMARY is missing"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "en" in d and all(isinstance(v, list) for v in d.values())' \
    "$SUMMARY" || fail "$SUMMARY needs {\"en\": [...], ...}"
[[ -z $(git status --porcelain) ]] || fail "the working tree has changes; commit them first"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG exists already"
git fetch -q origin
git merge-base --is-ancestor HEAD origin/main || fail "push this commit to origin/main first"
git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 && fail "tag $TAG exists on origin"

scripts/release.sh

SIZE=$(stat -f %z "$ZIP")
SHA=$(shasum -a 256 "$ZIP" | awk '{ print $1 }')
python3 -I - "$SUMMARY" "$MANIFEST" <<PY
import json, sys
notes = json.load(open(sys.argv[1]))
manifest = {
    "version": "$VERSION",
    "protocolVersion": $PROTOCOL,
    "minimumSystemVersion": "$MINIMUM_SYSTEM",
    "url": "https://github.com/$SLUG/releases/download/$TAG/AnyRemote-$VERSION.zip",
    "size": $SIZE,
    "sha256": "$SHA",
    "notes": notes,
    "releaseURL": "https://github.com/$SLUG/releases/tag/$TAG",
}
json.dump(manifest, open(sys.argv[2], "w"), ensure_ascii=False, indent=2)
PY
{ cat "$NOTES"; echo; echo "SHA-256 of \`AnyRemote-$VERSION.zip\`: \`$SHA\`"; } > "$BODY"

echo "release:  $TAG (protocol v$PROTOCOL) from $(git rev-parse --short HEAD)"
echo "assets:   $ZIP ($SIZE bytes), $MANIFEST"
echo "notes:    $BODY"

if [[ "${1:-}" != "--publish" ]]; then
    echo "dry run: nothing published (pass --publish)"
    exit 0
fi

git tag -a "$TAG" -m "AnyRemote $VERSION"
git push origin "$TAG"
"$GH" release create "$TAG" "$ZIP" "$MANIFEST" --verify-tag --latest \
    --title "AnyRemote $VERSION" --notes-file "$BODY"
echo "published: https://github.com/$SLUG/releases/tag/$TAG"
