import Foundation
import AppKit
import Network
import Observation
import SwiftUI

private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}

private final class ProcessBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    var snapshot: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private final class CastServiceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var models: [String: String] = [:]

    func add(identifier: String, model: String) {
        lock.lock()
        models[identifier] = model
        lock.unlock()
    }

    var snapshot: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return models
    }
}

enum ADBProgress {
    static func fraction(in text: String) -> Double? {
        let characters = Array(text)
        for percentIndex in characters.indices.reversed() where characters[percentIndex] == "%" {
            var index = percentIndex
            var digits = ""
            while index > characters.startIndex {
                index = characters.index(before: index)
                let character = characters[index]
                if character.isNumber { digits.insert(character, at: digits.startIndex) }
                else if digits.isEmpty { continue }
                else { break }
            }
            if let value = Double(digits), (0...100).contains(value) { return value / 100 }
        }
        return nil
    }
}

enum ADBState: String, Codable, Sendable {
    case connected = "Connected"
    case unauthorized = "Authorize on device"
    case available = "ADB available"
    case offline = "Offline"
    case disabled = "ADB off"
    case unknown = "Unknown"

    var isUsable: Bool { self == .connected }
}

enum DeviceKind: Sendable, Equatable {
    case fireTV, television, phone, tablet, automotive, watch, androidDevice, cast
    case router, raspberryPi, printer, camera, computer, network

    var symbol: String {
        switch self {
        case .fireTV: "flame.fill"
        case .television, .cast: "tv.fill"
        case .phone: "iphone"
        case .tablet: "ipad"
        case .automotive: "car.fill"
        case .watch: "clock.fill"
        case .androidDevice: "display"
        case .router: "wifi.router.fill"
        case .raspberryPi, .computer: "desktopcomputer"
        case .printer: "printer.fill"
        case .camera: "video.fill"
        case .network: "network"
        }
    }

    var color: Color {
        switch self {
        case .fireTV: .orange
        case .television, .cast: .blue
        case .phone: .teal
        case .tablet: .cyan
        case .automotive: .orange
        case .watch: .mint
        case .androidDevice: .blue
        case .router: .purple
        case .raspberryPi: .pink
        case .printer: .green
        case .camera: .red
        case .computer: .indigo
        case .network: .secondary
        }
    }
}

struct AndroidDevice: Identifiable, Hashable, Sendable {
    let id: String
    var adbPort: UInt16 = 5555
    var name: String
    var manufacturer: String
    var model: String
    var macAddress: String?
    var adbState: ADBState
    var isAndroidLikely: Bool
    var hasCast: Bool
    var supportedABIs: String? = nil
    var androidVersion: String? = nil
    var apiLevel: String? = nil
    var androidCharacteristics: String? = nil
    var openPorts: Set<UInt16> = []
    var isGateway = false

    var serial: String { "\(id):\(adbPort)" }

    var recommendedAPKArchitecture: String? {
        guard let primary = supportedABIs?.split(separator: ",").first.map(String.init) else { return nil }
        return switch primary {
        case "arm64-v8a": "ARM64 · arm64-v8a (64-bit)"
        case "armeabi-v7a": "ARMv7 · armeabi-v7a (32-bit)"
        case "x86_64": "Intel · x86_64 (64-bit)"
        case "x86": "Intel · x86 (32-bit)"
        default: primary
        }
    }

    var subtitle: String {
        let values = [manufacturer, model].filter { !$0.isEmpty && $0 != "Unknown" }
        if values.count == 2, model.lowercased().hasPrefix(manufacturer.lowercased()) { return model }
        return values.joined(separator: " · ")
    }

    var kind: DeviceKind {
        let text = "\(name) \(manufacturer) \(model)".lowercased()
        let characteristics = androidCharacteristics?.lowercased() ?? ""
        if text.contains("fire") || text.contains("amazon") || text.contains("aft") { return .fireTV }
        if characteristics.contains("automotive") { return .automotive }
        if characteristics.contains("watch") { return .watch }
        if characteristics.contains("tablet") { return .tablet }
        if characteristics.contains("phone") { return .phone }
        if characteristics.contains("tv") || text.contains("tv") || text.contains("onn") || text.contains("xiaomi") || text.contains("mi ") { return .television }
        if isAndroidLikely { return hasCast ? .television : .androidDevice }
        if hasCast { return .cast }
        if isGateway { return .router }
        if Self.raspberryPiPrefixes.contains(where: { macAddress?.uppercased().hasPrefix($0) == true }) { return .raspberryPi }
        if openPorts.contains(9100) || openPorts.contains(631) { return .printer }
        if openPorts.contains(554) { return .camera }
        if openPorts.contains(62078) || openPorts.contains(445) || openPorts.contains(22) { return .computer }
        return .network
    }

    var symbol: String { kind.symbol }
    var kindColor: Color { kind.color }

    var typeLabel: String? {
        let text = "\(name) \(manufacturer) \(model)".lowercased()
        if text.contains("amazon") || text.contains("fire tv") || text.contains("aft") { return "Fire TV" }
        if text.contains("onn") {
            if text.contains("plus") { return "onn. 4K Plus" }
            if text.contains("4k") { return "onn. 4K" }
            return "onn. Google TV"
        }
        if text.contains("xiaomi") || text.contains("mi tv") { return text.contains("stick") ? "Xiaomi Mi TV Stick" : "Xiaomi TV" }
        if text.contains("chromecast") || text.contains("google tv") || manufacturer.lowercased() == "google" { return "Google TV" }
        if text.contains("nvidia") || text.contains("shield") { return "NVIDIA Shield" }
        if text.contains("sony") || text.contains("bravia") { return "Sony Google TV" }
        if text.contains("tcl") { return "TCL Google TV" }
        if text.contains("hisense") { return "Hisense Google TV" }
        if text.contains("philips") { return "Philips Android TV" }
        if text.contains("samsung") { return "Samsung TV" }
        if text.contains("webos") || text.contains(" lg ") || manufacturer.lowercased() == "lg" { return "LG TV" }
        if text.contains("roku") { return "Roku" }
        let characteristics = androidCharacteristics?.lowercased() ?? ""
        if characteristics.contains("automotive") { return "Android Automotive" }
        if characteristics.contains("watch") { return "Wear OS" }
        if characteristics.contains("tablet") { return "Android Tablet" }
        if characteristics.contains("phone") { return "Android Phone" }
        if characteristics.contains("tv") { return hasCast ? "Android TV · Cast" : "Android TV" }
        if isAndroidLikely { return hasCast ? "Android TV · Cast" : "Android Device" }
        if hasCast { return "Google Cast" }
        return switch kind {
        case .router: "Likely Router"
        case .raspberryPi: "Likely Raspberry Pi"
        case .printer: "Likely Printer"
        case .camera: "Likely Camera / Streamer"
        case .computer where openPorts.contains(62078): "Likely Apple Device"
        case .computer: "Likely Computer / Server"
        default: "Network Device"
        }
    }

    private static let raspberryPiPrefixes = ["B8:27:EB", "DC:A6:32", "E4:5F:01", "D8:3A:DD", "28:CD:C1", "2C:CF:67"]

    var supportsDownloadMode: Bool {
        "\(name) \(manufacturer) \(model)".localizedCaseInsensitiveContains("samsung")
    }

    var listPriority: Int {
        switch adbState {
        case .connected: 0
        case .unauthorized: 1
        case .available: 2
        case .offline: 3
        case .disabled where isAndroidLikely: 4
        case .disabled, .unknown: 5
        }
    }

    static func sidebarOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.listPriority != rhs.listPriority { return lhs.listPriority < rhs.listPriority }
        let lhsIdentified = lhs.manufacturer != "Unknown"
        let rhsIdentified = rhs.manufacturer != "Unknown"
        if lhsIdentified != rhsIdentified { return lhsIdentified }
        if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
        return NetworkDiscovery.ipParts(lhs.id).lexicographicallyPrecedes(NetworkDiscovery.ipParts(rhs.id))
    }
}

enum DevicePowerState: String, Sendable {
    case awake = "Screen awake"
    case asleep = "Screen asleep"
    case dozing = "Screen dozing"
    case unknown = "Screen state unavailable"

    static func parse(_ output: String) -> Self {
        let value = output.lowercased()
        if value.contains("mwakefulness=awake") || value.contains("state=on") { return .awake }
        if value.contains("mwakefulness=asleep") || value.contains("state=off") { return .asleep }
        if value.contains("mwakefulness=dozing") || value.contains("mwakefulness=dreaming") { return .dozing }
        return .unknown
    }

    var symbol: String {
        switch self {
        case .awake: "sun.max.fill"
        case .asleep: "moon.zzz.fill"
        case .dozing: "moon.stars.fill"
        case .unknown: "power.circle"
        }
    }
}

enum DevicePowerAction: String, Identifiable, Sendable {
    case sleep, wake, restart, recovery, bootloader, download, shutdown

    var id: Self { self }
    var title: String {
        switch self {
        case .sleep: "Sleep screen"
        case .wake: "Wake screen"
        case .restart: "Restart"
        case .recovery: "Restart in Recovery"
        case .bootloader: "Restart in Bootloader / Fastboot"
        case .download: "Restart in Download Mode"
        case .shutdown: "Shut Down"
        }
    }
    var symbol: String {
        switch self {
        case .sleep: "moon.zzz.fill"
        case .wake: "sun.max.fill"
        case .restart: "arrow.clockwise.circle.fill"
        case .recovery: "cross.case.fill"
        case .bootloader: "terminal.fill"
        case .download: "arrow.down.to.line"
        case .shutdown: "power"
        }
    }
    var requiresConfirmation: Bool { ![.sleep, .wake].contains(self) }
    var disconnects: Bool { requiresConfirmation }
    var confirmation: String {
        switch self {
        case .restart: "The device will disconnect while Android restarts."
        case .recovery: "The device will restart in Recovery. A remote may not work there."
        case .bootloader: "The device will restart in its bootloader or Fastboot interface. A USB connection may be required to continue."
        case .download: "The Samsung device will restart in Download Mode. A USB connection may be required to exit or continue."
        case .shutdown: "The device will turn off and cannot be started again through ADB."
        case .sleep, .wake: ""
        }
    }

    func arguments(serial: String) -> [String] {
        switch self {
        case .sleep: ["-s", serial, "shell", "input keyevent KEYCODE_SLEEP"]
        case .wake: ["-s", serial, "shell", "input keyevent KEYCODE_WAKEUP"]
        case .restart: ["-s", serial, "reboot"]
        case .recovery: ["-s", serial, "reboot", "recovery"]
        case .bootloader: ["-s", serial, "reboot", "bootloader"]
        case .download: ["-s", serial, "reboot", "download"]
        case .shutdown: ["-s", serial, "shell", "reboot -p"]
        }
    }
}

struct AppStorage: Hashable, Sendable {
    let code: Int64
    let data: Int64
    let cache: Int64
    var isEstimate = false
    var total: Int64 { code + data + cache }
}

struct DeviceStorage: Equatable, Sendable {
    let total: Int64
    let used: Int64
    let free: Int64
    let apps: Int64
    let refreshedAt: Date

    var usedFraction: Double { total > 0 ? min(max(Double(used) / Double(total), 0), 1) : 0 }
    var isLow: Bool { total > 0 && Double(free) / Double(total) < 0.15 }
}

struct CPUTicks: Equatable, Sendable {
    let total: Int64
    let idle: Int64
}

struct PerformanceSample: Equatable, Sendable {
    let cpu: CPUTicks
    let memoryTotal: Int64
    let memoryAvailable: Int64
}

struct DevicePerformance: Equatable, Sendable {
    let cpuFraction: Double?
    let memoryTotal: Int64
    let memoryUsed: Int64
    let refreshedAt: Date
}

struct DeviceApp: Identifiable, Hashable, Sendable {
    let packageName: String
    let isSystem: Bool
    var storage: AppStorage? = nil
    var installedAt: Date? = nil
    var updatedAt: Date? = nil
    var id: String { packageName }

    private static let knownNames = [
        "com.amazon.firetv.youtube": "YouTube",
        "com.disney.disneyplus": "Disney+",
        "com.netflix.ninja": "Netflix",
        "com.spotify.tv.android": "Spotify",
        "com.stremio.one": "Stremio",
        "org.smarttube.stable": "SmartTube",
        "net.mullvad.mullvadvpn": "Mullvad VPN",
        "tv.twitch.android.app": "Twitch",
        "tv.twitch.android.viewer": "Twitch"
    ]

