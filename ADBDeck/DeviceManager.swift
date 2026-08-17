import Foundation
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
    case disabled = "ADB off"
    case unknown = "Unknown"

    var isUsable: Bool { self == .connected }
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

    var serial: String { "\(id):\(adbPort)" }

    var subtitle: String {
        let values = [manufacturer, model].filter { !$0.isEmpty && $0 != "Unknown" }
        if values.count == 2, model.lowercased().hasPrefix(manufacturer.lowercased()) { return model }
        return values.joined(separator: " · ")
    }

    var symbol: String {
        let text = "\(name) \(manufacturer) \(model)".lowercased()
        if text.contains("fire") || text.contains("amazon") { return "flame.fill" }
        if text.contains("tv") || text.contains("onn") || text.contains("xiaomi") || text.contains("mi ") { return "tv.fill" }
        return isAndroidLikely ? "display" : "network"
    }

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
        if isAndroidLikely { return hasCast ? "Android TV · Cast" : "Android TV" }
        if hasCast { return "Google Cast" }
        return nil
    }

    var listPriority: Int {
        switch adbState {
        case .connected: 0
        case .unauthorized: 1
        case .available: 2
        case .disabled where isAndroidLikely: 3
        case .disabled, .unknown: 4
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

struct AppStorage: Hashable, Sendable {
    let code: Int64
    let data: Int64
    let cache: Int64
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
        guard manifest.formatVersion == 1, !manifest.packageName.isEmpty, !manifest.files.isEmpty,
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

        let arp = await arpTable()
        for (ip, mac) in arp {
            if serviceHosts[ip] != nil {
                serviceHosts[ip]?.mac = mac
            } else {
                serviceHosts[ip] = Host(ip: ip, mac: mac)
            }
        }

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
    var storage: DeviceStorage?
    var performance: DevicePerformance?
    var performanceError: String?
    var isLoadingFolderSizes = false
    var recentlyAddedApps: Set<String> = []
    var removingApps: Set<String> = []

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
                hasCast: host.castOpen
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
        storage = nil
        guard let device = selectedDevice, device.adbState.isUsable else {
            apps = []
            loadedAppsDeviceID = nil
            return
        }
        let isSameList = loadedAppsDeviceID == device.id && loadedSystemAppsSetting == showSystemApps
        let previousPackages = isSameList ? Set(apps.map(\.packageName)) : []
        if !isSameList {
            apps = []
            recentlyAddedApps = []
            removingApps = []
        }
        let ownsActivity = beginActivity("Loading apps", detail: "Reading packages from \(device.name)")
        defer { endActivity(ownsActivity) }
        do {
            async let userTask = packages(on: device, system: false)
            let system = showSystemApps ? try await packages(on: device, system: true) : []
            let user = try await userTask
            guard selectedDevice?.id == device.id else { return }
            let loaded = (user + system).sorted { $0.packageName.localizedCaseInsensitiveCompare($1.packageName) == .orderedAscending }
            let added = previousPackages.isEmpty ? [] : Set(loaded.map(\.packageName)).subtracting(previousPackages)
            withAnimation(.smooth) {
                apps = loaded
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
            await loadStorage()
        } catch { report(error, operation: "Load apps") }
    }

    @discardableResult
    func loadStorage() async -> Bool {
        guard let device = selectedDevice, device.adbState.isUsable else { storage = nil; return false }
        let ownsActivity = beginActivity("Reading storage", detail: device.name)
        defer { endActivity(ownsActivity) }
        do {
            let snapshot = try await storageSnapshot(on: device)
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
            return
        }
        do {
            let output = try await adb.run(["-s", device.serial, "shell", "grep '^cpu ' /proc/stat; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo"])
            guard let sample = PerformanceParser.sample(output) else {
                throw ADBError.commandFailed("Android returned an unsupported CPU or memory report.\n\n\(output)")
            }
            guard selectedDevice?.id == device.id else { return }
            performance = PerformanceParser.performance(sample, after: previousCPU[device.id])
            previousCPU[device.id] = sample.cpu
            performanceError = nil
        } catch {
            performance = nil
            performanceError = error.localizedDescription
        }
    }

    func install(_ url: URL) async {
        guard let device = selectedDevice, device.adbState.isUsable else { return }
        let fileExtension = url.pathExtension.lowercased()
        guard ["apk", "adbdeck"].contains(fileExtension),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else {
            statusMessage = "Choose an APK or ADB Deck app package"
            return
        }
        if fileExtension == "adbdeck" {
            await installBackup(url, on: device)
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
            guard output.localizedCaseInsensitiveContains("success") else { throw ADBError.commandFailed(output) }
            _ = try? await adb.run(["-s", serial, "shell", "rm", remote])
            transfer?.fraction = 1
            statusMessage = "Installed \(url.lastPathComponent)"
            await loadApps()
        } catch {
            _ = try? await adb.run(["-s", serial, "shell", "rm", remote])
            report(error, operation: "Install \(url.lastPathComponent)")
        }
        try? await Task.sleep(for: .milliseconds(450))
        transfer = nil
        isWorking = false
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

    private func installBackup(_ archive: URL, on device: AndroidDevice) async {
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
            guard output.localizedCaseInsensitiveContains("success") else { throw ADBError.commandFailed(output) }
            transfer?.fraction = 1
            statusMessage = "Installed \(manifest.displayName)"
            await loadApps()
        } catch { report(error, operation: "Install \(archive.lastPathComponent)") }
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
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw ADBError.commandFailed(output.nilIfEmpty ?? "Could not create or open the app package.")
            }
        }.value
    }

    func uninstall(_ app: DeviceApp) async {
        guard let device = selectedDevice else { return }
        let ownsActivity = beginActivity("Removing \(app.displayName)", detail: "From \(device.name)")
        withAnimation(.smooth) { removingApps.insert(app.packageName) }
        defer {
            endActivity(ownsActivity)
            withAnimation(.smooth) { removingApps.remove(app.packageName) }
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
        } catch { report(error, operation: "Open \(app.displayName)") }
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
            let props = try await adb.run(["-s", serial, "shell", "printf '%s|%s|%s' \"$(getprop ro.product.manufacturer)\" \"$(getprop ro.product.model)\" \"$(getprop ro.product.device)\""])
            let parts = props.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 3 {
                device.manufacturer = parts[0].isEmpty ? device.manufacturer : parts[0]
                device.model = parts[1].isEmpty ? device.model : parts[1]
                device.name = parts[1].isEmpty ? device.name : parts[1]
                rememberIdentity(device)
            }
        } catch {
            device.adbState = .available
            report(error, operation: "Connect to \(device.id)")
        }
    }

    private func report(_ error: Error, operation: String) {
        let details = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = OperationFailure(operation: operation, details: details.isEmpty ? "The operation failed without an error message." : details)
        statusMessage = "\(operation) failed"
    }

    private func packages(on device: AndroidDevice, system: Bool) async throws -> [DeviceApp] {
        let flag = system ? "-s" : "-3"
        let output = try await adb.run(["-s", device.serial, "shell", "pm list packages \(flag)"])
        return output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("package:") else { return nil }
            return DeviceApp(packageName: String(line.dropFirst(8)), isSystem: system)
        }
    }

    private func storageSnapshot(on device: AndroidDevice) async throws -> (device: DeviceStorage, apps: [String: AppStorage]) {
        let serial = device.serial
        async let capacityTask = adb.run(["-s", serial, "shell", "df -k /data"])
        async let statsTask = adb.run(["-s", serial, "shell", "dumpsys diskstats"])
        let (capacityOutput, statsOutput) = try await (capacityTask, statsTask)
        let appStorage = StorageParser.appStorage(statsOutput)
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
    }

    private func rememberIdentity(_ device: AndroidDevice) {
        guard let mac = device.macAddress, device.manufacturer != "Unknown" else { return }
        UserDefaults.standard.set([
            "manufacturer": device.manufacturer,
            "model": device.model,
            "name": device.name
        ], forKey: "ADBDeck.device.\(mac.lowercased())")
    }
}
