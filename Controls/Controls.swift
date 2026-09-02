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
            ControlWidgetButton(action: CycleModeIntent()) {
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
