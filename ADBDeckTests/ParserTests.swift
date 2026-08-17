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
        XCTAssertEqual(AppBackup.safeName("TV/App: Demo"), "TV-App- Demo")
    }
}
