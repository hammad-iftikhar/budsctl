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

/// Neither this intent nor `CycleNoiseModeIntent` asks to continue in the foreground,
/// and neither declares `.foreground(.dynamic)`.
///
/// They used to. `continueInForeground()` is gated on that declaration, and it was
/// there to launch the agent from a cold start. The cost turned out to be real:
/// declaring foreground support forces the intent to run in the app rather than in
/// the control extension, and this app is `LSUIElement` — no window, nothing for
/// Shortcuts' dialog presenter to attach to. Run from Spotlight, `perform()`
/// succeeded and the run then died in a modal reading "Unsupported".
/// `GetBatteryIntent`, which declares nothing and defaults to `.background`, ran
/// clean in the extension throughout.
///
/// Nothing is lost on the cold-start path: the request is already in the App Group
/// by then, and the agent drains pending requests on launch, so it applies as soon
/// as BudsCtl is opened. The intent now says so instead of trying to force it.
public struct SetModeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Set Noise Mode"
    public static let description = IntentDescription("Set the earbuds' noise mode.")
    public static var openAppWhenRun: Bool { false }

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

    /// See `CycleNoiseModeIntent.perform()` for why this returns a value and not
    /// only a dialog.
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let target = mode.asANCMode
        let seq = bridge.postRequest(.setMode(target))
        if await bridge.waitForHandling(of: seq, timeout: .seconds(2)) {
            // The agent only *took* the request here — with the buds in the
            // case that's as far as it gets. The device takes ~1.4 s to
            // apply and confirm a mode change, so wait for a published
            // snapshot to actually reflect it before telling Shortcuts this
            // worked; 3 s gives that real-world timing headroom.
            let snapshot = await bridge.waitForSnapshot(timeout: confirmationTimeout) {
                $0.connected && !$0.pending && $0.mode == target
            }
            guard snapshot.connected, !snapshot.pending, snapshot.mode == target else {
                let failure = "BudsCtl could not reach the earbuds."
                return .result(value: failure, dialog: IntentDialog(stringLiteral: failure))
            }
            return .result(value: "Set to \(target.label)", dialog: IntentDialog("Set to \(target.label)"))
        }
        // Nothing picked the request up, so the agent is not running. The
        // request stays in the App Group and the agent drains it on launch, so
        // it must not be re-posted — say so rather than pretending it applied.
        let idle = "BudsCtl is not running. Open it and this will apply."
        return .result(value: idle, dialog: IntentDialog(stringLiteral: idle))
    }
}

/// Renamed from `CycleModeIntent`, and the rename is the fix.
///
/// The AppIntents identifier is the type name, and every Spotlight run of the
/// old name ended in a modal reading "Unsupported" — with no dialog returned,
/// with a dialog, with a value, with both, at 2 ms and at 105 ms, hosted in the
/// app and in the extension. `ProbeWriteIntent`, a throwaway type with the same
/// body and result shape, ran clean on its first try. The difference was never
/// in the code: WorkflowKit stores a `ShowWhenRun` state per action identifier,
/// it was on for this one, and the result panel it then presents does not
/// render. Nothing in our reach clears that record — the store is SIP-protected
/// — so the identifier is abandoned.
///
/// Cost: a saved shortcut built against `CycleModeIntent` breaks and has to be
/// re-added. Acceptable here, where none exist.
public struct CycleNoiseModeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Cycle Noise Mode"
    public static let description = IntentDescription(
        "Move to the next noise mode: off, then noise cancellation, then transparency."
    )
    public static var openAppWhenRun: Bool { false }

    public var injectedBridge: StateBridge?
    private var bridge: StateBridge { injectedBridge ?? .shared }

    public init() {}

    /// Returns without awaiting anything, and that is the point.
    ///
    /// It used to wait for the agent to take the request (~105 ms). Run from
    /// Spotlight that was enough for Shortcuts to decide the action was slow
    /// (`shortcutShouldShowRunningProgress: 1`) and stand up its
    /// running-progress UI, which then died in a modal reading "Unsupported".
    /// `GetModeIntent` (0.1 ms) and `GetBatteryIntent` (25 ms) were identical
    /// in every other respect — same result shape, same dialog construction,
    /// same side-effect verdict — and never showed it.
    ///
    /// So the mode reported here is the one we are asking for, computed by the
    /// same rule the agent uses in `DeviceController.cycleMode`: the published
    /// snapshot already carries the optimistic mode, so both sides agree on
    /// what `next` is. Honesty comes from `connected` instead of from waiting —
    /// a request posted while the agent is down still applies when it starts,
    /// but this does not claim otherwise in the meantime.
    /// Value plus dialog, the shape `GetModeIntent` and `GetBatteryIntent` have
    /// always used without trouble.
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let snapshot = bridge.readSnapshot()
        bridge.postRequest(.cycleMode)
        guard snapshot.connected else {
            let idle = "BudsCtl is not connected to your earbuds."
            return .result(value: idle, dialog: IntentDialog(stringLiteral: idle))
        }
        // The target, not a reading: the agent applies `next` to the same
        // published snapshot in `DeviceController.cycleMode`, so both agree.
        let target = (snapshot.mode ?? .normal).next
        let text = "Noise mode is now \(target.label)"
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
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
