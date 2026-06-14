import SwiftUI

@main
struct FilePackrApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 760, minHeight: 480)
                .environmentObject(Localizer.shared)
                .environmentObject(AppSettings.shared)
        }
        .windowStyle(.titleBar)
    }
}
