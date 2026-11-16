#!/bin/zsh
# Checks that the version in project.yml has its release notes.
set -euo pipefail
cd "${0:A:h}/.."
VERSION=$(awk -F'"' '/MARKETING_VERSION: "/ { print $2; exit }' project.yml)
[[ -f docs/releases/$VERSION.md ]] || { echo "error: docs/releases/$VERSION.md is missing" >&2; exit 1; }
python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert "en" in d and all(isinstance(v, list) and all(isinstance(s, str) for s in v) for v in d.values())
' "docs/releases/$VERSION.json" || { echo "error: docs/releases/$VERSION.json needs {\"en\": [...], ...}" >&2; exit 1; }
