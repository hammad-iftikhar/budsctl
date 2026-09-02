import WidgetKit
import SwiftUI
import AppIntents
import BudsKit

/// Reads the agent's cached snapshot. Must be cheap and non-blocking: the
/// control extension is a separate sandboxed process with a short execution
/// budget, and it cannot own a Bluetooth connection or wait 1.4 s for one.
struct ModeValueProvider: ControlValueProvider {
    var previewValue: ModeSnapshot { .placeholder }

    func currentValue() async throws -> ModeSnapshot {
        StateBridge.shared.readSnapshot()
    }
}

/// One button, all three modes.
///
/// macOS hosts exactly one control per extension: there is no
/// `ControlWidgetBundle` in the macOS SDK, and `ControlWidgetConfigurationBuilder`
/// takes a single configuration. So the plan's three additional direct-mode
/// controls (ANC / Transparency / Off) are not implementable here, and this
/// cycle control — the plan's own default recommendation — is the whole surface.
@main
struct NoiseModeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: ControlKind.cycle,
            provider: ModeValueProvider()
        ) { snapshot in
            ControlWidgetButton(action: ControlCycleIntent()) {
                Label(snapshot.label, systemImage: snapshot.symbol)
            }
            // Nothing to cycle with no link to the buds, and the tap would
            // otherwise fall through to launching the agent in the foreground.
            .disabled(!snapshot.connected)
        }
        .displayName("Earbuds Noise Mode")
        .description("Cycle between noise cancellation, transparency, and off.")
    }
}

/// The control's own action, deliberately not `CycleNoiseModeIntent`.
///
/// Sharing one intent type between the control and Shortcuts was the last thing
/// separating "Cycle Noise Mode" from `GetModeIntent` and `GetBatteryIntent`,
/// which run clean from Spotlight: by then the two were identical in extracted
/// metadata, parameter states, AppIntents side-effect verdict, output item count
/// and perform() duration, yet only the control-bound one ended every Spotlight
/// run in a modal reading "Unsupported".
///
/// Not discoverable: this exists for the button, and Shortcuts already has
/// `CycleNoiseModeIntent` for the same job.
struct ControlCycleIntent: AppIntent {
    static let title: LocalizedStringResource = "Cycle Noise Mode"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }

    init() {}

    /// No waiting and no dialog. A control repaints from the published
    /// snapshot, which the agent updates optimistically the moment it takes
    /// the request — there is nothing here for a result to add.
    func perform() async throws -> some IntentResult {
        StateBridge.shared.postRequest(.cycleMode)
        return .result()
    }
}
