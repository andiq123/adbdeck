<p align="center">
  <img src="ADBDeck/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="112" alt="ADB Deck icon">
</p>

<h1 align="center">ADB Deck</h1>

<p align="center">A native macOS command center for Android devices on your local network.</p>

<p align="center">
  <a href="https://github.com/andiq123/adbdeck/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/andiq123/adbdeck?style=flat-square"></a>
  <a href="https://github.com/andiq123/adbdeck/actions/workflows/ci.yml"><img alt="Build" src="https://img.shields.io/github/actions/workflow/status/andiq123/adbdeck/ci.yml?branch=main&style=flat-square&label=build"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square&logo=apple">
</p>

## One place for every Android screen

ADB Deck discovers ADB-enabled TVs, streaming boxes, phones, tablets, and car head units. It identifies familiar hardware, keeps active devices easy to reach, and turns wireless ADB into a focused Mac experience.

<table>
  <tr>
    <td width="50%"><img src="docs/icons/discover.svg" width="22" alt=""> <strong>Automatic discovery</strong><br><sub>Find and identify ADB devices across the local network.</sub></td>
    <td width="50%"><img src="docs/icons/apps.svg" width="22" alt=""> <strong>App control</strong><br><sub>Install, launch, inspect, label, clone, disable, and remove apps—including APKM packages—and keep a chosen Android TV launcher active without the Mac connected.</sub></td>
  </tr>
  <tr>
    <td><img src="docs/icons/files.svg" width="22" alt=""> <strong>File management</strong><br><sub>Browse, size, transfer, organize, and clean device files.</sub></td>
    <td><img src="docs/icons/activity.svg" width="22" alt=""> <strong>Device health</strong><br><sub>Monitor storage, app usage, CPU, and memory.</sub></td>
  </tr>
</table>

## Use it

1. [Download the latest DMG](https://github.com/andiq123/adbdeck/releases/latest).
2. Drag **ADB Deck** to **Applications**.
3. Enable ADB or wireless debugging on the Android device.
4. Open ADB Deck, select the device, and approve its connection prompt.

Requires macOS 14 or later. USB devices and emulators appear through the local ADB server; wireless devices must be reachable from the Mac.

### Connections and device compatibility

- **USB / emulator:** enable USB debugging, connect the device or start the emulator, then refresh. Approve the debugging prompt on the device.
- **Classic network ADB:** use Add Device with an IPv4 address, hostname, or `[IPv6]` address. The default port is 5555; append `:port` for a different port.
- **Wireless debugging:** use Add Device → Pair wirelessly with the pairing address, port, and six-digit code. After pairing, enter the **connection** address and port from the main Wireless debugging screen. The pairing and connection ports are different. See the [Android ADB guide](https://developer.android.com/tools/adb#connect-to-a-device-over-wi-fi).

Successful manual connections are remembered. Automatic discovery combines ADB’s USB/emulator list, wireless mDNS services, and a bounded scan of the first active Ethernet/Wi-Fi interface’s local `/24`. Use a manual address for other reachable subnets.

The same ADB tools work across phones, tablets, Android TV / Google TV, Fire TV, Wear OS, and Android Automotive when their firmware permits debugging. Feature availability depends on Android version, manufacturer restrictions, and permissions; recovery, sideload, and bootloader transports cannot use normal Android app controls. App management currently targets the primary Android user (user 0). Device families are not a guarantee that every vendor-specific function is available.

### Send files to a device

Open **Files**, choose a writable folder, then click **Upload Files** or drop files and folders from Finder. Uploads show progress and transfer speed, support cancellation, and keep existing files untouched.

Any file type is supported, including files over 4 GB, without loading the file into Mac memory. Available space and the destination filesystem still apply: FAT32 cannot hold a single file of 4 GiB or larger. Uploads are staged until complete; interrupted items are cleaned up when the device remains reachable.

## Build

Open `ADBDeck.xcodeproj` in Xcode, or run:

```sh
./scripts/package.sh
```

The app, ZIP, and DMG are written to `dist/`.

### Tests

```sh
xcodebuild -project ADBDeck.xcodeproj -scheme ADBDeck -destination 'platform=macOS' test
```

The suite covers transport and endpoint parsing, device identification, subprocess output/cancellation/timeouts, package formats, file safety, and device reports. The real-device upload test is opt-in via `TEST_RUNNER_ADBDECK_UPLOAD_SERIAL`; ordinary tests do not change a device.

### Automatic updates

ADB Deck uses [Sparkle](https://sparkle-project.org/) to check the latest stable GitHub release every six hours and download updates in the background. Use **ADB Deck → Check for Updates…** or the sidebar update button for an immediate check. Settings lets you turn automatic checking and background downloads on or off. Updates are installed on quit or through Sparkle’s installation dialog; requested relaunches wait for active device operations.

Both the feed and update archive are verified with Ed25519 signatures before extraction. Update checks do not send a system profile. The first release containing this updater must be installed manually by users of older versions.

#### Publishing an update

1. Increase **both** `CFBundleShortVersionString` and `CFBundleVersion` in `ADBDeck/Info.plist`. Sparkle compares the build number, so it must always increase.
2. Push a matching `v<version>` tag. The release workflow builds a universal Mac app, packages it, and signs `appcast.xml` with the repository’s `SPARKLE_PRIVATE_KEY` Actions secret.
3. The workflow uploads the ZIP, DMG, and signed feed to a draft, then publishes it as the latest release. The feed URL is `https://github.com/andiq123/adbdeck/releases/latest/download/appcast.xml`.

The signing secret is configured for this repository. Keep a secure backup of the private key; never commit it or replace the public key in shipped apps without a supported key-rotation plan. The local backup is `~/.config/adbdeck/sparkle-ed25519.key` (owner-only access). For local feed generation after packaging:

```sh
SPARKLE_PRIVATE_KEY_FILE="$HOME/.config/adbdeck/sparkle-ed25519.key" ./scripts/generate-appcast.sh
```

The feed becomes available when the first release using this workflow is published. The release workflow fails if its signing key is missing; it never publishes unsigned updates.
