#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -x "$REPO_ROOT/build/Aside.app/Contents/MacOS/Aside" ] || [ "${1:-}" = "--build" ]; then
  "$REPO_ROOT/scripts/build-macos.sh"
fi
open "$REPO_ROOT/build/Aside.app"
