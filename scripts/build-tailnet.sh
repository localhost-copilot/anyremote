#!/bin/zsh
# Builds Tailnet/ (the embedded Tailscale node, in Go) as a static library
# for the architectures in $ARCHS (Xcode's; this Mac's by default) and puts
# libanyremotetailnet.a into the directory given (Xcode: $BUILT_PRODUCTS_DIR),
# where the app links it. Each architecture's build is kept under
# build/tailnet/<arch> and redone only when the Go sources, go.mod/go.sum,
# the Go version or the deployment target change.
#
# Needs Go (https://go.dev/dl, `brew install go`); $GO may name the binary.
# Go fetches the toolchain go.mod asks for, and the modules, on first use.
#
#   scripts/build-tailnet.sh <output directory>
set -euo pipefail
ROOT=${0:A:h:h}
OUT=${1:?usage: build-tailnet.sh <output directory>}
ARCHS=(${=${ARCHS:-$(uname -m)}})
DEPLOYMENT=${MACOSX_DEPLOYMENT_TARGET:-15.0}
CACHE=$ROOT/build/tailnet
HEADER=$ROOT/Packages/AnyRemoteKit/Sources/CAnyRemoteTailnet/include/anyremote_tailnet.h

# Features of tailscaled a node inside AnyRemote has no use for. Leaving
# out logtail also keeps it from uploading logs to Tailscale.
OMIT=(aws bird capture cli completion colorable cliconndiag kube ssh taildrop tap tpm drive webclient
      wakeonlan synology systray relayserver appconnectors advertiseexitnode advertiseroutes iptables
      networkmanager resolved dbus sdnotify syslog doctor clientupdate flashappliance identityfederation
      netlog logtail debugeventbus debugportmapper portlist qrcodes cloud linuxdnsfight webbrowser conn25
      androiddns favorites serviceclientprefs)
TAGS=${(j:,:)${OMIT/#/ts_omit_}}

find_go() {
    [[ -n ${GO:-} ]] && { print -r -- $GO; return }
    local candidate
    for candidate in "$(command -v go 2>/dev/null || true)" /opt/homebrew/bin/go /usr/local/go/bin/go \
        /usr/local/bin/go $HOME/.local/share/mise/installs/go/*/bin/go(NOn); do
        [[ -n $candidate && -x $candidate ]] && { print -r -- $candidate; return }
    done
    return 1
}
GO_BIN=$(find_go) || {
    echo "error: building AnyRemote needs Go for its embedded Tailscale node (Tailnet/): install it (brew install go) or set GO" >&2
    exit 1
}

# Go's own version, not the binary's: an older Go switches to the one go.mod asks for.
GO_VERSION=$(cd $ROOT/Tailnet && $GO_BIN env GOVERSION)
SOURCES=$(cat $ROOT/Tailnet/*.go(.) $ROOT/Tailnet/go.mod $ROOT/Tailnet/go.sum $HEADER | shasum -a 256 | cut -c1-16)

libraries=()
for arch in $ARCHS; do
    case $arch in
        arm64) goarch=arm64 ;;
        x86_64) goarch=amd64 ;;
        *) echo "error: no Go architecture for $arch" >&2; exit 1 ;;
    esac
    dir=$CACHE/$arch
    stamp="$SOURCES $GO_VERSION $DEPLOYMENT $TAGS"
    if [[ ! -f $dir/libanyremotetailnet.a || "$(cat $dir/stamp 2>/dev/null)" != "$stamp" ]]; then
        echo "Building the embedded Tailscale node for $arch ($GO_VERSION)"
        rm -rf $dir
        mkdir -p $dir
        (cd $ROOT/Tailnet && env GOOS=darwin GOARCH=$goarch CGO_ENABLED=1 CC="xcrun clang -arch $arch" \
            MACOSX_DEPLOYMENT_TARGET=$DEPLOYMENT CGO_CFLAGS="-O2 -mmacosx-version-min=$DEPLOYMENT" \
            CGO_LDFLAGS="-mmacosx-version-min=$DEPLOYMENT" \
            $GO_BIN build -trimpath -buildmode=c-archive -tags "$TAGS" -ldflags "-s -w" \
            -o $dir/libanyremotetailnet.a .)
        # The header the Swift side uses must declare what cgo exported: C
        # rejects a second declaration with other types.
        xcrun clang -arch $arch -fsyntax-only -x c - <<EOF
#include "$dir/libanyremotetailnet.h"
#include "$HEADER"
EOF
        # And the library links with the frameworks AnyRemoteTailnet names.
        xcrun clang -arch $arch -mmacosx-version-min=$DEPLOYMENT -x c - -x none $dir/libanyremotetailnet.a \
            -framework CoreFoundation -framework Security -framework IOKit -framework SystemConfiguration \
            -lresolv -o $dir/link-check <<EOF
#include "$HEADER"
int main(void) { ar_tailnet_stop(); return 0; }
EOF
        rm -f $dir/link-check
        print -r -- $stamp > $dir/stamp
    fi
    libraries+=($dir/libanyremotetailnet.a)
done

mkdir -p $OUT
if (( ${#libraries} == 1 )); then
    cp -f $libraries[1] $OUT/libanyremotetailnet.a
else
    lipo -create $libraries -output $OUT/libanyremotetailnet.a
fi
