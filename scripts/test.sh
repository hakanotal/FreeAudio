#!/bin/bash
# Run the pure-logic unit tests (Package.swift → FreeAudio/Core, Tests/FreeAudioCoreTests).
#
#   ./scripts/test.sh                 # all tests
#   ./scripts/test.sh --filter Volume # extra arguments go to `swift test`
#
# The Command Line Tools ship the Swift Testing macro plugin in a `testing` subfolder that
# `swift test` doesn't search on its own, so point the compiler at it when it's there.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PLUGIN_ARGS=()
TESTING_PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$TESTING_PLUGINS" ]; then
  PLUGIN_ARGS=(-Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS")
fi

swift test "${PLUGIN_ARGS[@]}" "$@"
