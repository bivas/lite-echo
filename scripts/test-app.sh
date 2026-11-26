#!/usr/bin/env bash
# Runs the Swift tests.
# With the Command Line Tools only (no Xcode) the default build backend does not load the
# swift-testing macro plugin on its own, so its folder is passed explicitly. With full Xcode
# (e.g. CI runners) swift-testing works out of the box and no extra flag is used.
# Extra arguments go to `swift test`, e.g.
#   scripts/test-app.sh --filter LiteEchoQueueTests
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV="$(xcode-select -p)"
FLAGS=()
if [[ "$DEV" == */CommandLineTools* ]]; then
  PLUGINS="$DEV/usr/lib/swift/host/plugins/testing"
  [[ -d "$PLUGINS" ]] || PLUGINS="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing"
  if [[ -d "$PLUGINS" ]]; then
    FLAGS=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")
  fi
fi
exec swift test --package-path "$ROOT/app" ${FLAGS[@]+"${FLAGS[@]}"} "$@"
