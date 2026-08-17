#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_root/ADBDeck/Info.plist")"
product="ADB Deck"
build_root="$project_root/build-release"
dist="$project_root/dist"
app="$dist/$product.app"
identity="${SIGN_IDENTITY:--}"

cd "$project_root"
xcodegen generate
xcodebuild -project ADBDeck.xcodeproj -scheme ADBDeck -configuration Release \
  -derivedDataPath "$build_root" CODE_SIGNING_ALLOWED=NO build

mkdir -p "$dist"
for target in "$app" "$dist/ADB-Deck-$version.zip" "$dist/ADB-Deck-$version.dmg"; do
  [[ -e "$target" ]] && find "$target" -depth -delete
done
ditto "$build_root/Build/Products/Release/$product.app" "$app"

if [[ "$identity" == "-" ]]; then
  codesign --force --sign - "$app/Contents/Resources/platform-tools/adb"
  codesign --force --deep --sign - "$app"
else
  codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/Resources/platform-tools/adb"
  codesign --force --deep --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"

ditto -c -k --sequesterRsrc --keepParent "$app" "$dist/ADB-Deck-$version.zip"
staging="$(mktemp -d)"
ditto "$app" "$staging/$product.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "$product" -srcfolder "$staging" -ov -format UDZO "$dist/ADB-Deck-$version.dmg"
find "$staging" -depth -delete
shasum -a 256 "$dist/ADB-Deck-$version.zip" "$dist/ADB-Deck-$version.dmg"
