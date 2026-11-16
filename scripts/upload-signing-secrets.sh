#!/bin/zsh
# Copies the release signing identity (scripts/signing-identity.sh) into the
# secrets of the GitHub "release" environment, for the Release workflow:
# SIGNING_P12 (base64 PKCS#12) and SIGNING_P12_PASSWORD (a fresh random one).
# Nothing secret is printed or left on disk. macOS's prompt to export the
# private key is answered by the script. GH = the GitHub CLI to use.
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
# It is only in a file, so the prompt is answered from here: activated (only
# then does it show up in Accessibility), moved to the main screen (it can
# open on a display nobody looks at, such as AnyRemote's virtual display),
# filled in and allowed. This needs Accessibility for the terminal.
answer_prompt() {
    osascript -l JavaScript - "$DIR/keychain-password" <<'JS' 2>&1
ObjC.import("AppKit")
function run(argv) {
    const agent = Application("System Events").processes.byName("SecurityAgent")
    if (!agent.exists()) return "waiting"
    $.NSRunningApplication.runningApplicationWithProcessIdentifier(agent.unixId()).activateWithOptions(0)
    delay(0.3)
    if (agent.windows.length == 0) return "waiting"
    const window = agent.windows[0]
    const screen = $.NSScreen.screens.objectAtIndex(0).frame
    const size = window.size()
    window.position = [Math.round((screen.size.width - size[0]) / 2), Math.round(screen.size.height / 3)]
    if (window.textFields.length == 0) return "waiting"
    const password = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null))
    window.textFields[0].value = password.trim()
    window.buttons.byName("Allow").click()
    return "allowed"
}
JS
}
echo "Answering macOS's prompt to export the key…"
security export -k "$KEYCHAIN" -t identities -f pkcs12 -P "$PASSWORD" -o "$WORK/identity.p12" &
EXPORT=$!
# An interrupted run mustn't leave the export waiting for a prompt.
trap 'kill $EXPORT 2>/dev/null; rm -rf "$WORK"' EXIT
STATE=waiting
for _ in {1..40}; do
    kill -0 $EXPORT 2>/dev/null || break
    [[ $STATE == allowed ]] || STATE=$(answer_prompt)
    sleep 0.5
done
if kill -0 $EXPORT 2>/dev/null; then
    kill $EXPORT
    echo "error: couldn't answer the prompt ($STATE). Does the terminal have Accessibility?" >&2
    exit 1
fi
wait $EXPORT || { echo "error: the export was refused" >&2; exit 1; }

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