    var displayName: String {
        if let name = Self.knownNames[packageName] { return name }
        return packageName.split(separator: ".").last.map(String.init)?.replacingOccurrences(of: "_", with: " ").capitalized ?? packageName
    }

    var symbol: String {
        let value = packageName.lowercased()
        if ["youtube", "netflix", "video", "twitch", "stremio", "disney", "prime"].contains(where: value.contains) { return "play.rectangle.fill" }
        if ["spotify", "music", "audio"].contains(where: value.contains) { return "music.note" }
        if ["vpn", "security"].contains(where: value.contains) { return "shield.fill" }
        if ["browser", "chrome", "firefox"].contains(where: value.contains) { return "globe" }
        if ["download", "loader"].contains(where: value.contains) { return "arrow.down.circle.fill" }
        if ["cast", "receiver"].contains(where: value.contains) { return "airplayvideo" }
        if ["game", "geforce"].contains(where: value.contains) { return "gamecontroller.fill" }
        if ["settings", "tools", "adb"].contains(where: value.contains) { return "wrench.and.screwdriver.fill" }
        return isSystem ? "gearshape.2.fill" : "app.fill"
    }
}

struct AppPermission: Identifiable, Hashable, Sendable {
    let name: String
    let granted: Bool
    var id: String { name }
    var shortName: String { name.split(separator: ".").last.map(String.init) ?? name }
}

struct AppInspection: Equatable, Sendable {
    let versionName: String?
    let versionCode: String?
    let minSDK: String?
    let targetSDK: String?
    let isStopped: Bool
    let isSuspended: Bool
    let enabledState: String
    let permissions: [AppPermission]
    let supportsCacheOnlyClear: Bool
}

enum AppInspectionParser {
    static func parse(_ output: String, supportsCacheOnlyClear: Bool) -> AppInspection {
        var versionName: String?
        var versionCode: String?
        var minSDK: String?
        var targetSDK: String?
        var isStopped = false
        var isSuspended = false
        var enabledState = "Default"
        var inUserZero = false
        var inRuntimePermissions = false
        var permissions: [AppPermission] = []

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if versionName == nil, line.hasPrefix("versionName=") { versionName = value(after: "versionName=", in: line) }
            if versionCode == nil, line.contains("versionCode=") {
                versionCode = token("versionCode", in: line)
                minSDK = token("minSdk", in: line)
                targetSDK = token("targetSdk", in: line)
            }
            if line.hasPrefix("User 0:") {
                inUserZero = true
                inRuntimePermissions = false
                isStopped = line.contains("stopped=true")
                isSuspended = line.contains("suspended=true")
                enabledState = switch token("enabled", in: line) {
                case "1": "Enabled"
                case "2", "3", "4": "Disabled"
                default: "Default"
                }
                continue
            }
            if inUserZero, line.hasPrefix("User "), !line.hasPrefix("User 0:") { break }
            if inUserZero, line == "runtime permissions:" { inRuntimePermissions = true; continue }
            if inRuntimePermissions, line.hasPrefix("android.permission."), let separator = line.range(of: ": granted=") {
                permissions.append(AppPermission(name: String(line[..<separator.lowerBound]), granted: line[separator.upperBound...].hasPrefix("true")))
            }
        }
        return AppInspection(versionName: versionName, versionCode: versionCode, minSDK: minSDK, targetSDK: targetSDK, isStopped: isStopped, isSuspended: isSuspended, enabledState: enabledState, permissions: permissions.sorted { $0.shortName < $1.shortName }, supportsCacheOnlyClear: supportsCacheOnlyClear)
    }

    private static func token(_ name: String, in line: String) -> String? {
        line.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("\(name)=") }.map { String($0.dropFirst(name.count + 1)) }
    }

    private static func value(after prefix: String, in line: String) -> String? {
        String(line.dropFirst(prefix.count)).nilIfEmpty
    }
}

struct ScreenCapture: Equatable, Sendable {
    let data: Data
    let width: Int
    let height: Int
    let capturedAt: Date
}

enum ScreenGeometry {
    static func devicePoint(at location: CGPoint, in viewSize: CGSize, imageSize: CGSize) -> CGPoint? {
        guard viewSize.width > 0, viewSize.height > 0, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let rendered = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (viewSize.width - rendered.width) / 2, y: (viewSize.height - rendered.height) / 2)
        guard location.x >= origin.x, location.y >= origin.y, location.x <= origin.x + rendered.width, location.y <= origin.y + rendered.height else { return nil }
        return CGPoint(x: (location.x - origin.x) / scale, y: (location.y - origin.y) / scale)
    }
}

struct MediaSessionInfo: Equatable, Sendable {
    let packageName: String
    let state: String
    let title: String?
}

enum MediaSessionParser {
    static func parse(_ output: String) -> MediaSessionInfo? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let header = lines.first(where: { $0.hasPrefix("Media button session is ") }),
              let package = header.dropFirst("Media button session is ".count).split(separator: "/").first.map(String.init) else { return nil }
        var inSession = false
        var state = "Idle"
        var title: String?
        for line in lines {
            if line.hasPrefix("package=") {
                if inSession { break }
                inSession = line == "package=\(package)"
            } else if inSession, line.contains("state=PlaybackState") {
                if line.contains("PLAYING(3)") || line.contains("{state=3,") { state = "Playing" }
                else if line.contains("PAUSED(2)") || line.contains("{state=2,") { state = "Paused" }
                else if line.contains("BUFFERING(6)") || line.contains("{state=6,") { state = "Buffering" }
            } else if inSession, let range = line.range(of: "description="), !line.contains("description=null") {
                title = String(line[range.upperBound...].split(separator: ",", maxSplits: 1).first ?? "").nilIfEmpty
            }
        }
        return MediaSessionInfo(packageName: package, state: state, title: title)
    }
}

enum ActivityParser {
    private static let currentPattern = try! NSRegularExpression(
        pattern: #"([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+)/"#
    )
    private static let recentPattern = try! NSRegularExpression(
        pattern: #"(?:A=\d+:|I=)([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+)"#
    )

    static func foreground(_ output: String) -> String? {
        output.split(separator: "\n").lazy
            .filter { $0.contains("mResumedActivity") || $0.contains("topResumedActivity") || $0.contains("ResumedActivity") }
            .compactMap { capture(in: String($0), with: currentPattern) }
            .first
    }

    static func recents(_ output: String, limit: Int = 12) -> [String] {
        var seen = Set<String>()
        return output.split(separator: "\n").compactMap { line in
            guard line.contains("Recent #"), let package = capture(in: String(line), with: recentPattern), seen.insert(package).inserted else { return nil }
            return package
        }.prefix(limit).map { $0 }
    }

    private static func capture(in text: String, with expression: NSRegularExpression) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[capture])
    }
}

struct DeviceLauncher: Identifiable, Hashable, Sendable {
    let component: String
    let name: String
    var id: String { component }
    var packageName: String { String(component.split(separator: "/", maxSplits: 1).first ?? "") }
    var isFallback: Bool {
        let value = component.lowercased()
        return value.contains("fallbackhome") || value.contains("recoveryactivity") || value.contains("firehomestarter")
    }
}

enum LauncherParser {
    private static let pattern = try! NSRegularExpression(pattern: #"([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+/[A-Za-z0-9_.$]+)"#)
    private static let knownNames = [
        "com.amazon.tv.launcher": "Fire TV Home",
        "com.amazon.firehomestarter": "Fire TV Home Starter",
        "com.google.android.apps.tv.launcherx": "Google TV Home",
        "com.android.tv.settings": "Android Fallback Home",
        "com.amazon.tv.settings.v2": "Fire TV Fallback Home"
    ]

    static func components(_ output: String) -> [String] {
        var seen = Set<String>()
        return output.split(separator: "\n").compactMap { line in
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = pattern.firstMatch(in: text, range: range), let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            let value = String(text[valueRange])
            return seen.insert(value).inserted ? value : nil
        }
    }

    static func name(for component: String, apps: [DeviceApp]) -> String {
        let package = String(component.split(separator: "/", maxSplits: 1).first ?? "")
        return apps.first { $0.packageName == package }?.displayName ?? knownNames[package] ?? DeviceApp(packageName: package, isSystem: false).displayName
    }
}

struct AppDates: Equatable, Sendable {
    var installed: Date?
    var updated: Date?
}

enum PackageMetadataParser {
    static func dates(_ output: String) -> [String: AppDates] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var result: [String: AppDates] = [:]
        var package: String?
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            if line.hasPrefix("  Package ["), let end = line.firstIndex(of: "]") {
                package = String(line[line.index(line.startIndex, offsetBy: 11)..<end])
                continue
            }
            guard let package else { continue }
            let field = line.trimmingCharacters(in: .whitespaces)
            if field.hasPrefix("firstInstallTime=") {
                if let date = formatter.date(from: String(field.dropFirst(17))) {
                    result[package, default: AppDates()].installed = max(result[package]?.installed ?? .distantPast, date)
                }
            } else if field.hasPrefix("lastUpdateTime=") {
                if let date = formatter.date(from: String(field.dropFirst(15))) {
                    result[package, default: AppDates()].updated = max(result[package]?.updated ?? .distantPast, date)
                }
            }
        }
        return result
    }
}

enum StorageParser {
    static func capacity(_ output: String, appBytes: Int64 = 0) -> DeviceStorage? {
        guard let line = output.split(separator: "\n").last(where: { $0.first == "/" }) else { return nil }
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 4,
              let total = Int64(fields[1]),
              let used = Int64(fields[2]),
              let free = Int64(fields[3]) else { return nil }
        return DeviceStorage(total: total * 1024, used: used * 1024, free: free * 1024, apps: appBytes, refreshedAt: Date())
    }

    static func appStorage(_ output: String) -> [String: AppStorage] {
        guard let packages = strings(after: "Package Names:", in: output),
              let code = integers(after: "App Sizes:", in: output),
              let data = integers(after: "App Data Sizes:", in: output),
              let cache = integers(after: "Cache Sizes:", in: output) else { return [:] }
        let count = [packages.count, code.count, data.count, cache.count].min() ?? 0
        return Dictionary(uniqueKeysWithValues: (0..<count).map {
            (packages[$0], AppStorage(code: code[$0], data: data[$0], cache: cache[$0]))
        })
    }

    static func apkStorage(_ output: String) -> [String: AppStorage] {
        Dictionary(uniqueKeysWithValues: output.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, let bytes = Int64(fields[1]), bytes > 0 else { return nil }
            return (String(fields[0]), AppStorage(code: bytes, data: 0, cache: 0, isEstimate: true))
        })
    }

    private static func value(after prefix: String, in output: String) -> String? {
        output.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }).map {
            String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
    }

    private static func strings(after prefix: String, in output: String) -> [String]? {
        guard let value = value(after: prefix, in: output), let data = value.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String]
    }

    private static func integers(after prefix: String, in output: String) -> [Int64]? {
        guard let value = value(after: prefix, in: output), let data = value.data(using: .utf8),
              let numbers = try? JSONSerialization.jsonObject(with: data) as? [NSNumber] else { return nil }
        return numbers.map(\.int64Value)
    }
}

enum PerformanceParser {
    static func sample(_ output: String) -> PerformanceSample? {
        let lines = output.split(separator: "\n")
        guard let cpuLine = lines.first(where: { $0.hasPrefix("cpu ") }) else { return nil }
        let values = cpuLine.split(whereSeparator: \.isWhitespace).dropFirst().prefix(8).compactMap { Int64($0) }
        guard values.count >= 5,
              let totalMemory = memory(named: "MemTotal:", in: lines),
              let availableMemory = memory(named: "MemAvailable:", in: lines) else { return nil }
        return PerformanceSample(
            cpu: CPUTicks(total: values.reduce(0, +), idle: values[3] + values[4]),
            memoryTotal: totalMemory * 1024,
            memoryAvailable: availableMemory * 1024
        )
    }

