#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_root/ADBDeck/Info.plist")"
artifacts="${1:-$project_root/dist}"
archive="$artifacts/ADB-Deck-$version.zip"
[[ -f "$archive" ]] || { print -u2 "Run scripts/package.sh first."; exit 1; }
[[ -n "${SPARKLE_PRIVATE_KEY:-}${SPARKLE_PRIVATE_KEY_FILE:-}" ]] || {
  print -u2 "Set SPARKLE_PRIVATE_KEY (CI) or SPARKLE_PRIVATE_KEY_FILE (local signing)."
  exit 1
}

# Pin the signing tools as well as the app's Swift package dependency.
tools_dir="$project_root/build/sparkle/2.10.0"
mkdir -p "$tools_dir"
if [[ ! -x "$tools_dir/bin/generate_appcast" ]]; then
  curl --fail --location --retry 3 --connect-timeout 15 --max-time 180 \
    'https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz' \
    -o "$tools_dir/Sparkle.tar.xz"
  print 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c  Sparkle.tar.xz' |
    (cd "$tools_dir" && shasum -a 256 -c -)
  tar -xJf "$tools_dir/Sparkle.tar.xz" -C "$tools_dir"
fi

# Only this version's ZIP goes into the feed; never accidentally publish stale dist files.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$archive" "$staging/${archive:t}"
arguments=(
  --download-url-prefix "https://github.com/andiq123/adbdeck/releases/download/v$version/"
  --link "https://github.com/andiq123/adbdeck/releases/tag/v$version"
  --maximum-deltas 0
  "$staging"
)
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  "$tools_dir/bin/generate_appcast" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "${arguments[@]}"
else
  print -rn -- "$SPARKLE_PRIVATE_KEY" | "$tools_dir/bin/generate_appcast" --ed-key-file - "${arguments[@]}"
fi
[[ -s "$staging/appcast.xml" ]] || { print -u2 "No signed appcast was generated."; exit 1; }
ditto "$staging/appcast.xml" "$artifacts/appcast.xml"
