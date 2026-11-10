#!/bin/bash
# Single test command for the app. Plain `swift test` fails on a Command-Line-Tools-only
# Mac ("plugin for module 'TestingMacros' not found"), so add the plugin path when present.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugins=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
extra=()
if [ -d "$plugins" ]; then
    extra=(-Xswiftc -plugin-path -Xswiftc "$plugins")
fi
exec swift test --package-path "$here" ${extra[@]+"${extra[@]}"} "$@"
