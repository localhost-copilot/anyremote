#!/bin/zsh
# Builds the universal Release app, signs it with the stable local identity
# (scripts/signing-identity.sh) so privacy permissions survive updates, and
# zips it to build/dist/AnyRemote-<version>.zip.
#
#   scripts/release.sh            build, sign, zip
#   scripts/release.sh --install  also replace /Applications/AnyRemote.app and restart it
set -euo pipefail
cd "${0:A:h}/.."

VERSION=$(awk -F'"' '/MARKETING_VERSION: "/ { print $2; exit }' project.yml)
APP=build/dd-release/Build/Products/Release/AnyRemote.app
KEYCHAIN="$HOME/Library/Application Support/AnyRemoteSigning/signing.keychain-db"

xcodegen generate >/dev/null
xcodebuild -project AnyRemote.xcodeproj -scheme AnyRemote -configuration Release \
    -derivedDataPath build/dd-release CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -quiet build

IDENTITY=$(scripts/signing-identity.sh)
sign() {
    codesign --force --options runtime --timestamp=none --keychain "$KEYCHAIN" --sign "$IDENTITY" "$@"
}
# Inside out: the Dock helper and the microphone driver, then the app with
# its entitlements. Core Audio loads the driver signed with this identity.
sign "$APP/Contents/MacOS/AnyRemoteDockProxy"
sign "$APP/Contents/Resources/AnyRemote Microphone.driver"
sign --entitlements App/AnyRemote.entitlements "$APP"
codesign --verify --strict --deep "$APP"
echo "signed: $(codesign -dr - "$APP" 2>&1 | sed -n 's/^designated => //p')"

mkdir -p build/dist
rm -f "build/dist/AnyRemote-$VERSION.zip"
ditto -c -k --keepParent "$APP" "build/dist/AnyRemote-$VERSION.zip"
echo "zipped: build/dist/AnyRemote-$VERSION.zip"

if [[ "${1:-}" == "--install" ]]; then
    osascript -e 'tell application id "com.localhost-copilot.anyremote" to quit' 2>/dev/null || true
    # Quitting can wait on a confirmation or a viewer's session. Replacing the
    # bundle under a running copy makes `open` only activate that old copy,
    # and nothing starts again once it does quit.
    for _ in {1..120}; do pgrep -f /Applications/AnyRemote.app/Contents/MacOS >/dev/null || break; sleep 0.5; done
    if pgrep -f /Applications/AnyRemote.app/Contents/MacOS >/dev/null; then
        echo "AnyRemote is still running; quit it and run this again (build/dist has the zip)." >&2
        exit 1
    fi
    rm -rf /Applications/AnyRemote.app
    ditto "$APP" /Applications/AnyRemote.app
    open /Applications/AnyRemote.app
    echo "installed: /Applications/AnyRemote.app $VERSION"
fi
