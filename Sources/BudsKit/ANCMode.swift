import Foundation

public enum ANCMode: UInt8, CaseIterable, Sendable, Codable {
    case normal = 0x00
    case anc = 0x01
    case passthrough = 0x02

    /// Cycle order for the hotkey and the cycle control.
    public var next: ANCMode {
        switch self {
        case .normal: .anc
        case .anc: .passthrough
        case .passthrough: .normal
        }
    }

    public var label: String {
        switch self {
        case .normal: "Off"
        case .anc: "Noise Cancellation"
        case .passthrough: "Transparency"
        }
    }

    /// Short form for the segmented picker, where the full labels do not fit.
    public var shortLabel: String {
        switch self {
        case .normal: "Off"
        case .anc: "ANC"
        case .passthrough: "Transparency"
        }
    }

    /// SF Symbol. Verified present on macOS 26 by `budsctl-cli symbols` (Task 8).
    public var symbol: String {
        switch self {
        case .normal: "ear"
        case .anc: "waveform.slash"
        case .passthrough: "ear.and.waveform"
        }
    }
}

public extension GaiaFrame {
    /// The mode carried by a `0x0310` reply or notification, nil for anything else.
    var mode: ANCMode? {
        guard command == .getMode, let first = payload.first else { return nil }
        return ANCMode(rawValue: first)
    }
}
