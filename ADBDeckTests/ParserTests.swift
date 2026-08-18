import XCTest
@testable import ADBDeck

final class ParserTests: XCTestCase {
    func testARPParserIgnoresIncompleteEntries() {
        let output = """
        ? (192.168.1.50) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]
        ? (192.168.1.51) at (incomplete) on en0 ifscope [ethernet]
        ? (192.168.1.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
        mdns.mcast.net (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]
        """
        XCTAssertEqual(NetworkDiscovery.parseARP(output), ["192.168.1.50": "aa:bb:cc:dd:ee:ff"])
    }

    func testConnectedIdentifiedDevicesSortFirst() {
        let generic = AndroidDevice(id: "192.168.1.1", name: "Router", manufacturer: "Unknown", model: "Unknown", adbState: .disabled, isAndroidLikely: false, hasCast: false)
        let cast = AndroidDevice(id: "192.168.1.20", name: "Mi TV", manufacturer: "Xiaomi", model: "TV", adbState: .disabled, isAndroidLikely: true, hasCast: true)
        let connected = AndroidDevice(id: "192.168.1.50", name: "Fire TV", manufacturer: "Amazon", model: "AFTKRT", adbState: .connected, isAndroidLikely: true, hasCast: false)
        XCTAssertEqual([generic, cast, connected].sorted(by: AndroidDevice.sidebarOrder).map(\.id), [connected.id, cast.id, generic.id])
    }

    func testADBProgressAndIconEstimation() {
        XCTAssertEqual(ADBProgress.fraction(in: "[ 42%] pushing base.apk"), 0.42)
        XCTAssertEqual(ADBProgress.fraction(in: "[ 12%] pushing base.apk\r[ 87%] pushing base.apk"), 0.87)
        XCTAssertEqual(DeviceApp(packageName: "com.netflix.ninja", isSystem: false).symbol, "play.rectangle.fill")
        XCTAssertTrue(ADBClient.needsServerRestart("failed to connect: No route to host"))
        XCTAssertFalse(ADBClient.needsServerRestart("authentication rejected"))
    }

    func testStreamerTypeLabels() {
        let fire = AndroidDevice(id: "1", name: "AFTKRT", manufacturer: "Amazon", model: "AFTKRT", adbState: .connected, isAndroidLikely: true, hasCast: false)
        let onn = AndroidDevice(id: "2", name: "Living Room", manufacturer: "onn.", model: "onn. 4K Plus Streami", adbState: .disabled, isAndroidLikely: true, hasCast: true)
        let xiaomi = AndroidDevice(id: "3", name: "Mi TV Stick", manufacturer: "Xiaomi", model: "Mi TV Stick", adbState: .disabled, isAndroidLikely: true, hasCast: true)
        XCTAssertEqual([fire.typeLabel, onn.typeLabel, xiaomi.typeLabel], ["Fire TV", "onn. 4K Plus", "Xiaomi Mi TV Stick"])
        XCTAssertEqual(NetworkDiscovery.normalizedCastModel("onn. 4K Plus Streami"), "onn. 4K Plus Streaming")
    }

    func testDeviceTypeEstimationUsesStrongestAvailableSignal() {
        let car = AndroidDevice(id: "1", name: "Android", manufacturer: "Unknown", model: "Radio", adbState: .connected, isAndroidLikely: true, hasCast: false, androidCharacteristics: "automotive")
        let router = AndroidDevice(id: "2", name: "Device", manufacturer: "Unknown", model: "Unknown", adbState: .disabled, isAndroidLikely: false, hasCast: false, isGateway: true)
        let pi = AndroidDevice(id: "3", name: "Device", manufacturer: "Unknown", model: "Unknown", macAddress: "b8:27:eb:00:00:01", adbState: .disabled, isAndroidLikely: false, hasCast: false)
        let printer = AndroidDevice(id: "4", name: "Device", manufacturer: "Unknown", model: "Unknown", adbState: .disabled, isAndroidLikely: false, hasCast: false, openPorts: [9100])
        XCTAssertEqual([car.typeLabel, router.typeLabel, pi.typeLabel, printer.typeLabel], ["Android Automotive", "Likely Router", "Likely Raspberry Pi", "Likely Printer"])
        XCTAssertEqual(NetworkDiscovery.parseDefaultGateway("   gateway: 192.168.1.1\ninterface: en0"), "192.168.1.1")
    }

