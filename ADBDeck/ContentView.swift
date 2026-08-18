import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    private enum DetailMode: String, CaseIterable { case apps = "Apps", files = "Files" }
    private enum AppSort: String, CaseIterable {
        case name = "Name"
        case installed = "Recently installed"
        case updated = "Recently updated"
        case size = "Size"
    }

    @State private var manager = DeviceManager()
    @State private var search = ""
    @State private var fileSearch = ""
    @State private var isImporting = false
    @State private var appToRemove: DeviceApp?
    @State private var fileToDelete: RemoteFile?
    @State private var fileToRename: RemoteFile?
    @State private var editedName = ""
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var detailMode = DetailMode.apps
    @SwiftUI.AppStorage("appSort") private var appSort = AppSort.name
    @State private var showAddDevice = false
    @State private var manualAddress = ""
    @State private var showOtherDevices = false
    @State private var showOptimizeConfirmation = false
    @State private var showRemoteInput = false
    @State private var showDeviceActivity = false
    @State private var showLaunchers = false
    @State private var remoteText = ""
    @State private var liveRemotePreview = true
    @State private var inspectedApp: DeviceApp?
    @State private var pendingPowerAction: DevicePowerAction?

    private var androidDevices: [AndroidDevice] { manager.devices.filter { $0.isAndroidLikely } }
    private var otherDevices: [AndroidDevice] { manager.devices.filter { !$0.isAndroidLikely } }

    private var filteredApps: [DeviceApp] {
        let filtered = search.isEmpty ? manager.apps : manager.apps.filter {
            $0.packageName.localizedCaseInsensitiveContains(search) || $0.displayName.localizedCaseInsensitiveContains(search)
        }
        switch appSort {
        case .name:
            return filtered.sorted(by: nameOrder)
        case .installed:
            return filtered.sorted { recentOrder($0.installedAt, $1.installedAt, $0, $1) }
        case .updated:
            return filtered.sorted { recentOrder($0.updatedAt, $1.updatedAt, $0, $1) }
        case .size:
            return filtered.sorted {
                let lhs = $0.storage?.total ?? -1
                let rhs = $1.storage?.total ?? -1
                return lhs == rhs ? nameOrder($0, $1) : lhs > rhs
            }
        }
    }

    private func nameOrder(_ lhs: DeviceApp, _ rhs: DeviceApp) -> Bool {
        lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    private func recentOrder(_ lhs: Date?, _ rhs: Date?, _ lhsApp: DeviceApp, _ rhsApp: DeviceApp) -> Bool {
        if lhs != rhs { return (lhs ?? .distantPast) > (rhs ?? .distantPast) }
        return nameOrder(lhsApp, rhsApp)
    }

    private var filteredFiles: [RemoteFile] {
        guard !fileSearch.isEmpty else { return manager.files }
        return manager.files.filter { $0.name.localizedCaseInsensitiveContains(fileSearch) }
    }

    private var currentLocationName: String { RemoteFiles.locationName(for: manager.currentPath) }
    private var canModifyCurrentFolder: Bool { manager.currentPathAccess == .readWrite }
    private var canPasteHere: Bool {
        guard canModifyCurrentFolder, let item = manager.fileClipboard else { return false }
        return item.file.path != RemoteFiles.joined(manager.currentPath, item.file.name)
    }
    private var fileEmptyDescription: String {
        if !fileSearch.isEmpty { return "No items in \(currentLocationName) match “\(fileSearch)”." }
        switch manager.currentPathAccess {
        case .denied: return "Android denied ADB access to this folder."
        case .unavailable: return "ADB could not read this folder. Check the connection and try again."
        case .checking: return "Checking this folder through ADB."
        case .readOnly, .readWrite: return "This folder is empty."
        }
    }

    var body: some View {
        presentedContent
    }

    private var navigationContent: some View {
        NavigationSplitView {
            sidebar
                .frame(width: 280)
                .navigationSplitViewColumnWidth(280)
        } detail: {
            Group {
                if let device = manager.selectedDevice {
                    deviceDetail(device)
                } else if manager.isRefreshing {
                    DiscoveryLoadingView()
                } else {
                    ContentUnavailableView("No device selected", systemImage: "display.2", description: Text("Refresh to discover devices on this network."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .background(.ultraThinMaterial)
        .task { await manager.refresh() }
        .onChange(of: manager.selection) {
            manager.fileClipboard = nil
            manager.storage = nil
            manager.performance = nil
            manager.performanceError = nil
            manager.powerState = .unknown
            manager.screenCapture = nil
            manager.screenCaptureError = nil
            manager.appInspection = nil
            manager.mediaSession = nil
            Task { await reloadDetail() }
        }
        .onChange(of: detailMode) { Task { await reloadDetail() } }
        .task(id: "\(manager.selection ?? "")-\(scenePhase)") {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await manager.loadPerformance()
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [
            UTType(filenameExtension: "apk") ?? .data,
            UTType(filenameExtension: "apkm") ?? .archive,
            UTType(filenameExtension: "adbdeck") ?? .archive
        ]) { result in
            guard case .success(let url) = result else { return }
            Task { await manager.install(url) }
        }
    }

    private var destructiveAlertContent: some View {
        navigationContent
        .alert("App already installed", isPresented: Binding(get: { manager.pendingReplacement != nil }, set: { if !$0 { manager.pendingReplacement = nil } }), presenting: manager.pendingReplacement) { request in
            Button("Cancel", role: .cancel) { manager.pendingReplacement = nil }
            Button(request.actionTitle, role: request.mode == .replace ? .destructive : nil) {
                manager.pendingReplacement = nil
                Task { await manager.install(request.url, mode: request.mode) }
            }
        } message: { request in
            Text(request.summary)
        }
        .alert("Remove app?", isPresented: Binding(get: { appToRemove != nil }, set: { if !$0 { appToRemove = nil } }), presenting: appToRemove) { app in
            Button("Cancel", role: .cancel) { appToRemove = nil }
            Button("Remove", role: .destructive) {
                appToRemove = nil
                Task { await manager.uninstall(app) }
            }
        } message: { app in
            Text("This removes \(app.packageName) and its local data from \(manager.selectedDevice?.name ?? "the device").")
        }
        .alert("Delete from device?", isPresented: Binding(get: { fileToDelete != nil }, set: { if !$0 { fileToDelete = nil } }), presenting: fileToDelete) { file in
            Button("Cancel", role: .cancel) { fileToDelete = nil }
            Button("Delete", role: .destructive) {
                fileToDelete = nil
                Task { await manager.delete(file) }
            }
        } message: { file in
            Text("Permanently delete \(file.name)\(file.isDirectory ? " and everything inside it" : "") from the device? This cannot be undone.")
        }
    }

    private var presentedContent: some View {
        powerAlertContent
        .alert("Rename", isPresented: Binding(get: { fileToRename != nil }, set: { if !$0 { fileToRename = nil } })) {
            TextField("Name", text: $editedName)
            Button("Cancel", role: .cancel) { fileToRename = nil }
            Button("Rename") {
                guard let file = fileToRename else { return }
                fileToRename = nil
                Task { await manager.rename(file, to: editedName) }
            }
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await manager.createFolder(named: newFolderName) } }
        }
        .sheet(item: Binding(get: { manager.lastError }, set: { manager.lastError = $0 })) { failure in
            failureSheet(failure)
        }
        .sheet(isPresented: $showAddDevice) {
            addDeviceSheet
        }
        .sheet(isPresented: $showRemoteInput) {
            remoteInputSheet
        }
        .sheet(isPresented: $showDeviceActivity) {
            deviceActivitySheet
        }
        .sheet(isPresented: $showLaunchers) {
            launcherSheet
        }
        .sheet(item: $inspectedApp) { app in
            AppInspectorSheet(manager: manager, app: app)
        }
    }

    private var powerAlertContent: some View {
        optimizationAlertContent
            .alert(pendingPowerAction?.title ?? "Device power", isPresented: Binding(
                get: { pendingPowerAction != nil },
                set: { if !$0 { pendingPowerAction = nil } }
            ), presenting: pendingPowerAction) { action in
                Button("Cancel", role: .cancel) { pendingPowerAction = nil }
                Button(action.title, role: action == .shutdown ? .destructive : nil) {
                    pendingPowerAction = nil
                    Task { await manager.performPowerAction(action) }
                }
            } message: { action in
                Text(action.confirmation)
            }
    }

    private var optimizationAlertContent: some View {
        destructiveAlertContent
        .alert("Optimize device?", isPresented: $showOptimizeConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Optimize") { Task { await manager.optimizeDevice() } }
        } message: {
            Text("This asks Android to close cached background apps. Temporary caches are trimmed only when storage is low. Installed apps and personal data are kept.")
        }
        .alert("Optimization complete", isPresented: Binding(get: { manager.optimizationResult != nil }, set: { if !$0 { manager.optimizationResult = nil } }), presenting: manager.optimizationResult) { _ in
            Button("Done") { manager.optimizationResult = nil }
        } message: { result in
            Text(optimizationSummary(result))
        }
    }

    private func failureSheet(_ failure: OperationFailure) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("\(failure.operation) failed", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(.red)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(failure.summary)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let device = failure.device {
                        Text("Target device")
                            .font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                            diagnosticCard("Device", value: "\(device.manufacturer) \(device.model)", detail: device.typeLabel, symbol: device.symbol, color: .blue)
                            diagnosticCard("Android", value: device.androidVersion.map { "Android \($0)" } ?? "Unknown", detail: device.apiLevel.map { "API \($0)" }, symbol: "checkmark.seal.fill", color: .green)
                            if failure.operation.localizedCaseInsensitiveContains("install") {
                                diagnosticCard("Choose this APK", value: device.recommendedAPKArchitecture ?? "Architecture not reported", detail: device.supportedABIs.map { "Supports \($0)" }, symbol: "cpu.fill", color: .purple)
                            }
                            diagnosticCard("Connection", value: device.serial, detail: device.adbState.rawValue, symbol: "network", color: .orange)
                        }
                        .textSelection(.enabled)
                    }

                    if let technical = failure.technicalDetails {
                        DisclosureGroup("Technical details") {
                            Text(technical)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 10)
                        }
                    }
                }
                .padding(14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(failureCopyText(failure), forType: .string)
                } label: {
                    Label("Copy Details", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                Spacer()
                Button("Close") { manager.lastError = nil }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 660, minHeight: 440)
    }

    private func diagnosticCard(_ title: String, value: String, detail: String?, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.caption.bold())
                .foregroundStyle(color)
            Text(value)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .padding(13)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(color.opacity(0.2), lineWidth: 1)
        }
    }

    private func failureCopyText(_ failure: OperationFailure) -> String {
        var text = "\(failure.operation) failed\n\n\(failure.details)"
        if let device = failure.device {
            text += "\n\nTarget device:\n\(device.manufacturer) \(device.model)\nAndroid: \(device.androidVersion ?? "Unknown") · API \(device.apiLevel ?? "Unknown")\nChoose APK: \(device.recommendedAPKArchitecture ?? "Unknown")\nSupported ABIs: \(device.supportedABIs ?? "Unknown")\nConnection: \(device.serial)"
        }
        return text
    }

    private var addDeviceSheet: some View {
            VStack(alignment: .leading, spacing: 18) {
                Label("Add ADB device", systemImage: "plus.rectangle.on.rectangle")
                    .font(.title2.bold())
                TextField("192.168.1.100", text: $manualAddress)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addManualDevice() }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { showAddDevice = false }
                    Button("Connect") { addManualDevice() }
                        .buttonStyle(.borderedProminent)
                        .disabled(manualAddress.isEmpty)
                }
            }
            .padding(24)
            .frame(width: 390)
    }

    private var remoteInputSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(manager.selectedDevice.map { $0.kind == .television || $0.kind == .fireTV ? "TV Remote" : "Device Remote" } ?? "Device Remote", systemImage: "dot.radiowaves.left.and.right")
                    .font(.title2.bold())
                    .foregroundStyle(.teal)
                Spacer()
                if manager.isCapturingScreen { ProgressView().controlSize(.small) }
                Toggle("Live", isOn: $liveRemotePreview).toggleStyle(.switch).controlSize(.small)
                Button { Task { await manager.captureScreen() } } label: { Label("Refresh screen", systemImage: "arrow.clockwise") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .disabled(manager.isCapturingScreen)
                ModalCloseButton { showRemoteInput = false }
            }
            if let media = manager.mediaSession {
                HStack(spacing: 8) {
                    Image(systemName: media.state == "Playing" ? "play.circle.fill" : "pause.circle.fill").foregroundStyle(.purple)
                    Text(media.title ?? DeviceApp(packageName: media.packageName, isSystem: false).displayName).lineLimit(1)
                    Text(media.state).font(.caption.bold()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.purple.opacity(0.1), in: Capsule())
            }
            HStack(alignment: .top, spacing: 18) {
                RemoteScreenPreview(capture: manager.screenCapture, isLoading: manager.isCapturingScreen, error: manager.screenCaptureError) { x, y in
                    Task { await manager.tapScreen(x: x, y: y) }
                }
                remoteControlPad
            }
            Divider()
            Text("Keyboard")
                .font(.headline)
            TextField("Text to send", text: $remoteText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit { sendRemoteText() }
            HStack(spacing: 10) {
                Button("Paste", systemImage: "doc.on.clipboard") {
                    remoteText = NSPasteboard.general.string(forType: .string) ?? ""
                }
                Spacer()
                remoteKey("Delete", symbol: "delete.left", code: "KEYCODE_DEL")
                remoteKey("Enter", symbol: "return", code: "KEYCODE_ENTER")
            }
            HStack {
                Text("Standard keyboard characters · 500 maximum")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Send") { sendRemoteText() }
                    .buttonStyle(.borderedProminent)
                    .disabled(remoteText.isEmpty || manager.isWorking)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 820)
        .task {
            manager.screenCapture = nil
            async let screen: Void = manager.captureScreen()
            async let media: Void = manager.loadMediaSession()
            _ = await (screen, media)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
                guard liveRemotePreview else { continue }
                async let nextScreen: Void = manager.captureScreen()
                async let nextMedia: Void = manager.loadMediaSession()
                _ = await (nextScreen, nextMedia)
            }
        }
    }

    private var remoteControlPad: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                remoteKey("Back", symbol: "chevron.backward", code: "KEYCODE_BACK")
                remoteKey("Home", symbol: "house.fill", code: "KEYCODE_HOME")
                remoteKey("Menu", symbol: "line.3.horizontal", code: "KEYCODE_MENU")
            }
            VStack(spacing: 3) {
                remoteKey("Up", symbol: "chevron.up", code: "KEYCODE_DPAD_UP").frame(width: 46, height: 38)
                HStack(spacing: 3) {
                    remoteKey("Left", symbol: "chevron.left", code: "KEYCODE_DPAD_LEFT").frame(width: 46, height: 38)
                    remoteKey("Select", symbol: "circle.inset.filled", code: "KEYCODE_DPAD_CENTER").frame(width: 46, height: 38)
                    remoteKey("Right", symbol: "chevron.right", code: "KEYCODE_DPAD_RIGHT").frame(width: 46, height: 38)
                }
                remoteKey("Down", symbol: "chevron.down", code: "KEYCODE_DPAD_DOWN").frame(width: 46, height: 38)
            }
            .buttonStyle(.bordered)
            HStack(spacing: 8) {
                remoteKey("Volume down", symbol: "speaker.minus.fill", code: "KEYCODE_VOLUME_DOWN")
                remoteKey("Mute", symbol: "speaker.slash.fill", code: "KEYCODE_VOLUME_MUTE")
                remoteKey("Volume up", symbol: "speaker.plus.fill", code: "KEYCODE_VOLUME_UP")
            }
            HStack(spacing: 8) {
                remoteKey("Previous", symbol: "backward.fill", code: "KEYCODE_MEDIA_PREVIOUS")
                remoteKey("Play or pause", symbol: "playpause.fill", code: "KEYCODE_MEDIA_PLAY_PAUSE")
                remoteKey("Next", symbol: "forward.fill", code: "KEYCODE_MEDIA_NEXT")
            }
            if manager.selectedDevice?.kind == .television || manager.selectedDevice?.kind == .fireTV {
                HStack(spacing: 8) {
                    remoteKey("TV input", symbol: "rectangle.on.rectangle", code: "KEYCODE_TV_INPUT")
                    remoteKey("Settings", symbol: "gearshape.fill", code: "KEYCODE_SETTINGS")
                    remoteKey("Captions", symbol: "captions.bubble.fill", code: "KEYCODE_CAPTIONS")
                }
            }
            Text("Click the preview to tap the device screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 205)
    }

    private var deviceActivitySheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Device activity", systemImage: "rectangle.stack.fill")
                    .font(.title2.bold())
                Spacer()
                if manager.isLoadingActivity { ProgressView().controlSize(.small) }
                Button { Task { await manager.loadActivity() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .help("Refresh device activity")
                .disabled(manager.isLoadingActivity || manager.isWorking)
                ModalCloseButton { showDeviceActivity = false }
            }

            Text("Current app")
                .font(.headline)
            if let package = manager.foregroundPackage {
                let app = activityApp(package)
                activityRow(app, isCurrent: true)
                    .padding(14)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            } else if manager.isLoadingActivity {
                ProgressView("Checking the foreground app…")
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                ContentUnavailableView("Home screen", systemImage: "house", description: Text("No managed app is currently in front."))
                    .frame(minHeight: 100)
            }

            HStack {
                Text("Recent apps")
                    .font(.headline)
                Spacer()
                Text("\(manager.recentPackages.count)")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if manager.recentPackages.isEmpty && !manager.isLoadingActivity {
                Text("No recent managed apps were reported by Android.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(manager.recentPackages, id: \.self) { package in
                            activityRow(activityApp(package), isCurrent: false)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            Text("Background returns to Home. Force Quit stops the app until it is opened again.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 560)
        .frame(minHeight: 430)
        .task { await manager.loadActivity() }
    }

    private var launcherSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Default launcher", systemImage: "house.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.green)
                Spacer()
                if manager.isLoadingLaunchers { ProgressView().controlSize(.small) }
                Button { Task { await manager.loadLaunchers() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .disabled(manager.isLoadingLaunchers || manager.isWorking)
                ModalCloseButton { showLaunchers = false }
            }
            Text("Choose the app Android opens when Home is pressed. Only installed apps that advertise the HOME role are shown.")
                .foregroundStyle(.secondary)
            if manager.selectedDevice?.kind == .fireTV {
                Label("Fire OS may lock Fire TV Home. ADB Deck verifies every change and never disables Amazon system packages.", systemImage: "exclamationmark.shield.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(12)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            if manager.launchers.isEmpty, manager.isLoadingLaunchers {
                ProgressView("Detecting installed launchers…")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else if manager.launchers.isEmpty {
                ContentUnavailableView("No launchers reported", systemImage: "house.slash", description: Text("This device did not expose any HOME activities through ADB."))
                    .frame(minHeight: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(manager.launchers) { launcher in
                            HStack(spacing: 12) {
                                Image(systemName: launcher.isFallback ? "cross.case.fill" : "house.fill")
                                    .foregroundStyle(launcher.isFallback ? Color.secondary : Color.green)
                                    .frame(width: 34, height: 34)
                                    .background((launcher.isFallback ? Color.secondary : .green).opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(launcher.name).fontWeight(.semibold)
                                    Text(launcher.component).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if launcher.component == manager.currentLauncher {
                                    Label("Default", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                } else if launcher.isFallback {
                                    Text("Recovery fallback").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Button("Use") { Task { await manager.setDefaultLauncher(launcher) } }
                                        .buttonStyle(.borderedProminent)
                                        .tint(.green)
                                        .disabled(manager.isWorking)
                                }
                            }
                            .padding(12)
                            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            Text("You can always select the original launcher again from this list.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 640)
        .frame(minHeight: 420)
        .task { await manager.loadLaunchers() }
    }

    private func activityRow(_ app: DeviceApp, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: app.symbol)
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.displayName).fontWeight(.semibold)
                    if isCurrent {
                        Text("OPEN")
                            .font(.caption2.bold())
                            .foregroundStyle(.green)
                    }
                }
                Text(app.packageName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isCurrent {
                Button { Task { await manager.backgroundCurrentApp() } } label: {
                    Label("Background", systemImage: "house.fill")
                }
                    .tint(.orange)
                    .disabled(manager.isWorking)
            } else {
                Button { Task { await manager.launch(app) } } label: {
                    Label("Open", systemImage: "play.fill")
                }
                .tint(.green)
                .help("Open \(app.displayName)")
                .disabled(manager.isWorking)
            }
            Button(role: .destructive) { Task { await manager.forceQuit(app) } } label: {
                Label("Force Quit", systemImage: "xmark.circle")
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.red)
            .help("Force quit \(app.displayName)")
            .disabled(manager.isWorking)
        }
        .padding(.vertical, 10)
    }

    private func activityApp(_ package: String) -> DeviceApp {
        manager.apps.first { $0.packageName == package } ?? DeviceApp(packageName: package, isSystem: false)
    }

    private var sidebar: some View {
        List(selection: $manager.selection) {
            Section("Android devices") {
                ForEach(androidDevices) { device in
                    DeviceRow(device: device)
                        .tag(device.id)
                }
            }
            if !otherDevices.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showOtherDevices) {
                        ForEach(otherDevices) { device in
                            DeviceRow(device: device)
                                .tag(device.id)
                        }
                    } label: {
                        HStack {
                            Label("Other network devices", systemImage: "eye.slash").lineLimit(1)
                            Spacer()
                            Text("\(otherDevices.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                if manager.isRefreshing || manager.isWorking {
                    ProgressView().controlSize(.small).frame(width: 10, height: 10)
                } else {
                    Circle().fill(.green).frame(width: 7, height: 7).frame(width: 10)
                }
                Text(manager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.thinMaterial)
        }
        .navigationTitle("ADB Deck")
        .toolbar {
            ToolbarItemGroup {
                Button { showAddDevice = true } label: { Label("Add device", systemImage: "plus") }
                Button { Task { await manager.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .rotationEffect(.degrees(manager.isRefreshing ? 360 : 0))
                        .animation(manager.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: manager.isRefreshing)
                }
                .disabled(manager.isRefreshing)
            }
        }
    }

    @ViewBuilder
    private func deviceDetail(_ device: AndroidDevice) -> some View {
        VStack(spacing: 0) {
            DeviceHeader(device: device, isBusy: manager.isWorking) {
                Task { await manager.connectSelected() }
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            if device.adbState.isUsable {
                VStack(spacing: 0) {
                    Picker("View", selection: $detailMode) {
                        ForEach(DetailMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    .frame(height: 52)
                    Divider()
                    StorageSummary(
                        storage: manager.storage,
                        performance: manager.performance,
                        performanceError: manager.performanceError,
                        isLoading: manager.isWorking,
                        isMonitoringPaused: scenePhase != .active || manager.isWorking || manager.isRefreshing
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    if detailMode == .apps { appList } else { fileBrowser }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ContentUnavailableView {
                    Label(device.adbState.rawValue, systemImage: device.adbState == .unauthorized ? "checkmark.shield" : "cable.connector")
                } description: {
                    Text(device.adbState == .unauthorized
                         ? "Accept the debugging prompt on the device, then connect again."
                         : device.adbState == .offline
                         ? "The device is restarting or powered off. Turn it on if needed, then refresh."
                         : "Enable USB or network debugging in Developer options, then connect.")
                } actions: {
                    Button(device.adbState == .offline ? "Refresh Devices" : "Connect") {
                        Task {
                            if device.adbState == .offline { await manager.refresh() }
                            else { await manager.connectSelected() }
                        }
                    }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            if let transfer = manager.transfer {
                TransferBanner(transfer: transfer)
                    .frame(maxWidth: 620)
                    .padding(20)
            }
        }
        .animation(.smooth(duration: 0.25), value: manager.transfer)
        .toolbar {
            ToolbarItemGroup {
                if detailMode == .apps {
                    Button { isImporting = true } label: {
                        Label("Install", systemImage: "square.and.arrow.down").foregroundStyle(.blue)
                    }
                    .help("Install an APK or ADB Deck app package")
                    .disabled(!device.adbState.isUsable || manager.isWorking)
                } else {
                    Menu {
                        Button(action: chooseUpload) { Label("Upload", systemImage: "square.and.arrow.up") }
                            .disabled(!canModifyCurrentFolder)
                        Button {
                            newFolderName = ""
                            showNewFolder = true
                        } label: { Label("New folder", systemImage: "folder.badge.plus") }
                            .disabled(!canModifyCurrentFolder)
                        Button { Task { await manager.pasteFiles() } } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                            .disabled(!canPasteHere)
                    } label: {
                        Label("File actions", systemImage: "folder.badge.gearshape").foregroundStyle(.blue)
                    }
                    .disabled(!device.adbState.isUsable || manager.isWorking)
                }
                Button { showOptimizeConfirmation = true } label: { Label("Optimize", systemImage: "wand.and.stars").foregroundStyle(.purple) }
                    .help("Close cached background apps and clear temporary caches")
                    .disabled(!device.adbState.isUsable || manager.isWorking)
                Button { showRemoteInput = true } label: { Label("Remote", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.teal) }
                    .help("Control the device, view its screen, and send text")
                    .disabled(!device.adbState.isUsable || manager.isWorking)
                Button { showDeviceActivity = true } label: { Label("Activity", systemImage: "rectangle.stack.fill").foregroundStyle(.orange) }
                    .help("See and control the current and recent apps")
                    .disabled(!device.adbState.isUsable || manager.isWorking)
                Button { showLaunchers = true } label: { Label("Launcher", systemImage: "house.fill").foregroundStyle(.green) }
                    .help("Choose the device's default Home launcher")
                    .disabled(!device.adbState.isUsable || manager.isWorking)
                Menu {
                    Section(manager.powerState.rawValue) {
                        switch manager.powerState {
                        case .awake:
                            Button { requestPowerAction(.sleep) } label: { Label(DevicePowerAction.sleep.title, systemImage: DevicePowerAction.sleep.symbol) }
                        case .asleep, .dozing:
                            Button { requestPowerAction(.wake) } label: { Label(DevicePowerAction.wake.title, systemImage: DevicePowerAction.wake.symbol) }
                        case .unknown:
                            Button { Task { await manager.loadPerformance() } } label: { Label("Check screen state", systemImage: "arrow.clockwise") }
                        }
                    }
                    Section("Restart") {
                        Button { requestPowerAction(.restart) } label: { Label(DevicePowerAction.restart.title, systemImage: DevicePowerAction.restart.symbol) }
                        Button { requestPowerAction(.recovery) } label: { Label(DevicePowerAction.recovery.title, systemImage: DevicePowerAction.recovery.symbol) }
                        Button { requestPowerAction(.bootloader) } label: { Label(DevicePowerAction.bootloader.title, systemImage: DevicePowerAction.bootloader.symbol) }
                        if device.supportsDownloadMode {
                            Button { requestPowerAction(.download) } label: { Label(DevicePowerAction.download.title, systemImage: DevicePowerAction.download.symbol) }
                        }
                    }
                    Divider()
                    Button(role: .destructive) { requestPowerAction(.shutdown) } label: { Label(DevicePowerAction.shutdown.title, systemImage: DevicePowerAction.shutdown.symbol) }
                } label: {
                    Label("Power", systemImage: manager.powerState.symbol)
                        .foregroundStyle(manager.powerState == .awake ? Color.orange : Color.indigo)
                }
                .help(manager.powerState.rawValue)
                .disabled(!device.adbState.isUsable || manager.isWorking)
                Button { Task { await reloadDetail(refreshStorage: true) } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .disabled(!device.adbState.isUsable || manager.isWorking)
            }
        }
    }

    private func requestPowerAction(_ action: DevicePowerAction) {
        if action.requiresConfirmation { pendingPowerAction = action }
        else { Task { await manager.performPowerAction(action) } }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    appListTitle
                    Spacer(minLength: 20)
                    appListControls
                }
                VStack(spacing: 8) {
                    HStack { appListTitle; Spacer() }
                    HStack { Spacer(); appListControls }
                }
                .padding(.vertical, 10)
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 58)

            if manager.isWorking && manager.apps.isEmpty {
                Spacer()
                ProgressView("Reading apps…")
                Spacer()
            } else if filteredApps.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(filteredApps) { app in
                    AppRow(app: app,
                           isNew: manager.recentlyAddedApps.contains(app.packageName),
                           isRemoving: manager.removingApps.contains(app.packageName),
                           dateLabel: appSort == .installed ? "Installed" : appSort == .updated ? "Updated" : nil,
                           date: appSort == .installed ? app.installedAt : appSort == .updated ? app.updatedAt : nil,
                           download: { chooseDownloadFolder(for: app) },
                           inspect: { inspectedApp = app },
                           launch: { Task { await manager.launch(app) } },
                           remove: { appToRemove = app })
                }
                .listStyle(.inset)
                .animation(.smooth, value: filteredApps)
                .disabled(manager.isWorking)
            }
        }
    }

    private var appListTitle: some View {
        HStack {
                Text("Installed apps")
                    .font(.title2.bold())
                Text("\(filteredApps.count)")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
        }
        .fixedSize()
    }

    private var appListControls: some View {
        HStack(spacing: 12) {
                Toggle("System apps", isOn: $manager.showSystemApps)
                    .toggleStyle(.switch)
                    .onChange(of: manager.showSystemApps) { Task { await manager.loadApps() } }
                Picker("Sort", selection: $appSort) {
                    ForEach(AppSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 170)
                TextField("Search apps", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
        }
        .fixedSize()
    }

    private var fileBrowser: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                fileNavigation(showPermission: true)
                fileNavigation(showPermission: false)
            }
            .padding(.horizontal, 14)
            .frame(height: 58)
            .fixedSize(horizontal: false, vertical: true)

            if let clipboard = manager.fileClipboard {
                HStack(spacing: 10) {
                    Label("\(clipboard.operation.rawValue): \(clipboard.file.name)", systemImage: clipboard.operation == .copy ? "doc.on.doc" : "scissors")
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(canPasteHere ? "Ready for \(currentLocationName)" : "Open a writable destination")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .cancel) { manager.fileClipboard = nil }
                    Button("Paste Here", systemImage: "doc.on.clipboard") { Task { await manager.pasteFiles() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canPasteHere || manager.isWorking)
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(.blue.opacity(0.08))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if manager.isWorking && manager.files.isEmpty {
                Spacer()
                ProgressView("Reading files…")
                Spacer()
            } else if filteredFiles.isEmpty {
                ContentUnavailableView("No files", systemImage: "folder", description: Text(fileEmptyDescription))
            } else {
                List(filteredFiles) { file in
                    RemoteFileRow(
                        file: file,
                        isMeasuringFolderSize: manager.isLoadingFolderSizes,
                        open: { if file.isDirectory { Task { await manager.loadFiles(at: file.path) } } else { chooseDownloadFolder(for: file) } },
                        download: { chooseDownloadFolder(for: file) },
                        copy: { manager.putOnClipboard(file, operation: .copy) },
                        cut: { manager.putOnClipboard(file, operation: .move) },
                        rename: {
                            editedName = file.name
                            fileToRename = file
                        },
                        remove: { fileToDelete = file },
                        canModify: canModifyCurrentFolder
                    )
                }
                .listStyle(.inset)
                .animation(.smooth, value: filteredFiles)
                .disabled(manager.isWorking)
            }
        }
        .onChange(of: manager.currentPath) { fileSearch = "" }
        .animation(.smooth(duration: 0.2), value: manager.fileClipboard)
    }

    private func fileNavigation(showPermission: Bool) -> some View {
            HStack(spacing: 10) {
                Button { Task { await manager.loadFiles(at: RemoteFiles.parent(of: manager.currentPath)) } } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(manager.currentPath == "/")
                .frame(width: 34)
                Menu {
                    Button("Internal storage") { Task { await manager.loadFiles(at: "/sdcard") } }
                    Button("Downloads") { Task { await manager.loadFiles(at: "/sdcard/Download") } }
                    Button("Android media") { Task { await manager.loadFiles(at: "/sdcard/Android/media") } }
                    Button("App data (may be protected)") { Task { await manager.loadFiles(at: "/sdcard/Android/data") } }
                    Divider()
                    Button("ADB temporary files") { Task { await manager.loadFiles(at: "/data/local/tmp") } }
                    Button("System root") { Task { await manager.loadFiles(at: "/") } }
                } label: {
                    Label(currentLocationName, systemImage: "externaldrive.fill")
                }
                .frame(width: showPermission ? 170 : 145)
                Text(manager.currentPath)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showPermission {
                    Label(manager.currentPathAccess.label, systemImage: manager.currentPathAccess.symbol)
                        .font(.caption.bold())
                        .foregroundStyle(fileAccessColor)
                        .fixedSize()
                        .help(fileAccessHelp)
                }
                TextField("Search \(currentLocationName)", text: $fileSearch)
                    .textFieldStyle(.roundedBorder)
                    .overlay(alignment: .trailing) {
                        if !fileSearch.isEmpty {
                            Button { fileSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .padding(.trailing, 6)
                                .help("Clear search")
                        }
                    }
                    .frame(width: 190)
            }
            .font(showPermission ? .caption : .body)
    }

    private var fileAccessColor: Color {
        switch manager.currentPathAccess {
        case .readWrite: .green
        case .readOnly: .orange
        case .denied, .unavailable: .red
        case .checking: .secondary
        }
    }

    private var fileAccessHelp: String {
        switch manager.currentPathAccess {
        case .readWrite: "ADB can read and change items in this folder."
        case .readOnly: "ADB can read this folder, but Android blocks changes. Root access would be required to bypass it."
        case .denied: "Android denied ADB access to this folder. ADB Deck does not bypass device security."
        case .unavailable: "ADB could not verify access to this folder."
        case .checking: "Checking the folder through ADB."
        }
    }

    private func addManualDevice() {
        let address = manualAddress
        manualAddress = ""
        showAddDevice = false
        Task { await manager.addDevice(address) }
    }

    private func sendRemoteText() {
        let text = remoteText
        Task {
            await manager.sendText(text)
            if manager.lastError == nil { remoteText = "" }
        }
    }

    private func remoteKey(_ name: String, symbol: String, code: String) -> some View {
        Button { Task { await manager.sendKey(code, named: name) } } label: {
            Label(name, systemImage: symbol)
        }
        .labelStyle(.iconOnly)
        .help(name)
        .disabled(manager.isWorking)
    }

    private func reloadDetail(refreshStorage: Bool = false) async {
        if detailMode == .apps {
            await manager.loadApps()
        } else {
            await manager.loadFiles()
            if refreshStorage || manager.storage == nil { await manager.loadStorage() }
        }
    }

    private func optimizationSummary(_ result: OptimizationResult) -> String {
        let storage = result.storageRecovered.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unavailable"
        let memory = result.memoryReleased.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "Unavailable"
        return "Temporary storage recovered: \(storage)\nMemory released now: \(memory)\n\nAndroid may reuse memory as apps restart."
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.title = "Upload to \(manager.currentPath)"
        panel.prompt = "Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await manager.upload(url) }
    }

    private func chooseDownloadFolder(for app: DeviceApp) {
        let panel = NSOpenPanel()
        panel.title = "Clone \(app.displayName) for another device"
        panel.prompt = "Clone Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task {
            if let saved = await manager.download(app, to: directory) {
                NSWorkspace.shared.activateFileViewerSelecting([saved])
            }
        }
    }

    private func chooseDownloadFolder(for file: RemoteFile) {
        let panel = NSOpenPanel()
        panel.title = "Download \(file.name)"
        panel.prompt = "Save Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task {
            if let saved = await manager.download(file, to: directory) {
                NSWorkspace.shared.activateFileViewerSelecting([saved])
            }
        }
    }
}

private struct DeviceRow: View {
    let device: AndroidDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.symbol)
                .font(.title3)
                .foregroundStyle(device.kindColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                HStack(spacing: 6) {
                    Text(device.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let label = device.typeLabel {
                        Text(label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(device.kindColor)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(device.kindColor.opacity(0.16), in: Capsule())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Circle()
                .fill(device.adbState == .connected ? .green : device.adbState == .unauthorized ? .orange : .gray.opacity(0.45))
                .frame(width: 8, height: 8)
                .help(device.adbState.rawValue)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

private struct DeviceHeader: View {
    let device: AndroidDevice
    let isBusy: Bool
    let connect: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: device.symbol)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .shadow(color: Color.accentColor.opacity(0.2), radius: 12, y: 5)
            VStack(alignment: .leading, spacing: 5) {
                Text(device.name).font(.title.bold()).lineLimit(1).minimumScaleFactor(0.75)
                if !device.subtitle.isEmpty { Text(device.subtitle).foregroundStyle(.secondary) }
                HStack(spacing: 12) {
                    Label(device.id, systemImage: "network")
                    if let mac = device.macAddress { Label(mac, systemImage: "number") }
                    if device.hasCast { Label("Cast", systemImage: "airplayvideo") }
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                if device.androidVersion != nil || device.recommendedAPKArchitecture != nil {
                    HStack(spacing: 8) {
                        if let version = device.androidVersion {
                            Label("Android \(version)" + (device.apiLevel.map { " · API \($0)" } ?? ""), systemImage: "checkmark.seal")
                        }
                        if let architecture = device.recommendedAPKArchitecture {
                            Label(architecture, systemImage: "cpu")
                                .help("Supported ABIs: \(device.supportedABIs ?? architecture)")
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            }
            Spacer()
            Button(action: connect) {
                if isBusy && device.adbState != .connected {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Connecting…")
                    }
                } else {
                    Label(device.adbState.rawValue, systemImage: device.adbState == .connected ? "checkmark.circle.fill" : "bolt.horizontal.circle")
                }
            }
            .fixedSize()
            .buttonStyle(.borderedProminent)
            .tint(device.adbState == .connected ? .green : .accentColor)
        }
        .padding(22)
        .frame(height: 132)
        .background(.regularMaterial)
    }
}

private struct AppRow: View {
    let app: DeviceApp
    let isNew: Bool
    let isRemoving: Bool
    let dateLabel: String?
    let date: Date?
    let download: () -> Void
    let inspect: () -> Void
    let launch: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: app.symbol)
                .font(.title2)
                .foregroundStyle(app.isSystem ? .secondary : Color.accentColor)
                .frame(width: 38, height: 38)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName).fontWeight(.medium)
                Text(app.packageName).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if isNew {
                Label("New", systemImage: "sparkles")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            }
            if isRemoving {
                Label("Removing", systemImage: "minus.circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                    .transition(.scale.combined(with: .opacity))
            }
            if app.isSystem { Text("System").font(.caption).foregroundStyle(.secondary) }
            if let dateLabel {
                Text(date.map { "\(dateLabel) \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Date unavailable")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 142, alignment: .trailing)
            }
            if let storage = app.storage {
                Text((storage.isEstimate ? "≈ " : "") + ByteCountFormatter.string(fromByteCount: storage.total, countStyle: .file))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .trailing)
                    .help(storage.isEstimate
                          ? "APK files: \(ByteCountFormatter.string(fromByteCount: storage.code, countStyle: .file))\nAndroid has not reported data and cache yet."
                          : "App: \(ByteCountFormatter.string(fromByteCount: storage.code, countStyle: .file))\nData: \(ByteCountFormatter.string(fromByteCount: storage.data, countStyle: .file))\nCache: \(ByteCountFormatter.string(fromByteCount: storage.cache, countStyle: .file))")
            } else {
                Text("—").foregroundStyle(.tertiary).frame(width: 78, alignment: .trailing)
            }
            Button(action: download) { Image(systemName: "square.and.arrow.down") }
                .buttonStyle(.borderless)
                .foregroundStyle(.blue)
                .help("Clone app package")
            Button(action: inspect) { Image(systemName: "info.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.purple)
                .help("Inspect app")
            Button(action: launch) { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.green)
                .help("Open app")
            Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Remove app")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background((isRemoving ? Color.red : isNew ? Color.green : Color.clear).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .animation(.smooth, value: isNew)
        .animation(.smooth, value: isRemoving)
        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .scale(scale: 0.98).combined(with: .opacity)))
        .accessibilityHint(isNew ? "Newly installed" : isRemoving ? "Being removed" : "")
        .contextMenu {
            Button("Inspect", action: inspect)
            Button("Clone app package", action: download)
            Button("Open", action: launch)
            Divider()
            Button("Remove", role: .destructive, action: remove)
        }
    }
}

private struct RemoteScreenPreview: View {
    let capture: ScreenCapture?
    let isLoading: Bool
    let error: String?
    let tap: (Int, Int) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.black)
            if let capture, let image = NSImage(data: capture.data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        GeometryReader { proxy in
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(SpatialTapGesture().onEnded { value in
                                    guard let point = ScreenGeometry.devicePoint(
                                        at: value.location,
                                        in: proxy.size,
                                        imageSize: CGSize(width: capture.width, height: capture.height)
                                    ) else { return }
                                    tap(Int(point.x), Int(point.y))
                                })
                        }
                    }
            } else if isLoading {
                ProgressView("Capturing screen…").tint(.white).foregroundStyle(.white)
            } else {
                ContentUnavailableView("Preview unavailable", systemImage: "display.trianglebadge.exclamationmark", description: Text(error ?? "Refresh to request a screenshot through ADB."))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 535, height: 301)
        .overlay(alignment: .bottomTrailing) {
            if let capture {
                Text("\(capture.width) × \(capture.height) · \(capture.capturedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(7)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

@MainActor
private struct AppInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var manager: DeviceManager
    let app: DeviceApp
    @State private var confirmClearData = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: app.symbol)
                    .font(.title2)
                    .foregroundStyle(.purple)
                    .frame(width: 48, height: 48)
                    .background(.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.displayName).font(.title2.bold())
                    Text(app.packageName).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if manager.isLoadingInspection { ProgressView().controlSize(.small) }
                Button { Task { await manager.loadInspection(for: app) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .disabled(manager.isLoadingInspection || manager.isWorking)
                ModalCloseButton { dismiss() }
            }

            if let inspection = manager.appInspection {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                    inspectorFact("Version", inspection.versionName ?? "Unknown", detail: inspection.versionCode.map { "Code \($0)" }, color: .blue)
                    inspectorFact("Android support", inspection.minSDK.map { "API \($0)+" } ?? "Unknown", detail: inspection.targetSDK.map { "Targets API \($0)" }, color: .green)
                    inspectorFact("State", inspection.isSuspended ? "Suspended" : inspection.isStopped ? "Stopped" : "Ready", detail: inspection.enabledState, color: inspection.isSuspended ? .red : .orange)
                    inspectorFact("Storage", app.storage.map { byteCount($0.total) } ?? "Unavailable", detail: app.storage.map { "Data \(byteCount($0.data)) · Cache \(byteCount($0.cache))" }, color: .purple)
                }

                HStack(spacing: 10) {
                    Button { Task { await manager.launch(app) } } label: { Label("Open", systemImage: "play.fill") }.tint(.green)
                    Button(role: .destructive) { Task { await manager.forceQuit(app) } } label: { Label("Force Quit", systemImage: "xmark.circle.fill") }.tint(.red)
                    Spacer()
                    Button { Task { await manager.clearCache(for: app) } } label: { Label("Clear Cache", systemImage: "eraser.fill") }
                        .disabled(!inspection.supportsCacheOnlyClear || manager.isWorking)
                        .help(inspection.supportsCacheOnlyClear ? "Remove temporary files while keeping app data" : "This Android version cannot clear only one app's cache through ADB")
                    Button(role: .destructive) { confirmClearData = true } label: { Label("Clear All Data", systemImage: "trash.slash.fill") }
                        .disabled(manager.isWorking)
                }
                .buttonStyle(.bordered)

                HStack {
                    Text("Runtime permissions").font(.headline)
                    Spacer()
                    if !inspection.permissions.isEmpty {
                        Text("\(inspection.permissions.filter(\.granted).count) of \(inspection.permissions.count) granted")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if inspection.permissions.isEmpty {
                    VStack(spacing: 7) {
                        Image(systemName: "checkmark.shield.fill").font(.title2).foregroundStyle(.green)
                        Text("No runtime permissions").font(.headline)
                        Text("Android reports no user-changeable permissions for this app.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 105)
                    .background(.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(inspection.permissions) { permission in
                                HStack(spacing: 10) {
                                    Image(systemName: permission.granted ? "checkmark.shield.fill" : "shield.slash")
                                        .foregroundStyle(permission.granted ? Color.green : Color.secondary)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(permission.shortName.replacingOccurrences(of: "_", with: " ").capitalized).fontWeight(.medium)
                                        Text(permission.name).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Button(permission.granted ? "Revoke" : "Grant") {
                                        Task { await manager.setPermission(permission, granted: !permission.granted, for: app) }
                                    }
                                    .tint(permission.granted ? .orange : .green)
                                    .disabled(manager.isWorking)
                                }
                                .padding(.vertical, 9)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 250)
                }
            } else if manager.isLoadingInspection {
                ProgressView("Reading package details…").frame(maxWidth: .infinity, minHeight: 280)
            } else {
                ContentUnavailableView("Inspection unavailable", systemImage: "info.circle", description: Text("Refresh to read this package through ADB."))
                    .frame(minHeight: 280)
            }
        }
        .padding(24)
        .frame(width: 700)
        .task { await manager.loadInspection(for: app) }
        .alert("Clear all app data?", isPresented: $confirmClearData) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Data", role: .destructive) { Task { await manager.clearData(for: app) } }
        } message: {
            Text("This resets \(app.displayName), removing its accounts, settings, downloads, and cache. The app remains installed. This cannot be undone.")
        }
    }

    private func inspectorFact(_ title: String, _ value: String, detail: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(color)
            Text(value).font(.headline).lineLimit(1)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .padding(11)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func byteCount(_ value: Int64) -> String {
        value == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private struct ModalCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button("Close", systemImage: "xmark", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(.red)
            .keyboardShortcut(.cancelAction)
            .help("Close")
    }
}

private struct StorageSummary: View {
    let storage: DeviceStorage?
    let performance: DevicePerformance?
    let performanceError: String?
    let isLoading: Bool
    let isMonitoringPaused: Bool

    var body: some View {
        Group {
            if let storage {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        storageLabel
                        ProgressView(value: storage.usedFraction)
                            .tint(storage.isLow ? .orange : Color.accentColor)
                            .frame(minWidth: 80, maxWidth: 180)
                        metrics(storage)
                        Spacer(minLength: 8)
                        health(storage, showsText: true)
                        Text(storage.refreshedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(width: 64, alignment: .trailing)
                    }
                    HStack(spacing: 10) {
                        storageLabel
                        metrics(storage)
                        Spacer(minLength: 4)
                        health(storage, showsText: false)
                    }
                }
            } else if isLoading {
                HStack {
                    storageLabel
                    ProgressView().controlSize(.small)
                    Text("Reading storage…").foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                HStack {
                    storageLabel
                    Text("Storage information unavailable").foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
        .frame(maxWidth: .infinity)
        .background(.quinary.opacity(0.35))
    }

    private var storageLabel: some View {
        Label("Storage", systemImage: "internaldrive.fill")
            .fontWeight(.semibold)
            .fixedSize()
    }

    private func metrics(_ storage: DeviceStorage) -> some View {
        HStack(spacing: 12) {
                metric("Used \(Int(storage.usedFraction * 100))%", storage.used)
                metric("Available", storage.free)
                metric("Apps", storage.apps)
                Divider().frame(height: 30)
                vital("CPU", performance?.cpuFraction.map { "\(Int($0 * 100))%" } ?? "…", fraction: performance?.cpuFraction, width: 64)
                vital("RAM", performance.map {
                    "\(ByteCountFormatter.string(fromByteCount: $0.memoryUsed, countStyle: .memory)) / \(ByteCountFormatter.string(fromByteCount: $0.memoryTotal, countStyle: .memory))"
                } ?? "—", fraction: performance.map { $0.memoryTotal > 0 ? Double($0.memoryUsed) / Double($0.memoryTotal) : 0 }, width: 142)
                if isMonitoringPaused {
                    Image(systemName: "snowflake")
                        .font(.caption.bold())
                        .foregroundStyle(.cyan)
                        .symbolEffect(.pulse)
                        .help("Live CPU and RAM monitoring is paused. It resumes automatically when the current task finishes and ADB Deck is active.")
                        .accessibilityLabel("Live monitoring paused")
                }
        }
        .opacity(isMonitoringPaused ? 0.6 : 1)
        .animation(.smooth(duration: 0.2), value: isMonitoringPaused)
    }

    private func health(_ storage: DeviceStorage, showsText: Bool) -> some View {
        Group {
            if showsText {
                Label(storage.isLow ? "Low storage" : "Healthy", systemImage: storage.isLow ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            } else {
                Image(systemName: storage.isLow ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .help(storage.isLow ? "Low storage" : "Storage healthy")
            }
        }
            .font(.caption.bold())
            .foregroundStyle(storage.isLow ? .orange : .green)
            .fixedSize()
    }

    private func metric(_ title: String, _ bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .font(.callout.monospacedDigit().weight(.medium))
        }
        .frame(minWidth: 70, alignment: .leading)
    }

    private func vital(_ title: String, _ value: String, fraction: Double?, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
                .contentTransition(.numericText())
            ProgressView(value: fraction ?? 0)
                .controlSize(.mini)
                .tint(isMonitoringPaused ? .cyan : .accentColor)
        }
        .frame(width: width, alignment: .leading)
        .help(performanceError ?? (isMonitoringPaused ? "Live monitoring paused; showing the last sample." : "Updates every 3 seconds while ADB Deck is active."))
    }
}

private struct DiscoveryLoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Locating devices…").font(.title3.weight(.semibold))
            Text("Scanning the local network and checking ADB availability")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RemoteFileRow: View {
    let file: RemoteFile
    let isMeasuringFolderSize: Bool
    let open: () -> Void
    let download: () -> Void
    let copy: () -> Void
    let cut: () -> Void
    let rename: () -> Void
    let remove: () -> Void
    let canModify: Bool

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: file.symbol)
                .font(.title2)
                .foregroundStyle(file.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 12) {
                    Text(file.permissions)
                    Text(file.modified)
                    if let size = file.isDirectory ? file.measuredSize : file.size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .contentTransition(.numericText())
                    } else if isMeasuringFolderSize {
                        ProgressView().controlSize(.mini)
                        Text("Calculating…")
                    }
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: open) { Image(systemName: file.isDirectory ? "chevron.right" : "square.and.arrow.down") }
                .buttonStyle(.borderless)
                .foregroundStyle(file.isDirectory ? Color.accentColor : .blue)
                .help(file.isDirectory ? "Open folder" : "Download")
            Menu {
                Button(file.isDirectory ? "Open" : "Download", action: open)
                if file.isDirectory { Button("Download", action: download) }
                Divider()
                Button("Copy", systemImage: "doc.on.doc", action: copy)
                Button("Move", systemImage: "scissors", action: cut).disabled(!canModify)
                Button("Rename", systemImage: "pencil", action: rename).disabled(!canModify)
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive, action: remove).disabled(!canModify)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .help("File actions")
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .contextMenu {
            Button(file.isDirectory ? "Open" : "Download", action: open)
            if file.isDirectory { Button("Download", action: download) }
            Divider()
            Button("Copy", action: copy)
            Button("Move", action: cut).disabled(!canModify)
            Button("Rename", action: rename).disabled(!canModify)
            Divider()
            Button("Delete", role: .destructive, action: remove).disabled(!canModify)
        }
    }
}

private struct TransferBanner: View {
    let transfer: TransferStatus

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.up.arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(transfer.title).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    if let fraction = transfer.fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                if let fraction = transfer.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Text(transfer.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 20, y: 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.smooth, value: transfer.fraction)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(transfer.fraction.map { "\(transfer.title), \(Int($0 * 100)) percent" } ?? "\(transfer.title), in progress")
    }
}