    static func performance(_ sample: PerformanceSample, after previous: CPUTicks?) -> DevicePerformance {
        let cpu: Double?
        if let previous {
            let total = sample.cpu.total - previous.total
            let idle = sample.cpu.idle - previous.idle
            cpu = total > 0 ? min(max(Double(total - idle) / Double(total), 0), 1) : nil
        } else {
            cpu = nil
        }
        return DevicePerformance(
            cpuFraction: cpu,
            memoryTotal: sample.memoryTotal,
            memoryUsed: max(sample.memoryTotal - sample.memoryAvailable, 0),
            refreshedAt: Date()
        )
    }

    private static func memory(named name: String, in lines: [Substring]) -> Int64? {
        lines.first(where: { $0.hasPrefix(name) })?.split(whereSeparator: \.isWhitespace).dropFirst().first.flatMap { Int64($0) }
    }
}

struct RemoteFile: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let size: Int64
    let modified: String
    let permissions: String
    let isDirectory: Bool
    let isLink: Bool
    var measuredSize: Int64? = nil

    var id: String { path }
    var symbol: String {
        if isDirectory { return "folder.fill" }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "webp"].contains(ext) { return "photo.fill" }
        if ["mp4", "mkv", "avi", "mov", "webm"].contains(ext) { return "film.fill" }
        if ["mp3", "m4a", "wav", "flac", "ogg"].contains(ext) { return "music.note" }
        if ext == "apk" { return "shippingbox.fill" }
        if ["zip", "rar", "7z", "tar", "gz"].contains(ext) { return "archivebox.fill" }
        return "doc.fill"
    }
}

enum RemoteFiles {
    static let protectedRoots: Set<String> = ["/", "/data", "/product", "/sdcard", "/storage", "/system", "/vendor"]

    static func joined(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/\(name)" : "\(directory.hasSuffix("/") ? directory.dropLast() : Substring(directory))/\(name)"
    }

    static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\n")
    }

    static func parse(_ output: String, in directory: String) -> [RemoteFile] {
        output.split(separator: "\n").compactMap { raw in
            let fields = raw.split(maxSplits: 7, whereSeparator: \.isWhitespace)
            guard fields.count == 8, fields[0].first.map({ "dl-".contains($0) }) == true else { return nil }
            var name = String(fields[7])
            let permissions = String(fields[0])
            let isLink = permissions.first == "l"
            if isLink, let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            guard name != ".", name != ".." else { return nil }
            return RemoteFile(
                name: name,
                path: joined(directory, name),
                size: Int64(fields[4]) ?? 0,
                modified: "\(fields[5]) \(fields[6])",
                permissions: permissions,
                isDirectory: permissions.first == "d",
                isLink: isLink
            )
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func directorySizes(_ output: String) -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: output.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let kilobytes = Int64(fields[0]) else { return nil }
            return (String(fields[1]), kilobytes * 1024)
        })
    }
}

enum RemoteInput {
    static func command(for text: String) throws -> String {
        guard !text.isEmpty else { throw ADBError.commandFailed("Enter or paste text to send.") }
        guard text.count <= 500 else { throw ADBError.commandFailed("Text input is limited to 500 characters at a time.") }
        guard text.unicodeScalars.allSatisfy({ $0 == "\n" || (0x20...0x7e).contains($0.value) }) else {
            throw ADBError.commandFailed("ADB text input supports standard keyboard characters only. Remove emoji, accents, or tabs and try again.")
        }

        var commands: [String] = []
        var chunk = ""
        func flush() {
            guard !chunk.isEmpty else { return }
            commands.append("input text \(RemoteFiles.shellQuote(chunk))")
            chunk = ""
        }
        for character in text {
            switch character {
            case " ": flush(); commands.append("input keyevent KEYCODE_SPACE")
            case "\n": flush(); commands.append("input keyevent KEYCODE_ENTER")
            default: chunk.append(character)
            }
        }
        flush()
        return commands.joined(separator: "; ")
    }
}

struct RemoteClipboard: Equatable, Sendable {
    enum Operation: String, Sendable { case copy = "Copy", move = "Move" }
    let file: RemoteFile
    let operation: Operation
}

struct TransferStatus: Equatable {
    var title: String
    var detail: String
    var fraction: Double?
}

struct OperationFailure: Identifiable, Equatable {
    let id = UUID()
    let operation: String
    let details: String
    let device: AndroidDevice?

    var summary: String {
        splitDetails.summary
    }

    var technicalDetails: String? {
        splitDetails.technical
    }

    private var splitDetails: (summary: String, technical: String?) {
        let marker = "\n\nDevice response:\n"
        if let range = details.range(of: marker) {
            return (String(details[..<range.lowerBound]), String(details[range.upperBound...]).nilIfEmpty)
        }
        let parts = details.components(separatedBy: "\n\n")
        guard parts.count > 1 else { return (details, nil) }
        return (parts[0], parts.dropFirst().joined(separator: "\n\n").nilIfEmpty)
    }
}

struct OptimizationResult: Identifiable, Equatable {
    let id = UUID()
    let storageRecovered: Int64?
    let memoryReleased: Int64?

    init(freeBefore: Int64?, freeAfter: Int64?, memoryBefore: Int64?, memoryAfter: Int64?) {
        storageRecovered = freeBefore.flatMap { before in freeAfter.map { max($0 - before, 0) } }
        memoryReleased = memoryBefore.flatMap { before in memoryAfter.map { max(before - $0, 0) } }
    }
}

struct InstallRequest: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let packageName: String
    let incoming: AppVersion
    let installed: AppVersion

    var isUpdate: Bool { incoming.code.map { new in installed.code.map { new > $0 } } == true }
    var isSameVersion: Bool { incoming.code != nil && incoming.code == installed.code }
    var actionTitle: String { isUpdate ? "Update" : isSameVersion ? "Reinstall" : "Replace" }
    var mode: InstallMode { isUpdate || isSameVersion ? .update : .replace }

    var summary: String {
        let comparison = isUpdate ? "A newer version is ready to install." : isSameVersion ? "This version is already installed." : incoming.code != nil && installed.code != nil ? "This package is older than the installed app." : "The package version could not be compared safely."
        let consequence = mode == .update
            ? "\(actionTitle) keeps the app and its data."
            : "Replace removes the installed app and all of its data first. If installation fails, the old app cannot be restored."
        return "\(comparison)\n\nInstalled: \(installed.display)\nSelected: \(incoming.display)\n\n\(consequence)"
    }
}

enum InstallMode: Sendable { case new, update, replace }

struct AppVersion: Equatable, Sendable {
    let code: Int64?
    let name: String?

    var display: String {
        if let name, let code { return "\(name) (build \(code))" }
        if let name { return name }
        if let code { return "Build \(code)" }
        return "Unknown"
    }
}

enum PackageVersionParser {
    static func version(_ output: String) -> AppVersion {
        var code: Int64?
        var name: String?
        for line in output.split(separator: "\n") {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("versionCode=") {
                code = Int64(value.dropFirst(12).prefix { $0.isNumber })
            } else if value.hasPrefix("versionName=") {
                let parsed = String(value.dropFirst(12))
                name = parsed == "null" || parsed.isEmpty ? nil : parsed
            }
        }
        return AppVersion(code: code, name: name)
    }
}

struct APKMetadata: Equatable, Sendable {
    let packageName: String
    let version: AppVersion
}

enum APKManifest {
    static func packageName(in data: Data) throws -> String {
        try metadata(in: data).packageName
    }

    static func metadata(in data: Data) throws -> APKMetadata {
        guard data.u16(at: 0) == 0x0003 else { throw invalid }
        var offset = Int(data.u16(at: 2) ?? 8)
        var strings: [String] = []
        while offset + 8 <= data.count {
            guard let type = data.u16(at: offset), let headerSize = data.u16(at: offset + 2),
                  let chunkSize = data.u32(at: offset + 4), headerSize >= 8, chunkSize >= UInt32(headerSize),
                  offset + Int(chunkSize) <= data.count else { throw invalid }
            if type == 0x0001 { strings = try stringPool(in: data, at: offset) }
            if type == 0x0102, !strings.isEmpty, data.string(at: offset + 20, from: strings) == "manifest",
               let attributeStart = data.u16(at: offset + 24), let attributeSize = data.u16(at: offset + 26),
               let attributeCount = data.u16(at: offset + 28), attributeSize >= 20 {
                let start = offset + 16 + Int(attributeStart)
                var packageName: String?
                var versionCode: Int64?
                var versionName: String?
                for index in 0..<Int(attributeCount) {
                    let attribute = start + index * Int(attributeSize)
                    guard attribute + 20 <= offset + Int(chunkSize) else { throw invalid }
                    guard let name = data.string(at: attribute + 4, from: strings) else { continue }
                    let raw = data.string(at: attribute + 8, from: strings)
                    let typed = data[attribute + 15] == 0x03 ? data.string(at: attribute + 16, from: strings) : nil
                    switch name {
                    case "package": packageName = raw ?? typed
                    case "versionName": versionName = raw ?? typed
                    case "versionCode": versionCode = data.u32(at: attribute + 16).map(Int64.init)
                    default: break
                    }
                }
                guard let packageName, validPackageName(packageName) else { throw invalid }
                return APKMetadata(packageName: packageName, version: AppVersion(code: versionCode, name: versionName))
            }
            offset += Int(chunkSize)
        }
        throw invalid
    }

    private static func stringPool(in data: Data, at offset: Int) throws -> [String] {
        guard let headerSize = data.u16(at: offset + 2), let count = data.u32(at: offset + 8),
              let flags = data.u32(at: offset + 16), let stringsStart = data.u32(at: offset + 20), headerSize >= 28 else { throw invalid }
        let offsets = offset + Int(headerSize)
        let base = offset + Int(stringsStart)
        return try (0..<Int(count)).map { index in
            guard let relative = data.u32(at: offsets + index * 4) else { throw invalid }
            var cursor = base + Int(relative)
            if flags & 0x100 != 0 {
                _ = try data.length8(at: &cursor)
                let length = try data.length8(at: &cursor)
                guard cursor + length <= data.count, let value = String(data: data[cursor..<cursor + length], encoding: .utf8) else { throw invalid }
                return value
            }
            let length = try data.length16(at: &cursor)
            guard cursor + length * 2 <= data.count,
                  let value = String(data: data[cursor..<cursor + length * 2], encoding: .utf16LittleEndian) else { throw invalid }
            return value
        }
    }

    static func validPackageName(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count > 1 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }
    }

    private static var invalid: ADBError { .commandFailed("The APK has an invalid or unreadable Android manifest.") }
}

private extension Data {
    func u16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func u32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }

    func string(at offset: Int, from pool: [String]) -> String? {
        guard let index = u32(at: offset), index != UInt32.max, Int(index) < pool.count else { return nil }
        return pool[Int(index)]
    }

    func length8(at cursor: inout Int) throws -> Int {
        guard cursor < count else { throw ADBError.commandFailed("The APK manifest string table is truncated.") }
        let first = Int(self[cursor]); cursor += 1
        guard first & 0x80 != 0 else { return first }
        guard cursor < count else { throw ADBError.commandFailed("The APK manifest string table is truncated.") }
        let value = (first & 0x7f) << 8 | Int(self[cursor]); cursor += 1
        return value
    }

    func length16(at cursor: inout Int) throws -> Int {
        guard let first = u16(at: cursor) else { throw ADBError.commandFailed("The APK manifest string table is truncated.") }
        cursor += 2
        guard first & 0x8000 != 0 else { return Int(first) }
        guard let second = u16(at: cursor) else { throw ADBError.commandFailed("The APK manifest string table is truncated.") }
        cursor += 2
        return Int(first & 0x7fff) << 16 | Int(second)
    }
}

enum AppBackup {
    struct Manifest: Codable, Equatable {
        let formatVersion: Int
        let packageName: String
        let displayName: String
        let files: [String]
    }

    static let manifestName = "manifest.json"

    static func safeName(_ value: String) -> String {
        let name = value.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Android App"
    }

    static func apkURLs(for manifest: Manifest, in directory: URL) throws -> [URL] {
        guard manifest.formatVersion == 1, APKManifest.validPackageName(manifest.packageName), !manifest.files.isEmpty,
              Set(manifest.files).count == manifest.files.count else {
            throw ADBError.commandFailed("This ADB Deck app package has an invalid manifest.")
        }
        return try manifest.files.map { name in
            guard name == URL(fileURLWithPath: name).lastPathComponent,
                  URL(fileURLWithPath: name).pathExtension.lowercased() == "apk" else {
                throw ADBError.commandFailed("The app package contains an unsafe file name.")
            }
            let url = directory.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
                throw ADBError.commandFailed("The app package is missing \(name).")
            }
            return url
        }
    }
}

