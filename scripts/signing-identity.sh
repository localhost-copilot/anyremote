#!/bin/zsh
# Creates (once) and unlocks a local code-signing identity for AnyRemote, kept
# in its own keychain so builds can sign without keychain prompts.
#
# Privacy permissions (Screen Recording, Accessibility) are keyed by the app's
# designated requirement. Ad-hoc signatures change with every build, so every
# update loses them; a stable certificate keeps them across updates.
#
# Prints the identity's SHA-1 hash. The private key never leaves this Mac.
set -euo pipefail

DIR="$HOME/Library/Application Support/AnyRemoteSigning"
KEYCHAIN="$DIR/signing.keychain-db"
PASSWORD_FILE="$DIR/keychain-password"
NAME="AnyRemote Local Signing"

if [[ ! -f "$KEYCHAIN" ]]; then
    mkdir -p "$DIR"
    chmod 700 "$DIR"
    umask 077
    openssl rand -hex 24 > "$PASSWORD_FILE"
    PASSWORD=$(<"$PASSWORD_FILE")
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
    cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$WORK/cert.cnf" \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
    openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
        -passout "pass:$PASSWORD" -out "$WORK/identity.p12" 2>/dev/null
    security create-keychain -p "$PASSWORD" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"   # no auto-lock timeout
    security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
fi

security unlock-keychain -p "$(<"$PASSWORD_FILE")" "$KEYCHAIN"
security find-certificate -c "$NAME" -Z "$KEYCHAIN" | awk '/SHA-1 hash:/ { print $3; exit }'
