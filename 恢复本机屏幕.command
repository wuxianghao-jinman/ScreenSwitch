#!/bin/bash
set -euo pipefail
tool_dir="$(cd "$(dirname "$0")" && pwd)"
"$tool_dir/屏幕开关.app/Contents/MacOS/ScreenSwitch" --restore
