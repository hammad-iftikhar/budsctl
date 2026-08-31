import SwiftUI
import BudsKit

@main
struct BudsCtlApp: App {
    var body: some Scene {
        MenuBarExtra("BudsCtl", systemImage: "ear") {
            Text("App group available: \(StateBridge.shared.appGroupAvailable ? "yes" : "NO")")
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
