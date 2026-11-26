#!/usr/bin/env bash
# Renders the README screenshots of the real app UI, offscreen (no screen recording needed).
# Output: docs/screenshots/*.png. Uses only temp data; never starts the engine or reads the
# real settings, queue or Keychain.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT/app" --product LiteEchoSnapshots
BIN="$(swift build --package-path "$ROOT/app" --show-bin-path)/LiteEchoSnapshots"
mkdir -p "$ROOT/docs/screenshots"
exec "$BIN" "$ROOT/docs/screenshots" "$@"