enum ADBError: LocalizedError {
    case binaryMissing
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing: "ADB is missing from the app bundle."
        case .commandFailed(let message): message.isEmpty ? "ADB command failed." : message
        }
    }
}

enum InstallOutput {
    static func requireSuccess(_ output: String, removedExistingApp: Bool = false) throws {
        let succeeded = output.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("Success") == .orderedSame
        }
        guard succeeded else { throw ADBError.commandFailed(details(for: output, removedExistingApp: removedExistingApp)) }
    }

    static func details(for output: String, removedExistingApp: Bool = false) -> String {
        let value = output.lowercased()
        let reason: String
        if value.contains("install_failed_insufficient_storage") {
            reason = "The device does not have enough free storage. Free some space, then try again."
        } else if value.contains("install_failed_no_matching_abis") {
            reason = "This app does not support the device’s processor architecture."
        } else if value.contains("install_failed_older_sdk") {
            reason = "This app requires a newer Android version than the device provides."
        } else if value.contains("install_failed_missing_split") {
            reason = "This app is missing required APK components. Install its complete .adbdeck package instead."
        } else if value.contains("install_failed_update_incompatible") {
            reason = "The installed app and this package use different signatures. Choose Replace to remove the old app first."
        } else if value.contains("install_failed_version_downgrade") {
            reason = "This package is older than the installed version. Choose Replace if you want to downgrade."
        } else if value.contains("install_parse_failed") || value.contains("failed to parse") {
            reason = "Android could not read this package. It may be damaged or incomplete."
        } else if value.contains("unauthorized") {
            reason = "The device has not authorized this Mac. Accept the debugging prompt on the device, then retry."
        } else if value.contains("device offline") || value.contains("no devices/emulators") {
            reason = "The device disconnected during installation. Reconnect it, then retry."
        } else {
            reason = "Android rejected the app package."
        }
        let replacement = removedExistingApp ? "\n\nThe previous app and its local data were already removed." : ""
        let response = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(reason)\(replacement)\n\nDevice response:\n\(response.isEmpty ? "No details returned." : response)"
    }
}

struct ADBClient: Sendable {
    static var binaryURL: URL? {
        if let bundled = Bundle.main.url(forResource: "adb", withExtension: nil, subdirectory: "platform-tools") {
            return bundled
        }
        return ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func run(_ arguments: [String]) async throws -> String {
        try await runStreaming(arguments) { _ in }
    }

    func runData(_ arguments: [String]) async throws -> Data {
        guard let binary = Self.binaryURL else { throw ADBError.binaryMissing }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let output = ProcessBuffer()
            let errors = ProcessBuffer()
            process.executableURL = binary
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { output.append(data) }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { errors.append(data) }
            }
            try process.run()
            process.waitUntilExit()
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            output.append(stdout.fileHandleForReading.readDataToEndOfFile())
            errors.append(stderr.fileHandleForReading.readDataToEndOfFile())
            guard process.terminationStatus == 0 else {
                throw ADBError.commandFailed(errors.text.nilIfEmpty ?? "ADB returned no details.")
            }
            return output.snapshot
        }.value
    }

    func connect(_ serial: String) async throws -> String {
        do {
            return try await connectOnce(serial)
        } catch ADBError.commandFailed(let message) where Self.needsServerRestart(message) {
            _ = try? await run(["kill-server"])
            return try await connectOnce(serial)
        }
    }

    private func connectOnce(_ serial: String) async throws -> String {
        let output = try await run(["connect", serial])
        guard output.lowercased().contains("connected to") else { throw ADBError.commandFailed(output) }
        return output
    }

    static func needsServerRestart(_ message: String) -> Bool {
        let value = message.lowercased()
        return ["no route to host", "device offline", "protocol fault", "connection reset", "cannot connect to daemon"]
            .contains(where: value.contains)
    }

    func runStreaming(_ arguments: [String], progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        guard let binary = Self.binaryURL else { throw ADBError.binaryMissing }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let buffer = ProcessBuffer()
            process.executableURL = binary
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            let consume: @Sendable (FileHandle) -> Void = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
                buffer.append(chunk)
                if let value = ADBProgress.fraction(in: buffer.text) { progress(value) }
            }
            stdout.fileHandleForReading.readabilityHandler = consume
            stderr.fileHandleForReading.readabilityHandler = consume
            try process.run()
            process.waitUntilExit()
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            buffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
            buffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
            let output = buffer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                let command = (["adb"] + arguments).joined(separator: " ")
                throw ADBError.commandFailed("Command: \(command)\nExit code: \(process.terminationStatus)\n\n\(output.isEmpty ? "No output returned." : output)")
            }
            return output
        }.value
    }
}

struct NetworkDiscovery {
    struct CastDetails: Sendable {
        let name: String?
        let identifier: String?
    }

    struct Host: Sendable {
        let ip: String
        var mac: String?
        var adbOpen = false
        var castOpen = false
        var castName: String?
        var castModel: String?
        var adbPort: UInt16?
        var openPorts: Set<UInt16> = []
        var isGateway = false
    }

    static func discover() async -> [Host] {
        guard let address = localIPv4(), let prefix = address.split(separator: ".").dropLast().nilIfEmpty?.joined(separator: ".") else {
            return []
        }

        var serviceHosts: [String: Host] = [:]
        for endpoint in await adbMDNSServices() {
            serviceHosts[endpoint.ip] = Host(ip: endpoint.ip, adbOpen: true, adbPort: endpoint.port)
        }
        // ponytail: /24 batches cap open sockets; add adaptive subnet scheduling only if larger networks are required.
        for batchStart in stride(from: 1, through: 254, by: 24) {
            await withTaskGroup(of: Host?.self) { group in
                for suffix in batchStart...min(batchStart + 23, 254) {
                    let ip = "\(prefix).\(suffix)"
                    group.addTask {
                        async let adb = portOpen(ip: ip, port: 5555)
                        async let cast = portOpen(ip: ip, port: 8008)
                        let result = await (adb, cast)
                        guard result.0 || result.1 else { return nil }
                        return Host(ip: ip, adbOpen: result.0, castOpen: result.1, adbPort: result.0 ? 5555 : nil)
                    }
                }
                for await host in group {
                    guard let host else { continue }
                    if var existing = serviceHosts[host.ip] {
                        existing.adbOpen = existing.adbOpen || host.adbOpen
                        existing.castOpen = existing.castOpen || host.castOpen
                        existing.adbPort = existing.adbPort ?? host.adbPort
                        serviceHosts[host.ip] = existing
                    } else {
                        serviceHosts[host.ip] = host
                    }
                }
            }
        }

        async let arpTask = arpTable()
        async let gatewayTask = defaultGateway()
        let (arp, gateway) = await (arpTask, gatewayTask)
        for (ip, mac) in arp {
            if serviceHosts[ip] != nil {
                serviceHosts[ip]?.mac = mac
            } else {
                serviceHosts[ip] = Host(ip: ip, mac: mac)
            }
        }

        let fingerprints = await fingerprint(Array(serviceHosts.keys))
        for (ip, ports) in fingerprints { serviceHosts[ip]?.openPorts = ports }
        if let gateway { serviceHosts[gateway]?.isGateway = true }

        let castModels = await castServiceModels()
        for ip in serviceHosts.values.filter({ $0.castOpen }).map(\.ip) {
            let details = await castDetails(ip: ip)
            serviceHosts[ip]?.castName = details.name
            if let identifier = details.identifier?.replacingOccurrences(of: "-", with: "").lowercased() {
                serviceHosts[ip]?.castModel = castModels[identifier].map(normalizedCastModel)
            }
        }
        return serviceHosts.values.sorted { ipParts($0.ip).lexicographicallyPrecedes(ipParts($1.ip)) }
    }

    static func localIPv4() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.ifa_name) == "en0" else { continue }
            var address = interface.ifa_addr.pointee
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(&address, socklen_t(interface.ifa_addr.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            return String(cString: buffer)
        }
        return nil
    }

    static func parseADBMDNS(_ output: String) -> [(ip: String, port: UInt16)] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3,
                  fields[1] == "_adb._tcp" || fields[1] == "_adb-tls-connect._tcp",
                  let separator = fields[2].lastIndex(of: ":"),
                  let port = UInt16(fields[2][fields[2].index(after: separator)...]) else { return nil }
            let ip = String(fields[2][..<separator])
            guard ipParts(ip).count == 4 else { return nil }
            return (ip, port)
        }
    }

    private static func adbMDNSServices() async -> [(ip: String, port: UInt16)] {
        guard let output = try? await ADBClient().run(["mdns", "services"]) else { return [] }
        return parseADBMDNS(output)
    }

    static func portOpen(ip: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let queue = DispatchQueue(label: "ADBDeck.probe.\(ip).\(port)")
            let oneShot = OneShot()
            let finish: @Sendable (Bool) -> Void = { result in
                guard oneShot.claim() else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(550)) { finish(false) }
        }
    }

    static func castDetails(ip: String) async -> CastDetails {
        guard let url = URL(string: "http://\(ip):8008/setup/eureka_info?params=name,ssdp") else { return CastDetails(name: nil, identifier: nil) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return CastDetails(name: nil, identifier: nil) }
        return CastDetails(name: json["name"] as? String, identifier: json["ssdp_udn"] as? String)
    }

    static func castServiceModels() async -> [String: String] {
        await withCheckedContinuation { continuation in
            let browser = NWBrowser(for: .bonjour(type: "_googlecast._tcp", domain: "local."), using: .tcp)
            let queue = DispatchQueue(label: "ADBDeck.cast-browser")
            let collector = CastServiceCollector()
            let oneShot = OneShot()
            let finish: @Sendable () -> Void = {
                guard oneShot.claim() else { return }
                browser.cancel()
                continuation.resume(returning: collector.snapshot)
            }
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case let .service(instance, _, _, _) = result.endpoint,
                          let separator = instance.lastIndex(of: "-") else { continue }
                    let identifier = String(instance[instance.index(after: separator)...]).lowercased()
                    let model = String(instance[..<separator]).replacingOccurrences(of: "-", with: " ")
                    guard identifier.count >= 16, !model.isEmpty else { continue }
                    collector.add(identifier: identifier, model: model)
                }
            }
            browser.stateUpdateHandler = { state in if case .failed = state { finish() } }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(700), execute: finish)
        }
    }

    static func arpTable() async -> [String: String] {
        await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
            process.arguments = ["-an"]
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return [:] }
            process.waitUntilExit()
            return parseARP(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }.value
    }

    static func parseDefaultGateway(_ output: String) -> String? {
        output.split(separator: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("gateway:") }?
            .split(separator: ":", maxSplits: 1).last.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    static func defaultGateway() async -> String? {
        await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/sbin/route")
            process.arguments = ["-n", "get", "default"]
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return nil }
            process.waitUntilExit()
            return parseDefaultGateway(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }.value
    }

    static func fingerprint(_ ips: [String]) async -> [String: Set<UInt16>] {
        let ports: [UInt16] = [22, 445, 554, 631, 9100, 62078]
        return await withTaskGroup(of: (String, UInt16, Bool).self, returning: [String: Set<UInt16>].self) { group in
            for ip in ips { for port in ports { group.addTask { (ip, port, await portOpen(ip: ip, port: port)) } } }
            var result: [String: Set<UInt16>] = [:]
            for await (ip, port, isOpen) in group where isOpen { result[ip, default: []].insert(port) }
            return result
        }
    }

    static func parseARP(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(separator: "\n") where !line.contains("incomplete") {
            let fields = line.split(separator: " ")
            guard fields.count >= 4 else { continue }
            let ip = fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            let mac = String(fields[3])
            let octets = ipParts(ip)
            guard octets.count == 4, (0..<224).contains(octets[0]), octets[3] != 255, mac.contains(":") else { continue }
            result[ip] = mac
        }
        return result
    }

    static func ipParts(_ ip: String) -> [Int] { ip.split(separator: ".").compactMap { Int($0) } }

    static func normalizedCastModel(_ model: String) -> String {
        let value = model.lowercased()
        if value.contains("onn") && value.contains("plus") { return "onn. 4K Plus Streaming" }
        if value.contains("onn") && value.contains("4k") { return "onn. 4K Streaming" }
        if value.contains("mi tv stick") { return "Xiaomi Mi TV Stick" }
        return model
    }
}

