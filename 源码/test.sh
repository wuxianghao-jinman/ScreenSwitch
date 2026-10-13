#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd)"
scratch_dir="${SCREENSWITCH_BUILD_DIR:-${TMPDIR:-/tmp}/ScreenSwitch-build-${UID}}"
mkdir -p "$scratch_dir/module-cache"
xcrun swiftc -swift-version 5 -warnings-as-errors \
  -module-cache-path "$scratch_dir/module-cache" \
  "$source_dir/DisplayCore.swift" "$source_dir/NativeLayout.swift" "$source_dir/Tests.swift" \
  -framework CoreGraphics -framework ColorSync -o "$scratch_dir/SafetyTests"
"$scratch_dir/SafetyTests"
