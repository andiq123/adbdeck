import SwiftUI

@main
struct ADBDeckApp: App {
    @StateObject private var updater = AppUpdater()
    var body: some Scene {
        WindowGroup {
            GeometryReader { viewport in
                ContentView(viewportHeight: viewport.size.height)
                    .environmentObject(updater)
                    .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
            }
            .frame(minWidth: 940, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
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