private extension Collection {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

@MainActor
@Observable
final class DeviceManager {
    var devices: [AndroidDevice] = []
    var selection: String?
    var apps: [DeviceApp] = []
    var isRefreshing = false
    var isWorking = false
    var statusMessage = "Ready"
    var showSystemApps = false
    var transfer: TransferStatus?
    var files: [RemoteFile] = []
    var currentPath = "/sdcard"
    var fileClipboard: RemoteClipboard?
    var lastError: OperationFailure?
    var optimizationResult: OptimizationResult?
    var pendingReplacement: InstallRequest?
    var storage: DeviceStorage?
    var performance: DevicePerformance?
    var performanceError: String?
    var powerState = DevicePowerState.unknown
    var isLoadingFolderSizes = false
    var recentlyAddedApps: Set<String> = []
    var removingApps: Set<String> = []
    var foregroundPackage: String?
    var recentPackages: [String] = []
    var isLoadingActivity = false
    var launchers: [DeviceLauncher] = []
    var currentLauncher: String?
    var isLoadingLaunchers = false
    var screenCapture: ScreenCapture?
    var isCapturingScreen = false
    var screenCaptureError: String?
    var appInspection: AppInspection?
    var isLoadingInspection = false
    var mediaSession: MediaSessionInfo?

    private let adb = ADBClient()
    private var previousCPU: [String: CPUTicks] = [:]
    private var folderSizeRequestID = UUID()
    private var loadedAppsDeviceID: String?
    private var loadedSystemAppsSetting = false

    var selectedDevice: AndroidDevice? { devices.first { $0.id == selection } }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let ownsActivity = beginActivity("Locating devices", detail: "Scanning the local network")
        defer { endActivity(ownsActivity) }
        statusMessage = "Scanning the local network…"
        let hosts = await NetworkDiscovery.discover()
        var results: [AndroidDevice] = []

        for host in hosts {
            var device = AndroidDevice(
                id: host.ip,
                adbPort: host.adbPort ?? 5555,
                name: host.castName ?? "Device \(host.ip.split(separator: ".").last ?? "")",
                manufacturer: estimateBrand(from: [host.castName, host.castModel].compactMap { $0 }.joined(separator: " "), macAddress: host.mac),
                model: host.castModel ?? (host.castOpen ? "Google Cast device" : "Unknown"),
                macAddress: host.mac,
                adbState: host.adbOpen ? .available : .disabled,
                isAndroidLikely: host.adbOpen || host.castOpen,
                hasCast: host.castOpen,
                openPorts: host.openPorts,
                isGateway: host.isGateway
            )
            applyRememberedIdentity(to: &device)
            if host.adbOpen { await enrichWithADB(&device) }
            results.append(device)
        }

        results.sort(by: AndroidDevice.sidebarOrder)
        withAnimation(.snappy) { devices = results }
        if selection == nil || !results.contains(where: { $0.id == selection }) {
            selection = results.first { $0.isAndroidLikely }?.id ?? results.first?.id
        }
        isRefreshing = false
        statusMessage = "Found \(results.count) network device\(results.count == 1 ? "" : "s")"
        await loadApps()
    }

