#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

bash build.sh
codesign --verify --deep --strict build/Portly.app

package_stage=$(mktemp -d "$PWD/build/dmg-stage.XXXXXX")
trap 'rm -rf "$package_stage"' EXIT
mkdir "$package_stage/contents"
ditto build/Portly.app "$package_stage/contents/Portly.app"
ln -s /Applications "$package_stage/contents/Applications"
cp Resources/Portly.icns "$package_stage/contents/.VolumeIcon.icns"
SetFile -a C "$package_stage/contents"
# Build the filesystem without attaching a temporary disk device, then compress it.
hdiutil makehybrid -hfs -hfs-volume-name Portly \
  -hfs-openfolder "$package_stage/contents" \
  -o "$package_stage/Portly-raw.dmg" "$package_stage/contents"
hdiutil convert "$package_stage/Portly-raw.dmg" -format UDZO -ov -o build/Portly.dmg
hdiutil verify build/Portly.dmg
mkdir -p build/tools
xcrun swiftc -module-cache-path "$PWD/build/module-cache" \
  scripts/set-dmg-icon.swift -o build/tools/set-dmg-icon
build/tools/set-dmg-icon "$PWD/Resources/Portly.icns" "$PWD/build/Portly.dmg"
printf 'Packaged: %s\n' "$PWD/build/Portly.dmg"
