#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPER_DIR_PATH="$(xcode-select -p)"
TEST_PLUGIN="$DEVELOPER_DIR_PATH/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$TEST_PLUGIN" ]; then
  swift test --package-path "$REPO_ROOT/native" -Xswiftc -load-plugin-library -Xswiftc "$TEST_PLUGIN" "$@"
else
  swift test --package-path "$REPO_ROOT/native" "$@"
fi