    func addDevice(_ address: String) async {
        let ip = address.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ":5555", with: "")
        let octets = NetworkDiscovery.ipParts(ip)
        guard octets.count == 4, octets.allSatisfy({ 0...255 ~= $0 }) else {
            statusMessage = "Enter a valid IPv4 address"
            return
        }
        let ownsActivity = beginActivity("Connecting to \(ip)", detail: "Checking ADB availability")
        defer { endActivity(ownsActivity) }
        var device = AndroidDevice(id: ip, name: "Android device", manufacturer: "Unknown", model: "Unknown", adbState: .available, isAndroidLikely: true, hasCast: false)
        await enrichWithADB(&device)
        if let index = devices.firstIndex(where: { $0.id == ip }) { devices[index] = device } else { devices.append(device) }
        selection = ip
        await loadApps()
    }

    func connectSelected() async {
        guard var device = selectedDevice else { return }
        let ownsActivity = beginActivity("Connecting to \(device.name)", detail: device.serial)
        defer { endActivity(ownsActivity) }
        await enrichWithADB(&device)
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device }
        await loadApps()
    }

    func loadApps() async {
        guard let device = selectedDevice, device.adbState.isUsable else {
            storage = nil
            apps = []
            loadedAppsDeviceID = nil
            return
        }
        let isSameList = loadedAppsDeviceID == device.id && loadedSystemAppsSetting == showSystemApps
        let previousPackages = isSameList ? Set(apps.map(\.packageName)) : []
        let previousStorage = isSameList ? Dictionary(uniqueKeysWithValues: apps.compactMap { app in
            app.storage.map { (app.packageName, $0) }
        }) : [:]
        if !isSameList {
            storage = nil
            apps = []
            recentlyAddedApps = []
            removingApps = []
        }
        let ownsActivity = beginActivity("Loading apps", detail: "Reading packages from \(device.name)")
        defer { endActivity(ownsActivity) }
        do {
            async let userTask = packages(on: device, system: false)
            async let metadataTask = try? adb.run(["-s", device.serial, "shell", "dumpsys package packages | grep -E '^  Package \\[|firstInstallTime=|lastUpdateTime='"])
            let system = showSystemApps ? try await packages(on: device, system: true) : []
            let user = try await userTask
            let metadataOutput: String? = await metadataTask
            let dates = PackageMetadataParser.dates(metadataOutput ?? "")
            guard selectedDevice?.id == device.id else { return }
            var loaded: [DeviceApp] = user + system
            for index in loaded.indices {
                loaded[index].installedAt = dates[loaded[index].packageName]?.installed
                loaded[index].updatedAt = dates[loaded[index].packageName]?.updated
            }
            var snapshot: (device: DeviceStorage, apps: [String: AppStorage])?
            do {
                snapshot = try await storageSnapshot(on: device, apps: loaded)
            } catch {
                report(error, operation: "Read storage")
            }
            guard selectedDevice?.id == device.id else { return }
            for index in loaded.indices {
                loaded[index].storage = snapshot?.apps[loaded[index].packageName] ?? previousStorage[loaded[index].packageName]
            }
            loaded.sort { $0.packageName.localizedCaseInsensitiveCompare($1.packageName) == .orderedAscending }
            let added = previousPackages.isEmpty ? [] : Set(loaded.map(\.packageName)).subtracting(previousPackages)
            withAnimation(.smooth) {
                apps = loaded
                if let snapshot { storage = snapshot.device }
                recentlyAddedApps.formUnion(added)
            }
            loadedAppsDeviceID = device.id
            loadedSystemAppsSetting = showSystemApps
            statusMessage = "Loaded \(apps.count) app\(apps.count == 1 ? "" : "s")"
            if !added.isEmpty {
                statusMessage = "Added \(added.count) app\(added.count == 1 ? "" : "s")"
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard selectedDevice?.id == device.id else { return }
                    withAnimation(.smooth) { recentlyAddedApps.subtract(added) }
                }
            }
        } catch { report(error, operation: "Load apps") }
    }

    @discardableResult
    func loadStorage() async -> Bool {
        guard let device = selectedDevice, device.adbState.isUsable else { storage = nil; return false }
        let ownsActivity = beginActivity("Reading storage", detail: device.name)
        defer { endActivity(ownsActivity) }
        do {
            let snapshot = try await storageSnapshot(on: device, apps: apps)
            guard selectedDevice?.id == device.id else { return false }
            storage = snapshot.device
            apps = apps.map { app in
                var app = app
                app.storage = snapshot.apps[app.packageName]
                return app
            }
            return true
        } catch {
            report(error, operation: "Read storage")
            return false
        }
    }

    func loadPerformance() async {
        guard !isWorking, !isRefreshing else { return }
        guard let device = selectedDevice, device.adbState.isUsable else {
            performance = nil
            performanceError = nil
            powerState = .unknown
            return
        }
        do {
            let output = try await adb.run(["-s", device.serial, "shell", "grep '^cpu ' /proc/stat; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo; dumpsys power | grep -E 'mWakefulness=|Display Power: state=' || true"])
            guard let sample = PerformanceParser.sample(output) else {
                throw ADBError.commandFailed("Android returned an unsupported CPU or memory report.\n\n\(output)")
            }
            guard selectedDevice?.id == device.id else { return }
            performance = PerformanceParser.performance(sample, after: previousCPU[device.id])
            powerState = DevicePowerState.parse(output)
            previousCPU[device.id] = sample.cpu
            performanceError = nil
        } catch {
            performance = nil
            performanceError = error.localizedDescription
        }
    }

    func performPowerAction(_ action: DevicePowerAction) async {
        guard let device = selectedDevice, device.adbState.isUsable else {
            report(ADBError.commandFailed("Select and connect an authorized ADB device first."), operation: action.title)
            return
        }
        guard action != .download || device.supportsDownloadMode else {
            report(ADBError.commandFailed("Download Mode is vendor-specific and is only offered for identified Samsung devices."), operation: action.title)
            return
        }
        let ownsActivity = beginActivity(action.title, detail: action.disconnects ? "Preparing \(device.name)" : "Sending to \(device.name)", fraction: 0.2)
        defer { endActivity(ownsActivity) }
        do {
            _ = try await adb.run(action.arguments(serial: device.serial))
            transfer?.fraction = 1
            if action.disconnects {
                markOffline(device.id)
                statusMessage = "\(action.title) sent to \(device.name)"
            } else {
                powerState = action == .wake ? .awake : .asleep
                statusMessage = "\(action.title) sent to \(device.name)"
            }
        } catch {
            if action.disconnects, error.localizedDescription.localizedCaseInsensitiveContains("error: closed") {
                markOffline(device.id)
                statusMessage = "\(action.title) sent to \(device.name)"
            } else {
                report(error, operation: "\(action.title) \(device.name)")
            }
        }
    }

    private func markOffline(_ deviceID: String) {
        if let index = devices.firstIndex(where: { $0.id == deviceID }) { devices[index].adbState = .offline }
        apps = []
        files = []
        storage = nil
        performance = nil
        performanceError = nil
        powerState = .unknown
        loadedAppsDeviceID = nil
    }

    func optimizeDevice() async {
        guard let device = selectedDevice, device.adbState.isUsable else {
            report(ADBError.commandFailed("Select and connect an authorized ADB device before optimizing it."), operation: "Optimize device")
            return
        }
        let freeBefore = storage?.free
        let memoryBefore = performance?.memoryUsed
        optimizationResult = nil
        let ownsActivity = beginActivity("Optimizing \(device.name)", detail: "Closing cached background apps", fraction: 0.15)
        do {
            _ = try await adb.run(["-s", device.serial, "shell", "am kill-all"])
            if let storage, storage.isLow {
                transfer?.detail = "Reclaiming temporary cache space"
                transfer?.fraction = 0.5
                let targetFreeBytes = max(storage.total / 5, storage.free)
                _ = try await adb.run(["-s", device.serial, "shell", "pm trim-caches \(targetFreeBytes)"])
            } else {
                transfer?.detail = "Storage is healthy; temporary caches kept"
                transfer?.fraction = 0.65
            }
            transfer?.detail = "Refreshing storage and memory"
            transfer?.fraction = 0.85
            endActivity(ownsActivity)
            guard await loadStorage() else { return }
            await loadPerformance()
            guard selectedDevice?.id == device.id else { return }
            optimizationResult = OptimizationResult(
                freeBefore: freeBefore,
                freeAfter: storage?.free,
                memoryBefore: memoryBefore,
                memoryAfter: performance?.memoryUsed
            )
            statusMessage = "Optimized \(device.name)"
        } catch {
            endActivity(ownsActivity)
            report(error, operation: "Optimize \(device.name)")
        }
    }

    func sendText(_ text: String) async {
        guard let device = selectedDevice, device.adbState.isUsable else {
            report(ADBError.commandFailed("Select and connect an authorized ADB device before sending text."), operation: "Send text")
            return
        }
        do {
            let command = try RemoteInput.command(for: text)
            let ownsActivity = beginActivity("Sending text", detail: "To the focused field on \(device.name)")
            defer { endActivity(ownsActivity) }
            _ = try await adb.run(["-s", device.serial, "shell", command])
            statusMessage = "Sent text to \(device.name)"
        } catch {
            report(error, operation: "Send text to \(device.name)")
        }
    }

    func sendKey(_ keyCode: String, named name: String) async {
        guard let device = selectedDevice, device.adbState.isUsable else {
            report(ADBError.commandFailed("Select and connect an authorized ADB device before sending a key."), operation: "Send \(name)")
            return
        }
        let ownsActivity = beginActivity("Sending \(name)", detail: device.name)
        defer { endActivity(ownsActivity) }
        do {
            _ = try await adb.run(["-s", device.serial, "shell", "input keyevent \(keyCode)"])
            statusMessage = "Sent \(name) to \(device.name)"
        } catch {
            report(error, operation: "Send \(name) to \(device.name)")
        }
    }

    func captureScreen() async {
        guard let device = selectedDevice, device.adbState.isUsable, !isCapturingScreen else { return }
        isCapturingScreen = true
        defer { isCapturingScreen = false }
        do {
            let data = try await adb.runData(["-s", device.serial, "exec-out", "screencap", "-p"])
            guard !data.isEmpty else {
                throw ADBError.commandFailed("The device did not provide a screen image. Protected video, such as DRM playback, or this device's firmware may block capture. Remote controls still work.")
            }
            guard let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
                throw ADBError.commandFailed("The device returned an unreadable screen image.")
            }
            guard selectedDevice?.id == device.id else { return }
            screenCapture = ScreenCapture(data: data, width: bitmap.pixelsWide, height: bitmap.pixelsHigh, capturedAt: .now)
            screenCaptureError = nil
        } catch {
            screenCaptureError = error.localizedDescription
            statusMessage = "Screen capture failed"
        }
    }

    func loadMediaSession() async {
        guard let device = selectedDevice, device.adbState.isUsable else { mediaSession = nil; return }
        do {
            let output = try await adb.run(["-s", device.serial, "shell", "dumpsys media_session"])
            guard selectedDevice?.id == device.id else { return }
            mediaSession = MediaSessionParser.parse(output)
        } catch { mediaSession = nil }
    }

    func tapScreen(x: Int, y: Int) async {
        guard let device = selectedDevice, let capture = screenCapture, device.adbState.isUsable else { return }
        let x = min(max(x, 0), capture.width - 1)
        let y = min(max(y, 0), capture.height - 1)
        do {
            _ = try await adb.run(["-s", device.serial, "shell", "input tap \(x) \(y)"])
            try? await Task.sleep(for: .milliseconds(180))
            await captureScreen()
        } catch { report(error, operation: "Tap device screen") }
    }

    func loadInspection(for app: DeviceApp) async {
        guard let device = selectedDevice, device.adbState.isUsable, !isLoadingInspection else { return }
        isLoadingInspection = true
        appInspection = nil
        defer { isLoadingInspection = false }
        do {
            async let detailsTask = adb.run(["-s", device.serial, "shell", "dumpsys package \(RemoteFiles.shellQuote(app.packageName))"])
            async let helpTask = adb.run(["-s", device.serial, "shell", "pm help"])
            let (details, help) = try await (detailsTask, helpTask)
            guard selectedDevice?.id == device.id else { return }
            appInspection = AppInspectionParser.parse(details, supportsCacheOnlyClear: help.contains("--cache-only"))
            statusMessage = "Inspected \(app.displayName)"
        } catch { report(error, operation: "Inspect \(app.displayName)") }
    }

    func setPermission(_ permission: AppPermission, granted: Bool, for app: DeviceApp) async {
        guard let device = selectedDevice, device.adbState.isUsable else { return }
        let verb = granted ? "Grant" : "Revoke"
        let ownsActivity = beginActivity("\(verb) permission", detail: permission.shortName)
        defer { endActivity(ownsActivity) }
        do {
            _ = try await adb.run(["-s", device.serial, "shell", "pm \(granted ? "grant" : "revoke") --user 0 \(RemoteFiles.shellQuote(app.packageName)) \(RemoteFiles.shellQuote(permission.name))"])
            await loadInspection(for: app)
            statusMessage = "\(granted ? "Granted" : "Revoked") \(permission.shortName)"
        } catch { report(error, operation: "\(verb) \(permission.shortName)") }
    }

    func clearCache(for app: DeviceApp) async {
        guard let device = selectedDevice, device.adbState.isUsable, appInspection?.supportsCacheOnlyClear == true else { return }
        await clearPackage(app, command: "pm clear --user 0 --cache-only", title: "Clear cache")
    }

    func clearData(for app: DeviceApp) async {
        guard selectedDevice?.adbState.isUsable == true else { return }
        await clearPackage(app, command: "pm clear --user 0", title: "Clear app data")
    }

    private func clearPackage(_ app: DeviceApp, command: String, title: String) async {
        guard let device = selectedDevice else { return }
        let ownsActivity = beginActivity(title, detail: app.displayName)
        defer { endActivity(ownsActivity) }
        do {
            let output = try await adb.run(["-s", device.serial, "shell", "\(command) \(RemoteFiles.shellQuote(app.packageName))"])
            guard output.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Success" }) else {
                throw ADBError.commandFailed("Android did not confirm the operation.\n\nDevice response:\n\(output.nilIfEmpty ?? "No details returned.")")
            }
            await loadInspection(for: app)
            _ = await loadStorage()
            statusMessage = "\(title) completed for \(app.displayName)"
        } catch { report(error, operation: "\(title) for \(app.displayName)") }
    }

    func install(_ url: URL, mode: InstallMode = .new) async {
        guard let device = selectedDevice, device.adbState.isUsable else {
            report(ADBError.commandFailed("Select and connect an authorized ADB device before installing an app."), operation: "Install app")
            return
        }
        lastError = nil
        let fileExtension = url.pathExtension.lowercased()
        guard ["apk", "adbdeck"].contains(fileExtension) else {
            report(ADBError.commandFailed("Choose an .apk or .adbdeck app package."), operation: "Open \(url.lastPathComponent)")
            return
        }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
            report(ADBError.commandFailed("The selected package is empty, unavailable, or is not a regular file."), operation: "Open \(url.lastPathComponent)")
            return
        }
        let ownsActivity = beginActivity("Checking \(url.lastPathComponent)", detail: "Validating package on \(device.name)")
        let packageName: String
        var removedExistingApp = false
        do {
            let metadata = try await packageMetadata(in: url)
            packageName = metadata.packageName
            let output = try await adb.run(["-s", device.serial, "shell", "pm", "list", "packages", packageName])
            let installed = output.split(separator: "\n").contains("package:\(packageName)")
            if installed && mode == .new {
                let details = try await adb.run(["-s", device.serial, "shell", "dumpsys package \(RemoteFiles.shellQuote(packageName))"])
                endActivity(ownsActivity)
                pendingReplacement = InstallRequest(url: url, packageName: packageName, incoming: metadata.version, installed: PackageVersionParser.version(details))
                return
            }
            if installed && mode == .replace {
                transfer = TransferStatus(title: "Replacing \(packageName)", detail: "Removing the installed app and its data", fraction: nil)
                let uninstall = try await adb.run(["-s", device.serial, "uninstall", packageName])
                try InstallOutput.requireSuccess(uninstall)
                removedExistingApp = true
                withAnimation(.smooth) { apps.removeAll { $0.packageName == packageName } }
            }
        } catch {
            endActivity(ownsActivity)
            report(error, operation: "Validate \(url.lastPathComponent)")
            return
        }
        endActivity(ownsActivity)
        if fileExtension == "adbdeck" {
            await installBackup(url, packageName: packageName, removedExistingApp: removedExistingApp, on: device)
            return
        }
        isWorking = true
        let serial = device.serial
        let remote = "/data/local/tmp/adbdeck-\(UUID().uuidString).apk"
        transfer = TransferStatus(title: "Installing \(url.lastPathComponent)", detail: "Uploading to \(device.name)", fraction: nil)
        statusMessage = "Installing \(url.lastPathComponent)…"
        do {
            _ = try await adb.runStreaming(["-s", serial, "push", url.path, remote], progress: progressHandler(from: 0, to: 0.88))
            transfer = TransferStatus(title: "Installing \(url.lastPathComponent)", detail: "Verifying package on \(device.name)", fraction: 0.92)
            let output = try await adb.run(["-s", serial, "shell", "pm", "install", "-r", remote])
            try InstallOutput.requireSuccess(output, removedExistingApp: removedExistingApp)
            try await verifyInstalled(packageName, on: device)
            _ = try? await adb.run(["-s", serial, "shell", "rm", remote])
            transfer?.fraction = 1
            statusMessage = "Installed \(url.lastPathComponent)"
            await loadApps()
        } catch {
            _ = try? await adb.run(["-s", serial, "shell", "rm", remote])
            report(installationError(error, removedExistingApp: removedExistingApp), operation: "Install \(url.lastPathComponent)")
        }
        try? await Task.sleep(for: .milliseconds(450))
        transfer = nil
        isWorking = false
    }

    private func packageMetadata(in archive: URL) async throws -> APKMetadata {
        if archive.pathExtension.lowercased() == "adbdeck" {
            return try await validatedBackup(at: archive)
        }
        return try APKManifest.metadata(in: await archiveEntry("AndroidManifest.xml", in: archive))
    }

    private func validatedBackup(at archive: URL) async throws -> APKMetadata {
        let entries = try await runLocalOutput("/usr/bin/unzip", ["-Z1", archive.path])
        guard entries.split(separator: "\n").allSatisfy({ entry in
            !entry.hasPrefix("/") && !entry.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        }) else { throw ADBError.commandFailed("The ADB Deck package contains an unsafe file path.") }

        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ADBDeck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await runLocal("/usr/bin/ditto", ["-x", "-k", archive.path, workspace.path])
        let manifestURL = workspace.appendingPathComponent(AppBackup.manifestName)
        guard FileManager.default.isReadableFile(atPath: manifestURL.path) else {
            throw ADBError.commandFailed("This file is not an ADB Deck app package: \(AppBackup.manifestName) is missing.")
        }
        let manifest: AppBackup.Manifest
        do {
            manifest = try JSONDecoder().decode(AppBackup.Manifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw ADBError.commandFailed("The ADB Deck package manifest is damaged or unreadable.")
        }
        let apks = try AppBackup.apkURLs(for: manifest, in: workspace)
        var baseMetadata: APKMetadata?
        for apk in apks {
            let metadata = try APKManifest.metadata(in: await archiveEntry("AndroidManifest.xml", in: apk))
            guard metadata.packageName == manifest.packageName else {
                throw ADBError.commandFailed("\(apk.lastPathComponent) belongs to \(metadata.packageName), not \(manifest.packageName).")
            }
            if apk.lastPathComponent == "base.apk" || baseMetadata == nil { baseMetadata = metadata }
        }
        guard let baseMetadata else { throw ADBError.commandFailed("The app package has no readable APK components.") }
        return baseMetadata
    }

    private func archiveEntry(_ entry: String, in archive: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", archive.path, entry]
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let limit = 8 * 1024 * 1024
            let data = try stdout.fileHandleForReading.read(upToCount: limit + 1) ?? Data()
            if data.count > limit {
                process.terminate()
                process.waitUntilExit()
                throw ADBError.commandFailed("The app package manifest is unexpectedly large.")
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0, !data.isEmpty else {
                let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw ADBError.commandFailed(message.nilIfEmpty ?? "The app package does not contain \(entry).")
            }
            return data
        }.value
    }

    func download(_ app: DeviceApp, to directory: URL) async -> URL? {
        guard let device = selectedDevice, device.adbState.isUsable else { return nil }
        isWorking = true
        let serial = device.serial
        transfer = TransferStatus(title: "Downloading \(app.displayName)", detail: "Reading package paths", fraction: nil)
        statusMessage = "Downloading \(app.packageName)…"
        do {
            let output = try await adb.run(["-s", serial, "shell", "pm", "path", app.packageName])
            let paths = output.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("package:") else { return nil }
                return String(line.dropFirst(8))
            }
            guard !paths.isEmpty else { throw ADBError.commandFailed("The device did not return an APK path.") }

            let name = AppBackup.safeName(app.displayName)
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ADBDeck-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workspace) }
            for (index, remote) in paths.enumerated() {
                let fileName = paths.count == 1 ? "\(app.packageName).apk" : URL(fileURLWithPath: remote).lastPathComponent
                let local = workspace.appendingPathComponent(fileName)
                transfer?.detail = paths.count == 1 ? "Downloading APK" : "Downloading \(index + 1) of \(paths.count) APKs"
                let start = Double(index) / Double(paths.count)
                let end = paths.count == 1 ? 1 : Double(index + 1) / Double(paths.count + 1)
                _ = try await adb.runStreaming(["-s", serial, "pull", remote, local.path], progress: progressHandler(from: start, to: end))
            }
            let destination: URL
            if paths.count == 1 {
                destination = availableURL(named: name, extension: "apk", in: directory)
                try FileManager.default.moveItem(at: workspace.appendingPathComponent("\(app.packageName).apk"), to: destination)
            } else {
                let files = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
                let manifest = AppBackup.Manifest(formatVersion: 1, packageName: app.packageName, displayName: app.displayName, files: files)
                let data = try JSONEncoder().encode(manifest)
                try data.write(to: workspace.appendingPathComponent(AppBackup.manifestName), options: .atomic)
                destination = availableURL(named: name, extension: "adbdeck", in: directory)
                transfer?.detail = "Bundling \(paths.count) APK components"
                try await runLocal("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", workspace.path, destination.path])
            }
            transfer?.fraction = 1
            statusMessage = "Saved installable \(destination.lastPathComponent)"
            try? await Task.sleep(for: .milliseconds(450))
            transfer = nil
            isWorking = false
            return destination
        } catch {
            report(error, operation: "Download \(app.displayName) APK")
            transfer = nil
            isWorking = false
            return nil
        }
    }

    private func installBackup(_ archive: URL, packageName: String, removedExistingApp: Bool, on device: AndroidDevice) async {
        isWorking = true
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ADBDeck-\(UUID().uuidString)", isDirectory: true)
        transfer = TransferStatus(title: "Installing \(archive.deletingPathExtension().lastPathComponent)", detail: "Opening app package", fraction: 0.05)
        statusMessage = "Installing \(archive.lastPathComponent)…"
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workspace) }
            try await runLocal("/usr/bin/ditto", ["-x", "-k", archive.path, workspace.path])
            guard let manifestURL = try FileManager.default.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil)
                .first(where: { $0.lastPathComponent == AppBackup.manifestName }) else {
                throw ADBError.commandFailed("This file is not an ADB Deck app package.")
            }
            let manifest = try JSONDecoder().decode(AppBackup.Manifest.self, from: Data(contentsOf: manifestURL))
            let apks = try AppBackup.apkURLs(for: manifest, in: workspace)
            transfer = TransferStatus(title: "Installing \(manifest.displayName)", detail: "Sending \(apks.count) APK components to \(device.name)", fraction: 0.2)
            let output = try await adb.runStreaming(["-s", device.serial, "install-multiple", "-r"] + apks.map(\.path), progress: progressHandler(from: 0.2, to: 1))
            try InstallOutput.requireSuccess(output, removedExistingApp: removedExistingApp)
            try await verifyInstalled(packageName, on: device)
            transfer?.fraction = 1
            statusMessage = "Installed \(manifest.displayName)"
            await loadApps()
        } catch {
            report(installationError(error, removedExistingApp: removedExistingApp), operation: "Install \(archive.lastPathComponent)")
        }
        try? await Task.sleep(for: .milliseconds(450))
        transfer = nil
        isWorking = false
    }

    private func availableURL(named name: String, extension fileExtension: String, in directory: URL) -> URL {
        let first = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        for number in 2...999 {
            let candidate = directory.appendingPathComponent("\(name) \(number)").appendingPathExtension(fileExtension)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(name) \(UUID().uuidString)").appendingPathExtension(fileExtension)
    }

    private func runLocal(_ executable: String, _ arguments: [String]) async throws {
        _ = try await runLocalOutput(executable, arguments)
    }

    private func runLocalOutput(_ executable: String, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ADBError.commandFailed(output.nilIfEmpty ?? "Could not create or open the app package.")
            }
            return output
        }.value
    }

    func uninstall(_ app: DeviceApp) async {
        guard let device = selectedDevice else { return }
        let ownsActivity = beginActivity("Removing \(app.displayName)", detail: "From \(device.name)")
        _ = withAnimation(.smooth) { removingApps.insert(app.packageName) }
        defer {
            endActivity(ownsActivity)
            _ = withAnimation(.smooth) { removingApps.remove(app.packageName) }
        }
        do {
            _ = try await adb.run(["-s", device.serial, "uninstall", app.packageName])
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.smooth) { apps.removeAll { $0.packageName == app.packageName } }
            statusMessage = "Removed \(app.displayName)"
            await loadApps()
        } catch { report(error, operation: "Remove \(app.displayName)") }
    }

    func launch(_ app: DeviceApp) async {
        guard let device = selectedDevice else { return }
        let ownsActivity = beginActivity("Opening \(app.displayName)", detail: "On \(device.name)")
        defer { endActivity(ownsActivity) }
        do {
            _ = try await adb.run(["-s", device.serial, "shell", "monkey -p \(app.packageName) -c android.intent.category.LAUNCHER 1"])
            statusMessage = "Opened \(app.displayName)"
            try? await Task.sleep(for: .milliseconds(250))
            await loadActivity()
        } catch { report(error, operation: "Open \(app.displayName)") }
    }

    func loadActivity() async {
        guard let device = selectedDevice, device.adbState.isUsable else {
            foregroundPackage = nil
            recentPackages = []
            return
        }
        guard !isLoadingActivity else { return }
        isLoadingActivity = true
        defer { isLoadingActivity = false }
        do {
            async let currentTask = adb.run(["-s", device.serial, "shell", "dumpsys activity activities"])
            async let recentTask = adb.run(["-s", device.serial, "shell", "dumpsys activity recents"])
            let (currentOutput, recentOutput) = try await (currentTask, recentTask)
            guard selectedDevice?.id == device.id else { return }
            let installed = Set(apps.map(\.packageName))
            let current = ActivityParser.foreground(currentOutput).flatMap { installed.contains($0) ? $0 : nil }
            let recent = ActivityParser.recents(recentOutput).filter { installed.contains($0) && $0 != current }
            withAnimation(.smooth) {
                foregroundPackage = current
                recentPackages = recent
            }
            statusMessage = current.map { "\(DeviceApp(packageName: $0, isSystem: false).displayName) is open" } ?? "No managed app is in front"
        } catch {
            report(error, operation: "Read device activity")
        }
    }

    func backgroundCurrentApp() async {
        guard let device = selectedDevice, device.adbState.isUsable else { return }
        let ownsActivity = beginActivity("Backgrounding app", detail: device.name)
        defer { endActivity(ownsActivity) }
        do {
            _ = try await adb.run(["-s", device.serial, "shell", "input keyevent KEYCODE_HOME"])
            try? await Task.sleep(for: .milliseconds(250))
            await loadActivity()
            statusMessage = "Moved the current app to the background"
        } catch {
            report(error, operation: "Background current app")
        }
    }

    func forceQuit(_ app: DeviceApp) async {
        guard let device = selectedDevice, device.adbState.isUsable else { return }
        let ownsActivity = beginActivity("Force quitting \(app.displayName)", detail: device.name)
        defer { endActivity(ownsActivity) }
        do {
            _ = try await adb.run(["-s", device.serial, "shell", "am force-stop \(RemoteFiles.shellQuote(app.packageName))"])
            try? await Task.sleep(for: .milliseconds(250))
            await loadActivity()
            statusMessage = "Force quit \(app.displayName)"
        } catch {
            report(error, operation: "Force quit \(app.displayName)")
        }
    }

    func loadLaunchers() async {
        guard let device = selectedDevice, device.adbState.isUsable else {
            launchers = []
            currentLauncher = nil
            return
        }
        guard !isLoadingLaunchers else { return }
        isLoadingLaunchers = true
        defer { isLoadingLaunchers = false }
        do {
            let intent = "-a android.intent.action.MAIN -c android.intent.category.HOME"
            async let choicesTask = adb.run(["-s", device.serial, "shell", "cmd package query-activities --brief --components \(intent)"])
            async let currentTask = adb.run(["-s", device.serial, "shell", "cmd package resolve-activity --brief --components \(intent)"])
            let (choicesOutput, currentOutput) = try await (choicesTask, currentTask)
            guard selectedDevice?.id == device.id else { return }
            let current = LauncherParser.components(currentOutput).first
            launchers = LauncherParser.components(choicesOutput)
                .map { DeviceLauncher(component: $0, name: LauncherParser.name(for: $0, apps: apps)) }
                .sorted {
                    if ($0.component == current) != ($1.component == current) { return $0.component == current }
                    if $0.isFallback != $1.isFallback { return !$0.isFallback }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            currentLauncher = current
            statusMessage = "Found \(launchers.filter { !$0.isFallback }.count) launcher\(launchers.filter { !$0.isFallback }.count == 1 ? "" : "s")"
        } catch { report(error, operation: "Detect launchers") }
    }

    func setDefaultLauncher(_ launcher: DeviceLauncher) async {
        guard let device = selectedDevice, device.adbState.isUsable else { return }
        guard launchers.contains(launcher), !launcher.isFallback else {
            report(ADBError.commandFailed("Android recovery and starter activities cannot be selected as the everyday launcher."), operation: "Change launcher")
            return
        }
        let ownsActivity = beginActivity("Changing launcher", detail: launcher.name, fraction: 0.2)
        defer { endActivity(ownsActivity) }
        do {
            let output = try await adb.run(["-s", device.serial, "shell", "cmd package set-home-activity --user 0 \(RemoteFiles.shellQuote(launcher.component))"])
            transfer?.fraction = 0.7
            try? await Task.sleep(for: .milliseconds(500))
            let intent = "-a android.intent.action.MAIN -c android.intent.category.HOME"
            let resolved = try await adb.run(["-s", device.serial, "shell", "cmd package resolve-activity --brief --components \(intent)"])
            let actual = LauncherParser.components(resolved).first
            guard actual == launcher.component else {
                let note = device.kind == .fireTV ? "Fire OS refused the default-home change. Amazon firmware may lock Fire TV Home; ADB Deck did not disable protected system packages." : "Android kept \(actual ?? "an unknown launcher") as the default."
                throw ADBError.commandFailed("\(note)\n\nRequested: \(launcher.component)\nDevice response: \(output.isEmpty ? "No response" : output)")
            }
            transfer?.fraction = 0.9
            _ = try await adb.run(["-s", device.serial, "shell", "input keyevent KEYCODE_HOME"])
            currentLauncher = launcher.component
            transfer?.fraction = 1
            statusMessage = "\(launcher.name) is now the default launcher"
        } catch { report(error, operation: "Use \(launcher.name)") }
    }

    func loadFiles(at path: String? = nil) async {
        guard let device = selectedDevice, device.adbState.isUsable else { files = []; return }
        let target = path ?? currentPath
        guard target.hasPrefix("/"), !target.contains("\n") else { statusMessage = "Invalid device path"; return }
        currentPath = target
        files = []
        folderSizeRequestID = UUID()
        isLoadingFolderSizes = false
        let ownsActivity = beginActivity("Opening folder", detail: target)
        defer { endActivity(ownsActivity) }
        do {
            let output = try await adb.run(["-s", device.serial, "shell", "ls -la \(RemoteFiles.shellQuote(target))"])
            guard selectedDevice?.id == device.id, currentPath == target else { return }
            withAnimation(.smooth) { files = RemoteFiles.parse(output, in: target) }
            statusMessage = "Loaded \(files.count) item\(files.count == 1 ? "" : "s")"
            let folders = files.filter { $0.isDirectory }.map(\.path)
            if !folders.isEmpty {
                let requestID = UUID()
                folderSizeRequestID = requestID
                Task { await loadFolderSizes(folders, for: device, at: target, requestID: requestID) }
            }
        } catch { report(error, operation: "Browse \(target)") }
    }

    private func loadFolderSizes(_ folders: [String], for device: AndroidDevice, at path: String, requestID: UUID) async {
        guard folderSizeRequestID == requestID else { return }
        isLoadingFolderSizes = true
        defer {
            if folderSizeRequestID == requestID { isLoadingFolderSizes = false }
        }
        let arguments = folders.map(RemoteFiles.shellQuote).joined(separator: " ")
        guard let output = try? await adb.run(["-s", device.serial, "shell", "du -sk \(arguments) 2>/dev/null; true"]),
              folderSizeRequestID == requestID,
              selectedDevice?.id == device.id,
              currentPath == path else { return }
        let sizes = RemoteFiles.directorySizes(output)
        withAnimation(.smooth) {
            files = files.map { file in
                var updated = file
                updated.measuredSize = sizes[file.path]
                return updated
            }
        }
    }

    func createFolder(named name: String) async {
        guard RemoteFiles.validName(name) else { statusMessage = "Enter a valid folder name"; return }
        await mutateFiles("mkdir \(RemoteFiles.shellQuote(RemoteFiles.joined(currentPath, name)))", success: "Created \(name)")
    }

    func rename(_ file: RemoteFile, to name: String) async {
        guard RemoteFiles.validName(name) else { statusMessage = "Enter a valid name"; return }
        let destination = RemoteFiles.joined(RemoteFiles.parent(of: file.path), name)
        await moveOrCopy(file, to: destination, operation: .move)
    }

    func delete(_ file: RemoteFile) async {
        guard !RemoteFiles.protectedRoots.contains(file.path) else { statusMessage = "ADB Deck will not remove a device storage root"; return }
        await mutateFiles("rm -rf \(RemoteFiles.shellQuote(file.path))", success: "Removed \(file.name)")
    }

    func putOnClipboard(_ file: RemoteFile, operation: RemoteClipboard.Operation) {
        fileClipboard = RemoteClipboard(file: file, operation: operation)
        statusMessage = "\(operation.rawValue) \(file.name), then open a destination and paste"
    }

    func pasteFiles() async {
        guard let item = fileClipboard else { return }
        let destination = RemoteFiles.joined(currentPath, item.file.name)
        if await moveOrCopy(item.file, to: destination, operation: item.operation), item.operation == .move {
            fileClipboard = nil
        }
    }

    func upload(_ url: URL) async {
        guard let device = selectedDevice, device.adbState.isUsable else { return }
        let destination = RemoteFiles.joined(currentPath, url.lastPathComponent)
        isWorking = true
        transfer = TransferStatus(title: "Uploading \(url.lastPathComponent)", detail: "To \(currentPath)", fraction: nil)
        statusMessage = "Uploading \(url.lastPathComponent)…"
        do {
            _ = try await adb.runStreaming(["-s", device.serial, "push", url.path, destination], progress: progressHandler(from: 0, to: 1))
            transfer?.fraction = 1
            transfer?.detail = "Refreshing files and storage"
            statusMessage = "Uploaded \(url.lastPathComponent)"
            await loadFiles()
            await loadStorage()
            try? await Task.sleep(for: .milliseconds(350))
        } catch { report(error, operation: "Upload \(url.lastPathComponent)") }
        transfer = nil
        isWorking = false
    }

    func download(_ file: RemoteFile, to directory: URL) async -> URL? {
        guard let device = selectedDevice, device.adbState.isUsable else { return nil }
        let destination = directory.appendingPathComponent(file.name)
        isWorking = true
        transfer = TransferStatus(title: "Downloading \(file.name)", detail: "To \(directory.path)", fraction: nil)
        statusMessage = "Downloading \(file.name)…"
        do {
            _ = try await adb.runStreaming(["-s", device.serial, "pull", file.path, destination.path], progress: progressHandler(from: 0, to: 1))
            transfer?.fraction = 1
            statusMessage = "Saved \(file.name)"
            try? await Task.sleep(for: .milliseconds(350))
            transfer = nil
            isWorking = false
            return destination
        } catch {
            report(error, operation: "Download \(file.name)")
            transfer = nil
            isWorking = false
            return nil
        }
    }

    @discardableResult
    private func moveOrCopy(_ file: RemoteFile, to destination: String, operation: RemoteClipboard.Operation) async -> Bool {
        guard file.path != destination else { statusMessage = "Source and destination are the same"; return false }
        let source = RemoteFiles.shellQuote(file.path)
        let target = RemoteFiles.shellQuote(destination)
        let command = "if [ -e \(target) ]; then echo 'Destination already exists' >&2; exit 1; fi; \(operation == .copy ? "cp -R" : "mv") \(source) \(target)"
        return await mutateFiles(command, success: "\(operation == .copy ? "Copied" : "Moved") \(file.name)")
    }

    @discardableResult
    private func mutateFiles(_ command: String, success: String) async -> Bool {
        guard let device = selectedDevice, device.adbState.isUsable else { return false }
        let ownsActivity = beginActivity(success, detail: "On \(device.name)")
        defer { endActivity(ownsActivity) }
        do {
            _ = try await adb.run(["-s", device.serial, "shell", command])
            statusMessage = success
            await loadFiles()
            await loadStorage()
        } catch {
            report(error, operation: success)
            return false
        }
        return true
    }

    private func enrichWithADB(_ device: inout AndroidDevice) async {
        do {
            let serial = device.serial
            let connection = try await adb.connect(serial)
            let list = try await adb.run(["devices", "-l"])
            if list.split(separator: "\n").contains(where: { $0.hasPrefix(serial) && $0.contains("unauthorized") }) {
                device.adbState = .unauthorized
                statusMessage = "Approve ADB on \(device.name)"
                return
            }
            guard list.split(separator: "\n").contains(where: { $0.hasPrefix(serial) && $0.contains("device") }) else {
                device.adbState = connection.contains("connected") ? .available : .unknown
                return
            }
            device.adbState = .connected
            device.isAndroidLikely = true
            let props = try await adb.run(["-s", serial, "shell", "printf '%s|%s|%s|%s|%s|%s|%s' \"$(getprop ro.product.manufacturer)\" \"$(getprop ro.product.model)\" \"$(getprop ro.product.device)\" \"$(getprop ro.product.cpu.abilist)\" \"$(getprop ro.build.version.release)\" \"$(getprop ro.build.version.sdk)\" \"$(getprop ro.build.characteristics)\""])
            let parts = props.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 7 {
                device.manufacturer = parts[0].isEmpty ? device.manufacturer : parts[0]
                device.model = parts[1].isEmpty ? device.model : parts[1]
                device.name = parts[1].isEmpty ? device.name : parts[1]
                device.supportedABIs = parts[3].nilIfEmpty
                device.androidVersion = parts[4].nilIfEmpty
                device.apiLevel = parts[5].nilIfEmpty
                device.androidCharacteristics = parts[6].nilIfEmpty
                rememberIdentity(device)
            }
        } catch {
            device.adbState = .available
            report(error, operation: "Connect to \(device.id)")
        }
    }

    private func report(_ error: Error, operation: String) {
        let details = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = OperationFailure(operation: operation, details: details.isEmpty ? "The operation failed without an error message." : details, device: selectedDevice)
        statusMessage = "\(operation) failed"
    }

    private func verifyInstalled(_ packageName: String, on device: AndroidDevice) async throws {
        let output = try await adb.run(["-s", device.serial, "shell", "pm", "path", packageName])
        guard output.split(separator: "\n").contains(where: {
            let line = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.hasPrefix("package:") && line.hasSuffix(".apk")
        }) else {
            throw ADBError.commandFailed("Android reported success, but \(packageName) could not be found on the device afterward.\n\nDevice response:\n\(output.nilIfEmpty ?? "No package path returned.")")
        }
    }

    private func installationError(_ error: Error, removedExistingApp: Bool) -> Error {
        let message = error.localizedDescription
        if !message.contains("Device response:"), message.lowercased().contains("install_") {
            return ADBError.commandFailed(InstallOutput.details(for: message, removedExistingApp: removedExistingApp))
        }
        guard removedExistingApp, !message.contains("already removed") else { return error }
        return ADBError.commandFailed("\(message)\n\nThe previous app and its local data were already removed.")
    }

    private func packages(on device: AndroidDevice, system: Bool) async throws -> [DeviceApp] {
        let flag = system ? "-s" : "-3"
        let output = try await adb.run(["-s", device.serial, "shell", "pm list packages \(flag)"])
        return output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("package:") else { return nil }
            return DeviceApp(packageName: String(line.dropFirst(8)), isSystem: system)
        }
    }

    private func storageSnapshot(on device: AndroidDevice, apps listedApps: [DeviceApp]) async throws -> (device: DeviceStorage, apps: [String: AppStorage]) {
        let serial = device.serial
        async let capacityTask = adb.run(["-s", serial, "shell", "df -k /data"])
        async let statsTask = adb.run(["-s", serial, "shell", "dumpsys diskstats"])
        let (capacityOutput, statsOutput) = try await (capacityTask, statsTask)
        var appStorage = StorageParser.appStorage(statsOutput)
        let missing = listedApps.filter { !$0.isSystem && appStorage[$0.packageName] == nil }.map(\.packageName)
        if !missing.isEmpty {
            let commands = missing.map {
                let package = RemoteFiles.shellQuote($0)
                return "du -sk $(pm path \(package) | cut -d: -f2) 2>/dev/null | awk -v p=\(package) '{s+=$1} END {if(s) print p \"\\t\" s*1024}'"
            }
            if let output = try? await adb.run(["-s", serial, "shell", commands.joined(separator: "; ")]) {
                appStorage.merge(StorageParser.apkStorage(output)) { current, _ in current }
            }
        }
        guard let capacity = StorageParser.capacity(capacityOutput, appBytes: appStorage.values.reduce(0) { $0 + $1.total }) else {
            throw ADBError.commandFailed("Android returned an unsupported storage report.\n\n\(capacityOutput)")
        }
        return (capacity, appStorage)
    }

    private func progressHandler(from start: Double, to end: Double) -> @Sendable (Double) -> Void {
        { [weak self] value in
            Task { @MainActor [weak self] in
                let next = start + min(max(value, 0), 1) * (end - start)
                if let current = self?.transfer?.fraction, current > next { return }
                self?.transfer?.fraction = next
            }
        }
    }

    @discardableResult
    private func beginActivity(_ title: String, detail: String, fraction: Double? = nil) -> Bool {
        isWorking = true
        statusMessage = "\(title)…"
        guard transfer == nil else { return false }
        withAnimation(.smooth) { transfer = TransferStatus(title: title, detail: detail, fraction: fraction) }
        return true
    }

    private func endActivity(_ owned: Bool) {
        guard owned else { return }
        withAnimation(.smooth) { transfer = nil }
        isWorking = false
    }

    private func estimateBrand(from name: String?, macAddress: String? = nil) -> String {
        let text = name?.lowercased() ?? ""
        if text.contains("xiaomi") || text.hasPrefix("mi ") { return "Xiaomi" }
        if text.contains("fire") { return "Amazon" }
        if text.contains("onn") { return "onn." }
        if text.contains("chromecast") || text.contains("google") { return "Google" }
        if macAddress?.uppercased().hasPrefix("C0:95:CF") == true { return "Amazon" }
        return "Unknown"
    }

    private func applyRememberedIdentity(to device: inout AndroidDevice) {
        guard let mac = device.macAddress,
              let identity = UserDefaults.standard.dictionary(forKey: "ADBDeck.device.\(mac.lowercased())") as? [String: String] else { return }
        if let manufacturer = identity["manufacturer"] { device.manufacturer = manufacturer }
        if let model = identity["model"] { device.model = model }
        if device.name.hasPrefix("Device "), let name = identity["name"] { device.name = name }
        device.androidCharacteristics = identity["characteristics"] ?? device.androidCharacteristics
    }

    private func rememberIdentity(_ device: AndroidDevice) {
        guard let mac = device.macAddress, device.manufacturer != "Unknown" else { return }
        UserDefaults.standard.set([
            "manufacturer": device.manufacturer,
            "model": device.model,
            "name": device.name,
            "characteristics": device.androidCharacteristics ?? ""
        ], forKey: "ADBDeck.device.\(mac.lowercased())")
    }
}