    func testRemoteFileParserPreservesNamesAndProtectsRoots() {
        let output = """
        total 12
        drwxrwx--- 2 root sdcard_rw 4096 2026-08-17 12:00 My Folder
        -rw-rw---- 1 root sdcard_rw 1536 2026-08-17 12:01 movie file.mkv
        lrwxrwxrwx 1 root root 21 2026-08-17 12:02 shortcut -> /storage/emulated/0
        """
        let files = RemoteFiles.parse(output, in: "/sdcard")
        XCTAssertEqual(files.map(\.name), ["My Folder", "movie file.mkv", "shortcut"])
        XCTAssertEqual(files[1].size, 1536)
        XCTAssertEqual(RemoteFiles.parent(of: "/sdcard/My Folder"), "/sdcard")
        XCTAssertEqual(RemoteFiles.locationName(for: "/sdcard/Download/Movies"), "Downloads")
        XCTAssertEqual(RemoteFiles.locationName(for: "/sdcard/Android/media/com.example"), "Android media")
        XCTAssertEqual(RemoteFiles.locationName(for: "/data/local/tmp/build.apk"), "ADB temporary files")
        XCTAssertEqual(RemoteFiles.locationName(for: "/system"), "system")
        XCTAssertTrue(RemoteFiles.shouldMeasureFolderSizes(in: "/sdcard/Download"))
        XCTAssertFalse(RemoteFiles.shouldMeasureFolderSizes(in: "/"))
        XCTAssertTrue(RemoteFiles.protectedRoots.contains("/system"))
        XCTAssertFalse(RemoteFiles.validName("../bad"))
        XCTAssertEqual(RemoteFiles.shellQuote("Andi's TV"), "'Andi'\\''s TV'")
        XCTAssertEqual(RemoteFiles.directorySizes("12\t/sdcard/My Folder\n2048 /sdcard/Movies"), [
            "/sdcard/My Folder": 12_288,
            "/sdcard/Movies": 2_097_152
        ])
    }

    func testStorageAndPerAppSizeParsing() {
        let df = """
        Filesystem 1K-blocks Used Available Use% Mounted on
        /dev/block/dm-1 1000000 750000 250000 75% /data
        """
        let stats = """
        Package Names: ["com.example.one","com.example.two"]
        App Sizes: [100,200]
        App Data Sizes: [30,40]
        Cache Sizes: [5,6]
        """
        let apps = StorageParser.appStorage(stats)
        XCTAssertEqual(apps["com.example.one"]?.total, 135)
        let capacity = StorageParser.capacity(df, appBytes: apps.values.reduce(0) { $0 + $1.total })
        XCTAssertEqual(capacity?.used, 768_000_000)
        XCTAssertEqual(capacity?.free, 256_000_000)
        XCTAssertEqual(capacity?.apps, 381)
        XCTAssertEqual(StorageParser.apkStorage("com.example.fresh\t55476224\ninvalid\n")["com.example.fresh"]?.total, 55_476_224)
        XCTAssertEqual(StorageParser.apkStorage("com.example.fresh\t55476224")["com.example.fresh"]?.isEstimate, true)
    }

    func testPerformanceParsingAndCPUDelta() {
        let first = PerformanceParser.sample("""
        cpu 100 0 50 850 0 0 0 0
        MemTotal: 1000 kB
        MemAvailable: 400 kB
        """)
        let second = PerformanceParser.sample("""
        cpu 140 0 70 890 0 0 0 0
        MemTotal: 1000 kB
        MemAvailable: 300 kB
        """)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        let performance = PerformanceParser.performance(second!, after: first!.cpu)
        XCTAssertEqual(performance.cpuFraction!, 0.6, accuracy: 0.001)
        XCTAssertEqual(performance.memoryTotal, 1_024_000)
        XCTAssertEqual(performance.memoryUsed, 716_800)
    }

    func testPowerStateAndContextualCommands() {
        XCTAssertEqual(DevicePowerState.parse("mWakefulness=Awake"), .awake)
        XCTAssertEqual(DevicePowerState.parse("mWakefulness=Asleep"), .asleep)
        XCTAssertEqual(DevicePowerState.parse("Display Power: state=OFF"), .asleep)
        XCTAssertEqual(DevicePowerAction.bootloader.arguments(serial: "tv:5555"), ["-s", "tv:5555", "reboot", "bootloader"])
        XCTAssertEqual(DevicePowerAction.shutdown.arguments(serial: "tv:5555"), ["-s", "tv:5555", "shell", "reboot -p"])
        XCTAssertTrue(AndroidDevice(id: "1", name: "Samsung TV", manufacturer: "Samsung", model: "TV", adbState: .connected, isAndroidLikely: true, hasCast: false).supportsDownloadMode)
        XCTAssertFalse(AndroidDevice(id: "2", name: "Fire TV", manufacturer: "Amazon", model: "AFTKRT", adbState: .connected, isAndroidLikely: true, hasCast: false).supportsDownloadMode)
    }

