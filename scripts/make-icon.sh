#!/bin/zsh
# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift (no Xcode needed).
# The .icns is committed, so building the app does not need to run this.
set -euo pipefail
cd "${0:A:h}/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O scripts/make-icon.swift -o "$WORK/make-icon"
"$WORK/make-icon" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
echo "Wrote $PWD/Resources/AppIcon.icns"
