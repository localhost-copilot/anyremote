#!/bin/zsh
# Builds everything a GitHub release carries for the version in project.yml:
#   build/dist/AnyRemote-<version>.zip        the signed app (scripts/release.sh)
#   build/dist/AnyRemote-update.json          the manifest installed copies read
#   build/dist/release-notes-<version>.md     the release page
# from docs/releases/<version>.md and docs/releases/<version>.json. Run by
# the Release workflow, and by scripts/publish-release.sh --local.
set -euo pipefail
cd "${0:A:h}/.."

VERSION=$(awk -F'"' '/MARKETING_VERSION: "/ { print $2; exit }' project.yml)
PROTOCOL=$(sed -n 's/^public let anyRemoteProtocolVersion: UInt16 = \([0-9]*\).*/\1/p' \
    Packages/AnyRemoteKit/Sources/AnyRemoteWire/ControlMessage.swift)
MINIMUM_SYSTEM=$(awk -F'"' '/macOS: "/ { print $2; exit }' project.yml)
TAG="v$VERSION"
NOTES="docs/releases/$VERSION.md"
SUMMARY="docs/releases/$VERSION.json"
SLUG=${GITHUB_REPOSITORY:-$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')}
ZIP="build/dist/AnyRemote-$VERSION.zip"
MANIFEST="build/dist/AnyRemote-update.json"
BODY="build/dist/release-notes-$VERSION.md"

scripts/check-release-notes.sh
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
echo "assets: $ZIP ($SIZE bytes), $MANIFEST, $BODY"