    func testADBMDNSDiscoveryIncludesClassicAndTLSDevices() {
        let output = """
        List of discovered mdns services
        adb-radio _adb._tcp 192.168.1.40:5555
        adb-phone _adb-tls-connect._tcp 192.168.1.41:37123
        adb-pair _adb-tls-pairing._tcp 192.168.1.41:39001
        """
        let endpoints = NetworkDiscovery.parseADBMDNS(output)
        XCTAssertEqual(endpoints.map(\.ip), ["192.168.1.40", "192.168.1.41"])
        XCTAssertEqual(endpoints.map(\.port), [5555, 37123])
    }

    func testADBDeckAppPackageValidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory.appendingPathComponent("base.apk"))
        try Data([2]).write(to: directory.appendingPathComponent("split_config.en.apk"))
        let manifest = AppBackup.Manifest(formatVersion: 1, packageName: "com.example.app", displayName: "Example", files: ["base.apk", "split_config.en.apk"])
        XCTAssertEqual(try AppBackup.apkURLs(for: manifest, in: directory).map(\.lastPathComponent), manifest.files)
        XCTAssertThrowsError(try AppBackup.apkURLs(for: .init(formatVersion: 1, packageName: "com.example.app", displayName: "Example", files: ["../base.apk"]), in: directory))
        XCTAssertThrowsError(try AppBackup.apkURLs(for: .init(formatVersion: 1, packageName: "bad; rm -rf", displayName: "Example", files: ["base.apk"]), in: directory))
        XCTAssertEqual(AppBackup.safeName("TV/App: Demo"), "TV-App- Demo")
    }

    func testAPKMSelectsCompatibleArchitectureAndDensity() throws {
        let files = ["base.apk", "split_config.arm64_v8a.apk", "split_config.armeabi_v7a.apk", "split_config.en.apk", "split_config.hdpi.apk", "split_config.xhdpi.apk"]
        XCTAssertEqual(try APKM.selectedFiles(from: files, supportedABIs: "armeabi-v7a,armeabi", density: 300),
                       ["base.apk", "split_config.armeabi_v7a.apk", "split_config.en.apk", "split_config.xhdpi.apk"])
        XCTAssertEqual(try APKM.selectedFiles(from: files, supportedABIs: "arm64-v8a,armeabi-v7a", density: 240),
                       ["base.apk", "split_config.arm64_v8a.apk", "split_config.en.apk", "split_config.hdpi.apk"])
        XCTAssertThrowsError(try APKM.selectedFiles(from: files, supportedABIs: "x86", density: 320))
        XCTAssertEqual(APKM.density(from: "Physical density: 240\nOverride density: 320"), 320)
    }

    func testAPKManifestPackageValidation() throws {
        let manifest = Data(base64Encoded: "AwAIAJQAAAABABwAVAAAAAMAAAAAAAAAAAEAACgAAAAAAAAAAAAAAAsAAAAVAAAACAhtYW5pZmVzdAAHB3BhY2thZ2UAEhJjb20uZXhhbXBsZS5wbGF5ZXIAAAACARAAOAAAAAEAAAD//////////wAAAAAUABQAAQAAAAAAAAD/////AQAAAAIAAAAIAAADAgAAAA==")!
        XCTAssertEqual(try APKManifest.packageName(in: manifest), "com.example.player")
        XCTAssertEqual(try APKManifest.metadata(in: manifest).version, AppVersion(code: nil, name: nil))
        XCTAssertThrowsError(try APKManifest.packageName(in: manifest.prefix(24)))
        XCTAssertFalse(APKManifest.validPackageName("bad; command"))
    }

    func testVersionComparisonChoosesSafeInstallAction() {
        let installed = AppVersion(code: 10, name: "1.0")
        let update = InstallRequest(url: URL(fileURLWithPath: "/new.apk"), packageName: "com.example.app", incoming: AppVersion(code: 11, name: "1.1"), installed: installed)
        XCTAssertEqual(update.mode, .update)
        XCTAssertEqual(update.actionTitle, "Update")
        XCTAssertTrue(update.summary.contains("keeps the app and its data"))

        let downgrade = InstallRequest(url: URL(fileURLWithPath: "/old.apk"), packageName: "com.example.app", incoming: AppVersion(code: 9, name: "0.9"), installed: installed)
        XCTAssertEqual(downgrade.mode, .replace)
        XCTAssertEqual(downgrade.actionTitle, "Replace")
        XCTAssertTrue(downgrade.summary.contains("older"))

        XCTAssertEqual(PackageVersionParser.version("versionCode=42 minSdk=23\nversionName=2.4.0"), AppVersion(code: 42, name: "2.4.0"))
    }

    func testInstallOutputRequiresExactSuccessAndExplainsFailures() throws {
        XCTAssertNoThrow(try InstallOutput.requireSuccess("Performing Streamed Install\nSuccess"))
        XCTAssertThrowsError(try InstallOutput.requireSuccess("Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]", removedExistingApp: true)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("enough free storage"))
            XCTAssertTrue(message.contains("already removed"))
            XCTAssertTrue(message.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE"))
        }
        XCTAssertThrowsError(try InstallOutput.requireSuccess("Not successful"))
    }

    func testPackageInstallAndUpdateDates() {
        let dates = PackageMetadataParser.dates("""
          Package [com.example.old] (abc):
            firstInstallTime=2025-01-02 03:04:05
            lastUpdateTime=2025-02-03 04:05:06
          Package [com.example.new] (def):
            firstInstallTime=2026-08-17 19:30:00
            lastUpdateTime=2026-08-17 19:31:00
              firstInstallTime=1970-01-01 00:00:00
          Package [com.example.unknown] (ghi):
            firstInstallTime=not-a-date
        """)
        XCTAssertEqual(dates.count, 2)
        XCTAssertNotNil(dates["com.example.old"]?.installed)
        XCTAssertGreaterThan(dates["com.example.new"]!.installed!, dates["com.example.old"]!.installed!)
        XCTAssertGreaterThan(dates["com.example.new"]!.updated!, dates["com.example.new"]!.installed!)
        XCTAssertEqual(Calendar.current.component(.year, from: dates["com.example.new"]!.installed!), 2026)
        XCTAssertNil(dates["com.example.unknown"]?.installed)
    }

    func testOptimizationReportsOnlyRecoveredResources() {
        let recovered = OptimizationResult(freeBefore: 1_000, freeAfter: 1_600, memoryBefore: 900, memoryAfter: 500)
        XCTAssertEqual(recovered.storageRecovered, 600)
        XCTAssertEqual(recovered.memoryReleased, 400)
        let unchanged = OptimizationResult(freeBefore: 1_000, freeAfter: 900, memoryBefore: 500, memoryAfter: 700)
        XCTAssertEqual(unchanged.storageRecovered, 0)
        XCTAssertEqual(unchanged.memoryReleased, 0)
    }

    func testRemoteInputBuildsSafeKeyboardCommands() throws {
        XCTAssertEqual(try RemoteInput.command(for: "Hello TV\n100%"), "input text 'Hello'; input keyevent KEYCODE_SPACE; input text 'TV'; input keyevent KEYCODE_ENTER; input text '100%'")
        XCTAssertEqual(try RemoteInput.command(for: "Andi's"), "input text 'Andi'\\''s'")
        XCTAssertThrowsError(try RemoteInput.command(for: "📺"))
        XCTAssertThrowsError(try RemoteInput.command(for: String(repeating: "a", count: 501)))
    }

    func testActivityParserFindsForegroundAndUniqueRecentApps() {
        let activities = """
          mResumedActivity: ActivityRecord{abc u0 com.netflix.ninja/.MainActivity t9}
          ResumedActivity: ActivityRecord{abc u0 com.netflix.ninja/.MainActivity t9}
        """
        let recents = """
          * Recent #0: Task{abc A=100:com.netflix.ninja U=0}
          * Recent #1: Task{def I=org.smarttube.stable/.MainActivity U=0}
          * Recent #2: Task{ghi A=101:com.netflix.ninja U=0}
        """
        XCTAssertEqual(ActivityParser.foreground(activities), "com.netflix.ninja")
        XCTAssertEqual(ActivityParser.recents(recents), ["com.netflix.ninja", "org.smarttube.stable"])
        XCTAssertNil(ActivityParser.foreground("mResumedActivity: null"))
    }

    func testLauncherParserFindsComponentsAndProtectsFallbacks() {
        let output = """
        3 activities found:
          Activity #0:
            priority=950 isDefault=true
            com.amazon.tv.launcher/.ui.HomeActivity_vNext
          Activity #1:
            com.example.launcher/com.example.launcher.HomeActivity
          Activity #2:
            com.amazon.tv.settings.v2/.system.FallbackHome
        """
        let components = LauncherParser.components(output)
        XCTAssertEqual(components, ["com.amazon.tv.launcher/.ui.HomeActivity_vNext", "com.example.launcher/com.example.launcher.HomeActivity", "com.amazon.tv.settings.v2/.system.FallbackHome"])
        XCTAssertFalse(DeviceLauncher(component: components[0], name: "Fire TV Home").isFallback)
        XCTAssertTrue(DeviceLauncher(component: components[2], name: "Fallback").isFallback)
    }

    func testLauncherCompatibilityDetectsPlayProtectedBuilds() {
        XCTAssertTrue(LauncherCompatibility.requiresGooglePlayLicense("com.pairip.licensecheck.LicenseActivity"))
        XCTAssertFalse(LauncherCompatibility.requiresGooglePlayLicense("com.example.launcher.MainActivity"))
    }

    func testFireTVHelperPreservesOtherAccessibilityServices() {
        let existing = "com.example.reader/.Service:com.example.remote/.Service"
        let enabled = FireTVHomeHelper.accessibilityServices(existing, enabling: true)
        XCTAssertTrue(enabled.contains(existing))
        XCTAssertTrue(enabled.contains(FireTVHomeHelper.service))
        XCTAssertEqual(FireTVHomeHelper.accessibilityServices(enabled, enabling: false), existing)
    }

    func testAppInspectionScreenMappingAndMediaParsing() {
        let inspection = AppInspectionParser.parse("""
          versionCode=2400 minSdk=17 targetSdk=34
          versionName=32.10
          User 0: installed=true suspended=false stopped=false enabled=0
            runtime permissions:
              android.permission.CAMERA: granted=true, flags=[ USER_SET]
              android.permission.RECORD_AUDIO: granted=false, flags=[]
          User 10: installed=false
        """, supportsCacheOnlyClear: true)
        XCTAssertEqual(inspection.versionName, "32.10")
        XCTAssertEqual(inspection.versionCode, "2400")
        XCTAssertEqual(inspection.permissions, [AppPermission(name: "android.permission.CAMERA", granted: true), AppPermission(name: "android.permission.RECORD_AUDIO", granted: false)])
        XCTAssertTrue(inspection.supportsCacheOnlyClear)

        let center = ScreenGeometry.devicePoint(at: CGPoint(x: 200, y: 150), in: CGSize(width: 400, height: 300), imageSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(center?.x ?? 0, 960, accuracy: 0.01)
        XCTAssertEqual(center?.y ?? 0, 540, accuracy: 0.01)
        XCTAssertNil(ScreenGeometry.devicePoint(at: CGPoint(x: 10, y: 10), in: CGSize(width: 400, height: 300), imageSize: CGSize(width: 1920, height: 1080)))

        let media = MediaSessionParser.parse("""
          Media button session is org.smarttube.stable/org.smarttube.stable (userId=0)
          Sessions Stack:
            package=org.smarttube.stable
            state=PlaybackState {state=PLAYING(3), position=0}
            metadata: size=6, description=Example Video, Example Channel, null
        """)
        XCTAssertEqual(media, MediaSessionInfo(packageName: "org.smarttube.stable", state: "Playing", title: "Example Video"))
    }

    func testDeviceArchitectureRecommendationAndErrorFormatting() {
        let device = AndroidDevice(id: "192.168.1.50", name: "Fire TV", manufacturer: "Amazon", model: "AFTKRT", adbState: .connected, isAndroidLikely: true, hasCast: false, supportedABIs: "armeabi-v7a,armeabi", androidVersion: "11", apiLevel: "30")
        XCTAssertEqual(device.recommendedAPKArchitecture, "ARMv7 · armeabi-v7a (32-bit)")
        let failure = OperationFailure(operation: "Install", details: "This app does not support the device architecture.\n\nDevice response:\nINSTALL_FAILED_NO_MATCHING_ABIS", device: device)
        XCTAssertEqual(failure.summary, "This app does not support the device architecture.")
        XCTAssertEqual(failure.technicalDetails, "INSTALL_FAILED_NO_MATCHING_ABIS")
        let commandFailure = OperationFailure(operation: "Browse", details: "Command: adb shell ls\nExit code: 1\n\nPermission denied", device: device)
        XCTAssertEqual(commandFailure.summary, "Permission denied")
        XCTAssertTrue(commandFailure.technicalDetails?.hasPrefix("Command:") == true)
    }

}
