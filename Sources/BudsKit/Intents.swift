import Foundation
import AppIntents

/// The mode as Shortcuts sees it.
///
/// Raw values are stable identifiers baked into users' saved shortcuts. The
/// display text lives in `caseDisplayRepresentations` and can change freely;
/// these strings cannot.
public enum ANCModeAppEnum: String, AppEnum {
    case off
    case noiseCancellation
    case transparency

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Noise Mode")

    public static let caseDisplayRepresentations: [ANCModeAppEnum: DisplayRepresentation] = [
        .off: "Off",
        .noiseCancellation: "Noise Cancellation",
        .transparency: "Transparency",
    ]

    public init(_ mode: ANCMode) {
        switch mode {
        case .normal: self = .off
        case .anc: self = .noiseCancellation
        case .passthrough: self = .transparency
        }
    }

    public var asANCMode: ANCMode {
        switch self {
        case .off: .normal
        case .noiseCancellation: .anc
        case .transparency: .passthrough
        }
    }
}

/// Neither this intent nor `CycleModeIntent` conforms to `ForegroundContinuableIntent`:
/// on the macOS 26.5 SDK that protocol, and `requestToContinueInForeground()`, are
/// deprecated in favor of `AppIntent.continueInForeground(_:alwaysConfirm:)`, which
/// is available on every `AppIntent` with no protocol conformance needed. Using the
/// deprecated pair here would build clean today but leave a warning-free build
/// commitment resting on soon-to-be-removed API for no behavioral difference.
///
/// `continueInForeground()` is gated on `supportedModes` declaring
/// `.foreground(.dynamic)` — the deprecation message on `ForegroundContinuableIntent`
/// names this as the replacement mechanism, and `IntentModes.Current.canContinueInForeground`
/// strongly implies the runtime checks it. Declared below on both intents; not
/// verified at runtime (needs a GUI session — see the task report).
public struct SetModeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Set Noise Mode"
    public static let description = IntentDescription("Set the earbuds' noise mode.")
    public static var openAppWhenRun: Bool { false }
    // The SDK's replacement for ForegroundContinuableIntent: continueInForeground()
    // is gated on the intent declaring that it may run in the foreground.
    // .background is what we normally want (post to the running agent and return);
    // .foreground(.dynamic) is what permits the cold-start launch.
    public static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Mode")
    public var mode: ANCModeAppEnum

    /// Set by tests only. Deliberately not a `@Parameter`, so AppIntents does
    /// not try to surface it in Shortcuts.
    public var injectedBridge: StateBridge?
    private var bridge: StateBridge { injectedBridge ?? .shared }

    /// Set by tests only, for the same reason as `injectedBridge`: the real
    /// value gives the device's ~1.4 s apply window realistic headroom, but
    /// that makes the honest-failure path slow to exercise in a unit test.
    public var confirmationTimeout: Duration = .seconds(3)

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = mode.asANCMode
        let seq = bridge.postRequest(.setMode(target))
        if await bridge.waitForHandling(of: seq, timeout: .seconds(2)) {
            // The agent only *took* the request here — with the buds in the
            // case that's as far as it gets. The device takes ~1.4 s to
            // apply and confirm a mode change, so wait for a published
            // snapshot to actually reflect it before telling Shortcuts this
            // worked; 3 s gives that real-world timing headroom.
            let snapshot = await bridge.waitForSnapshot(timeout: confirmationTimeout) {
                $0.connected && $0.mode == target
            }
            guard snapshot.connected, snapshot.mode == target else {
                return .result(dialog: IntentDialog("BudsCtl could not reach the earbuds."))
            }
            return .result(dialog: IntentDialog("Set to \(target.label)"))
        }
        // Nothing picked the request up, so the agent is not running. Launch
        // it — it drains pending requests on start, so the original request
        // still applies and must not be re-posted.
        try await continueInForeground()
        return .result(dialog: IntentDialog("Starting BudsCtl…"))
    }
}

public struct CycleModeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Cycle Noise Mode"
    public static let description = IntentDescription(
        "Move to the next noise mode: off, then noise cancellation, then transparency."
    )
    public static var openAppWhenRun: Bool { false }
    // See SetModeIntent's supportedModes comment.
    public static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    public var injectedBridge: StateBridge?
    private var bridge: StateBridge { injectedBridge ?? .shared }

    public init() {}

    public func perform() async throws -> some IntentResult {
        let seq = bridge.postRequest(.cycleMode)
        if await bridge.waitForHandling(of: seq, timeout: .seconds(2)) {
            return .result()
        }
        try await continueInForeground()
        return .result()
    }
}

public struct GetModeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Get Noise Mode"
    public static let description = IntentDescription("Read the earbuds' current noise mode.")
    public static var openAppWhenRun: Bool { false }

    public var injectedBridge: StateBridge?
    private var bridge: StateBridge { injectedBridge ?? .shared }

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // Reads cached state only. Never opens a connection.
        let snapshot = bridge.readSnapshot()
        let text = snapshot.label
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

public struct GetBatteryIntent: AppIntent {
    public static let title: LocalizedStringResource = "Get Earbud Battery"
    public static let description = IntentDescription("Read the last known battery level of each earbud.")
    public static var openAppWhenRun: Bool { false }

    public var injectedBridge: StateBridge?
    private var bridge: StateBridge { injectedBridge ?? .shared }

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let snapshot = bridge.readSnapshot()
        let left = snapshot.batteryLeft.map { "\($0)%" } ?? "unknown"
        let right = snapshot.batteryRight.map { "\($0)%" } ?? "unknown"
        let text = "Left \(left), right \(right)"
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}
