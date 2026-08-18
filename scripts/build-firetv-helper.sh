#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
build_tools="$sdk/build-tools/36.0.0"
android_jar="$sdk/platforms/android-36/android.jar"
source="$project_root/FireTVHelper"
build="$project_root/build-firetv-helper"
output="$project_root/ADBDeck/Resources/ADBDeckFireTVHelper.apk"
keystore="$project_root/FireTVHelper/debug.keystore"

[[ -f "$android_jar" ]] || { print -u2 "Android SDK platform 36 is required"; exit 1; }
mkdir -p "$build/classes" "$build/dex" "${output:h}"
find "$build" -mindepth 1 -depth -delete
mkdir -p "$build/classes" "$build/dex"

"$build_tools/aapt2" compile --dir "$source/res" -o "$build/resources.zip"
"$build_tools/aapt2" link -o "$build/helper-unsigned.apk" -I "$android_jar" --manifest "$source/AndroidManifest.xml" "$build/resources.zip"
javac -source 8 -target 8 -bootclasspath "$android_jar" -d "$build/classes" "$source/src/com/andi/adbdeck/helper/HomeRedirectService.java"
"$build_tools/d8" --lib "$android_jar" --min-api 26 --output "$build/dex" "$build/classes/com/andi/adbdeck/helper/HomeRedirectService.class"
(cd "$build/dex" && zip -q -u "$build/helper-unsigned.apk" classes.dex)
[[ -f "$keystore" ]] || keytool -genkeypair -keystore "$keystore" -storepass android -alias androiddebugkey -keypass android -dname "CN=ADB Deck Helper" -keyalg RSA -validity 10000 >/dev/null
"$build_tools/apksigner" sign --ks "$keystore" --ks-pass pass:android --key-pass pass:android --out "$output" "$build/helper-unsigned.apk"
"$build_tools/apksigner" verify "$output"
print "$output"
