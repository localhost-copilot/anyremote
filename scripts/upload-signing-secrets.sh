#!/bin/zsh
# Copies the release signing identity (scripts/signing-identity.sh) into the
# secrets of the GitHub "release" environment, for the Release workflow:
# SIGNING_P12 (base64 PKCS#12) and SIGNING_P12_PASSWORD (a fresh random one).
# Nothing secret is printed or left on disk. macOS may ask to allow the
# export of the private key. GH = the GitHub CLI to use.
set -euo pipefail
cd "${0:A:h}/.."

GH=${GH:-gh}
DIR="$HOME/Library/Application Support/AnyRemoteSigning"
KEYCHAIN="$DIR/signing.keychain-db"
security unlock-keychain -p "$(<"$DIR/keychain-password")" "$KEYCHAIN"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"
PASSWORD=$(openssl rand -hex 24)
# macOS asks for the signing keychain's password before letting the key go.
# It is only in a file, so it goes on the clipboard, marked concealed (so
# clipboard sharing and history skip it), and is cleared afterwards.
clipboard() {
    osascript -l JavaScript - "$@" <<'JS' >/dev/null
ObjC.import("AppKit")
function run(argv) {
    const board = $.NSPasteboard.generalPasteboard
    board.clearContents
    if (argv.length == 0) return
    const text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null)
    board.declareTypesOwner($(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]), null)
    board.setStringForType(text.stringByTrimmingCharactersInSet($.NSCharacterSet.whitespaceAndNewlineCharacterSet),
                           "public.utf8-plain-text")
    board.setStringForType("", "org.nspasteboard.ConcealedType")
}
JS
}
trap 'clipboard; rm -rf "$WORK"' EXIT
clipboard "$DIR/keychain-password"
echo "macOS now asks to let “security” export the key: paste the password (⌘V), then click Allow."
security export -k "$KEYCHAIN" -t identities -f pkcs12 -P "$PASSWORD" -o "$WORK/identity.p12"
clipboard

# The identity that goes up must be the one releases are checked against.
CHECK="$WORK/check.keychain-db"
security create-keychain -p check "$CHECK"
security import "$WORK/identity.p12" -k "$CHECK" -P "$PASSWORD" >/dev/null
HASH=$(security find-certificate -a -Z "$CHECK" | awk '/SHA-1 hash:/ { print tolower($3); exit }')
security delete-keychain "$CHECK"
grep -q "H\"$HASH\"" scripts/designated-requirement.txt || { echo "error: this identity isn't the release identity" >&2; exit 1; }

base64 -i "$WORK/identity.p12" | "$GH" secret set SIGNING_P12 --env release
printf %s "$PASSWORD" | "$GH" secret set SIGNING_P12_PASSWORD --env release
echo "uploaded the signing identity (certificate $HASH) to the release environment"
