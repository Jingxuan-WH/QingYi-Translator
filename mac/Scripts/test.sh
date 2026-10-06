#!/bin/bash
# Runs the unit tests. With only the Command Line Tools installed, Swift Testing lives outside the toolchain's
# default search paths, so the framework and its runtime library are pointed to explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
FLAGS=()
if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    CLT="$(xcode-select -p)"
    FRAMEWORKS="$CLT/Library/Developer/Frameworks"
    RUNTIME="$CLT/Library/Developer/usr/lib"
    if [[ -d "$FRAMEWORKS/Testing.framework" ]]; then
        FLAGS=(-Xswiftc "-F$FRAMEWORKS" -Xlinker "-F$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$RUNTIME")
    fi
fi
swift test ${FLAGS[@]+"${FLAGS[@]}"} "$@"
