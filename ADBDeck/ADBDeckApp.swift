import SwiftUI

@main
struct ADBDeckApp: App {
    @StateObject private var updater = AppUpdater()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(updater)
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        Settings {
            UpdateSettingsView().environmentObject(updater)
        }
    }
}

