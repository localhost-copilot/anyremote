#!/bin/zsh
# Regenerates the app icons (App/Assets.xcassets) from scripts/make-icon.swift:
# AppIcon (blue) for release builds, AppIcon-Dev (orange) for debug builds.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
catalog=App/Assets.xcassets
mkdir -p "$catalog"
print '{ "info" : { "author" : "xcode", "version" : 1 } }' > "$catalog/Contents.json"

for variant set in release AppIcon dev AppIcon-Dev; do
    swift scripts/make-icon.swift "$work/$variant.png" "$variant"
    dir="$catalog/$set.appiconset"
    rm -rf "$dir"; mkdir -p "$dir"
    images=()
    for points in 16 32 128 256 512; do
        for scale in 1 2; do
            pixels=$((points * scale))
            name="icon_${points}x${points}@${scale}x.png"
            sips -z $pixels $pixels "$work/$variant.png" --out "$dir/$name" >/dev/null
            images+=("{ \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${points}x${points}\", \"filename\" : \"$name\" }")
        done
    done
    print "{ \"images\" : [\n    ${(j:,\n    :)images}\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}" > "$dir/Contents.json"
    echo "wrote $dir"
done
