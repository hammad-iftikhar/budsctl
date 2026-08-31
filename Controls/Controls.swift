import WidgetKit
import SwiftUI
import AppIntents
import BudsKit

// `ControlWidgetBundle` (the brief's literal `@main` entry point) does not
// exist in the macOS SDK — it is iOS/watchOS-only. On macOS a single
// `ControlWidget` conformer is `@main` directly, via the `static func main()`
// that SwiftUI's `ControlWidget` extension supplies (macOS 26.0+).
@main
struct PlaceholderControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlKind.cycle) {
            ControlWidgetButton(action: PlaceholderIntent()) {
                Label("BudsCtl", systemImage: "ear")
            }
        }
        .displayName("BudsCtl")
    }
}

struct PlaceholderIntent: AppIntent {
    static let title: LocalizedStringResource = "Placeholder"
    func perform() async throws -> some IntentResult { .result() }
}
