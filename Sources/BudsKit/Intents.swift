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

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        bridge.postRequest(.setMode(mode.asANCMode))
        return .result(dialog: IntentDialog("Set to \(mode.asANCMode.label)"))
    }
}

public struct CycleModeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Cycle Noise Mode"
    public static let description = IntentDescription(
        "Move to the next noise mode: off, then noise cancellation, then transparency."
    )
    public static var openAppWhenRun: Bool { false }

    public var injectedBridge: StateBridge?
    private var bridge: StateBridge { injectedBridge ?? .shared }

    public init() {}

    public func perform() async throws -> some IntentResult {
        bridge.postRequest(.cycleMode)
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
