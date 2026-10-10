#!/bin/zsh
# Runs the unit tests. The explicit plugin path works around Command Line Tools'
# SwiftPM occasionally not finding the Swift Testing macros on incremental builds.
set -euo pipefail
cd "${0:A:h}/.."
PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
