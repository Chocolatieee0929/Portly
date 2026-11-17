#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  printf '%s\n' '请安装并完成 Xcode 首次启动，然后重试。' >&2
  exit 1
fi
xcodebuild -quiet -project Portly.xcodeproj -scheme Portly -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$PWD/build/DerivedData" \
  CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache" build
# Keep the existing convenient output path. The entire signed bundle comes from Xcode.
ditto build/DerivedData/Build/Products/Release/Portly.app build/Portly.app
printf 'Built: %s\n' "$PWD/build/Portly.app"
