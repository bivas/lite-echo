#!/usr/bin/env bash
# Runs the Swift tests with the Command Line Tools only (no Xcode).
# The default build backend does not load the swift-testing macro plugin on its own,
# so its folder is passed explicitly. Extra arguments go to `swift test`, e.g.
#   scripts/test-app.sh --filter LiteEchoQueueTests
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV="$(xcode-select -p)"
PLUGINS="$DEV/usr/lib/swift/host/plugins/testing"
[[ -d "$PLUGINS" ]] || PLUGINS="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing"
exec swift test --package-path "$ROOT/app" -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
