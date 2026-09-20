import Combine
import Sparkle
import SwiftUI

/// One updater per application, shared by every window and the app menu.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = true
    @Published private(set) var automaticallyDownloads = true
    @Published private(set) var lastCheck: Date?
    @Published private(set) var isWaitingForDeviceOperations = false

    private var busyWindows: Set<UUID> = []
    private var pendingInstall: (() -> Void)?
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
    )

    init(startAutomatically: Bool = true) {
        super.init()
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloads)
        updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastCheck)
        if startAutomatically { controller.startUpdater() }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
    func setAutomaticallyChecks(_ enabled: Bool) { controller.updater.automaticallyChecksForUpdates = enabled }
    func setAutomaticallyDownloads(_ enabled: Bool) { controller.updater.automaticallyDownloadsUpdates = enabled }

    func setDeviceBusy(_ busy: Bool, window: UUID) {
        if busy { busyWindows.insert(window) } else { busyWindows.remove(window) }
        if busyWindows.isEmpty, let install = pendingInstall {
            pendingInstall = nil
            isWaitingForDeviceOperations = false
            install()
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeRelaunchIfBusy(installHandler)
    }

    func postponeRelaunchIfBusy(_ installHandler: @escaping () -> Void) -> Bool {
        guard !busyWindows.isEmpty else { return false }
        pendingInstall = installHandler
        isWaitingForDeviceOperations = true
        return true
    }
}

struct UpdateSettingsView: View {
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        Form {
            Section {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecks }, set: updater.setAutomaticallyChecks
                ))
                Toggle("Download updates in the background", isOn: Binding(
                    get: { updater.automaticallyDownloads }, set: updater.setAutomaticallyDownloads
                ))
                .disabled(!updater.automaticallyChecks)
                Text("Signed updates come from ADB Deck’s GitHub releases. Installation and relaunch wait for active device operations to finish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Installed version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                if let lastCheck = updater.lastCheck {
                    LabeledContent("Last checked", value: lastCheck.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
                if updater.isWaitingForDeviceOperations {
                    Label("Update ready. Waiting for device operations…", systemImage: "clock")
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
