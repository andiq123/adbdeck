import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    private enum DetailMode: String, CaseIterable { case apps = "Apps", files = "Files" }
    private enum AppSort: String, CaseIterable { case name = "Name", size = "Size" }

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
    @State private var appSort = AppSort.name
    @State private var showAddDevice = false
    @State private var manualAddress = ""
    @State private var showOtherDevices = false

    private var androidDevices: [AndroidDevice] { manager.devices.filter { $0.isAndroidLikely } }
    private var otherDevices: [AndroidDevice] { manager.devices.filter { !$0.isAndroidLikely } }

    private var filteredApps: [DeviceApp] {
        let filtered = search.isEmpty ? manager.apps : manager.apps.filter {
            $0.packageName.localizedCaseInsensitiveContains(search) || $0.displayName.localizedCaseInsensitiveContains(search)
        }
        switch appSort {
        case .name:
            return filtered.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .size:
            return filtered.sorted { ($0.storage?.total ?? -1) > ($1.storage?.total ?? -1) }
        }
    }

    private var filteredFiles: [RemoteFile] {
        guard !fileSearch.isEmpty else { return manager.files }
        return manager.files.filter { $0.name.localizedCaseInsensitiveContains(fileSearch) }
    }

    var body: some View {
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
            manager.performance = nil
            manager.performanceError = nil
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
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [UTType(filenameExtension: "apk") ?? .data, UTType(filenameExtension: "adbdeck") ?? .archive]) { result in
            guard case .success(let url) = result else { return }
            Task { await manager.install(url) }
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
            VStack(alignment: .leading, spacing: 16) {
                Label("\(failure.operation) failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.red)
                ScrollView {
                    Text(failure.details)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                HStack {
                    Button("Copy Details") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(failure.operation) failed\n\n\(failure.details)", forType: .string)
                    }
                    Spacer()
                    Button("Close") { manager.lastError = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(minWidth: 620, minHeight: 360)
        }
        .sheet(isPresented: $showAddDevice) {
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
                if manager.isRefreshing {
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
                        isLoading: manager.isWorking
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
                         : "Enable USB or network debugging in Developer options, then connect.")
                } actions: {
                    Button("Connect") { Task { await manager.connectSelected() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            if let transfer = manager.transfer {
                TransferBanner(transfer: transfer)
                    .frame(maxWidth: 620)
                    .padding(16)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    if detailMode == .apps {
                        Button { isImporting = true } label: { Label("Install app package", systemImage: "square.and.arrow.down") }
                    } else {
                        Button(action: chooseUpload) { Label("Upload", systemImage: "square.and.arrow.up") }
                        Button {
                            newFolderName = ""
                            showNewFolder = true
                        } label: { Label("New folder", systemImage: "folder.badge.plus") }
                        Button { Task { await manager.pasteFiles() } } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                            .disabled(manager.fileClipboard == nil)
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .disabled(!device.adbState.isUsable || manager.isWorking)
                Button { Task { await reloadDetail() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .disabled(!device.adbState.isUsable || manager.isWorking)
            }
        }
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
                           download: { chooseDownloadFolder(for: app) },
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
                .frame(width: 125)
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

            if manager.isWorking && manager.files.isEmpty {
                Spacer()
                ProgressView("Reading files…")
                Spacer()
            } else if filteredFiles.isEmpty {
                ContentUnavailableView("No files", systemImage: "folder", description: Text(fileSearch.isEmpty ? "This folder is empty or Android denied access." : "No items match your search."))
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
                        remove: { fileToDelete = file }
                    )
                }
                .listStyle(.inset)
                .animation(.smooth, value: filteredFiles)
                .disabled(manager.isWorking)
            }
        }
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
                    Button("Android data") { Task { await manager.loadFiles(at: "/sdcard/Android") } }
                    Divider()
                    Button("ADB temporary files") { Task { await manager.loadFiles(at: "/data/local/tmp") } }
                    Button("System root") { Task { await manager.loadFiles(at: "/") } }
                } label: {
                    Label("Locations", systemImage: "externaldrive.fill")
                }
                .frame(width: 140)
                Text(manager.currentPath)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showPermission {
                    if manager.currentPath != "/sdcard" && !manager.currentPath.hasPrefix("/sdcard/") {
                        Label("Android permissions", systemImage: "lock.shield")
                            .foregroundStyle(.secondary)
                    } else {
                        Color.clear
                    }
                }
                TextField("Search files", text: $fileSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
            }
            .font(showPermission ? .caption : .body)
    }

    private func addManualDevice() {
        let address = manualAddress
        manualAddress = ""
        showAddDevice = false
        Task { await manager.addDevice(address) }
    }

    private func reloadDetail() async {
        if detailMode == .apps {
            await manager.loadApps()
        } else {
            await manager.loadFiles()
            await manager.loadStorage()
        }
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
                .foregroundStyle(device.isAndroidLikely ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name).fontWeight(.medium).lineLimit(1).layoutPriority(1)
                    if let label = device.typeLabel {
                        Text(label)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(device.id).font(.caption.monospaced()).foregroundStyle(.secondary)
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
        .frame(height: 112)
        .background(.regularMaterial)
    }
}

private struct AppRow: View {
    let app: DeviceApp
    let isNew: Bool
    let isRemoving: Bool
    let download: () -> Void
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
            if let storage = app.storage {
                Text(ByteCountFormatter.string(fromByteCount: storage.total, countStyle: .file))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .trailing)
                    .help("App: \(ByteCountFormatter.string(fromByteCount: storage.code, countStyle: .file))\nData: \(ByteCountFormatter.string(fromByteCount: storage.data, countStyle: .file))\nCache: \(ByteCountFormatter.string(fromByteCount: storage.cache, countStyle: .file))")
            } else {
                Text("—").foregroundStyle(.tertiary).frame(width: 78, alignment: .trailing)
            }
            Button(action: download) { Image(systemName: "square.and.arrow.down") }
                .buttonStyle(.borderless)
                .help("Clone app package")
            Button(action: launch) { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .help("Open app")
            Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
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
            Button("Clone app package", action: download)
            Button("Open", action: launch)
            Divider()
            Button("Remove", role: .destructive, action: remove)
        }
    }
}

private struct StorageSummary: View {
    let storage: DeviceStorage?
    let performance: DevicePerformance?
    let performanceError: String?
    let isLoading: Bool

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
                vital("CPU", performance?.cpuFraction.map { "\(Int($0 * 100))%" } ?? "…", width: 54)
                vital("RAM", performance.map {
                    "\(ByteCountFormatter.string(fromByteCount: $0.memoryUsed, countStyle: .memory)) / \(ByteCountFormatter.string(fromByteCount: $0.memoryTotal, countStyle: .memory))"
                } ?? "—", width: 136)
        }
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

    private func vital(_ title: String, _ value: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
                .contentTransition(.numericText())
        }
        .frame(width: width, alignment: .leading)
        .help(performanceError ?? "Updates every 3 seconds while ADB Deck is active")
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
                .help(file.isDirectory ? "Open folder" : "Download")
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .contextMenu {
            Button(file.isDirectory ? "Open" : "Download", action: open)
            if file.isDirectory { Button("Download", action: download) }
            Divider()
            Button("Copy", action: copy)
            Button("Cut", action: cut)
            Button("Rename", action: rename)
            Divider()
            Button("Delete", role: .destructive, action: remove)
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
                    Text(transfer.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: transfer.fraction)
                    .progressViewStyle(.linear)
                Text(transfer.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(Color.accentColor.opacity(0.06))
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.smooth, value: transfer.fraction)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(transfer.title), \(Int(transfer.fraction * 100)) percent")
    }
}
