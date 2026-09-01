import Foundation
import Observation

public enum ConnectionState: Equatable, Sendable {
    case bluetoothOff
    case notConfigured   // no saved peripheral identifier
    case waiting         // pending connection armed, buds unavailable
    case connecting
    case ready
    case failed(String)

    public var isReady: Bool { self == .ready }

    public var label: String {
        switch self {
        case .bluetoothOff: "Bluetooth is off"
        case .notConfigured: "No earbuds selected"
        case .waiting: "Waiting for earbuds"
        case .connecting: "Connecting…"
        case .ready: "Connected"
        case .failed(let reason): reason
        }
    }
}

/// Mutated only by `DeviceController`, only on the main actor. Single writer.
@Observable
@MainActor
public final class DeviceState {
    public var connection: ConnectionState = .notConfigured
    /// Last mode the device confirmed.
    public var mode: ANCMode?
    /// Optimistic target during the device's ~1.4 s apply window.
    public var pendingMode: ANCMode?
    /// True from the moment a connection lands until the first re-read of the
    /// mode comes back.
    ///
    /// Separate from `isBusy`, which means a set of *ours* is in flight. This
    /// one means we do not yet know what the device is doing. The read taken as
    /// the link comes up is the least trustworthy one we ever take — see
    /// `DeviceController.settleMode` — so the UI says it is still reading
    /// rather than presenting that read as a confident selection.
    public var isResolvingMode = false
    public var batteryLeft: Int?
    public var batteryRight: Int?
    public var firmware: String?
    public var lastError: String?

    public init() {}

    /// What the UI renders as selected.
    public var displayMode: ANCMode? { pendingMode ?? mode }

    public var isBusy: Bool { pendingMode != nil }

    /// Template-rendered menu bar glyph. Encodes mode at a glance; the
    /// disconnected case is handled by the view's foreground style, not here.
    public var menuBarSymbol: String {
        displayMode?.symbol ?? "ear"
    }

    /// Cheap, Sendable projection for the widget extension. Reports only the
    /// confirmed mode — Control Center cannot render "in progress".
    public var snapshot: ModeSnapshot {
        ModeSnapshot(
            mode: mode,
            connected: connection.isReady,
            batteryLeft: batteryLeft,
            batteryRight: batteryRight
        )
    }
}

/// The entire contract between the agent and the control extension.
public struct ModeSnapshot: Codable, Sendable, Equatable {
    public var mode: ANCMode?
    public var connected: Bool
    public var batteryLeft: Int?
    public var batteryRight: Int?

    public init(
        mode: ANCMode?,
        connected: Bool,
        batteryLeft: Int? = nil,
        batteryRight: Int? = nil
    ) {
        self.mode = mode
        self.connected = connected
        self.batteryLeft = batteryLeft
        self.batteryRight = batteryRight
    }

    public var label: String {
        guard connected else { return "Disconnected" }
        return mode?.label ?? "Unknown"
    }

    public var symbol: String { mode?.symbol ?? "ear" }

    /// Shown in the Control Center gallery before any real state exists.
    public static let placeholder = ModeSnapshot(mode: .anc, connected: true)
}
