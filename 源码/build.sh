#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd)"
deliverable_dir="$(dirname "$source_dir")"
app_dir="$deliverable_dir/屏幕开关.app"
scratch_dir="${SCREENSWITCH_BUILD_DIR:-${TMPDIR:-/tmp}/ScreenSwitch-build-${UID}}"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$scratch_dir/module-cache"
xcrun swiftc -swift-version 5 -O -warnings-as-errors \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$scratch_dir/module-cache" \
  "$source_dir/DisplayCore.swift" "$source_dir/NativeLayout.swift" "$source_dir/main.swift" \
  -framework AppKit -framework Carbon -framework CoreGraphics -framework ColorSync \
  -o "$app_dir/Contents/MacOS/ScreenSwitch"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>屏幕开关</string>
<key>CFBundleDisplayName</key><string>屏幕开关</string>
<key>CFBundleIdentifier</key><string>local.wuxianghao.ScreenSwitch</string>
<key>CFBundleExecutable</key><string>ScreenSwitch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>个人工具，由 Codex 辅助开发。</string>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
chmod +x "$deliverable_dir/恢复本机屏幕.command"
printf '构建完成：%s\n' "$app_dir"
