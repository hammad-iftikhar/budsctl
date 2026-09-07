import Foundation

/// The SoundPEATS / Qualcomm GAIA family as an `EarbudsBackend`.
///
/// Two planes, deliberately separable:
///
/// - The **data plane** is a `GaiaTransport`. That is what makes this testable:
///   `FakeTransport` already reproduces the device's real awkwardness, so the
///   frame-to-event mapping the app runs is the same one the tests run.
/// - The **connection plane** is a `GaiaClient`, and it is optional. Absent
///   means "no radio attached" — a test driving a fake transport, which reports
///   connection state by calling `onConnectionChange` itself.
@MainActor
public final class GaiaBackend: EarbudsBackend {

    public static let id = "gaia"
    public static let displayName = "SoundPEATS"

    private let transport: any GaiaTransport
    private let client: GaiaClient?
    private let hub = EventHub()
    private var pump: Task<Void, Never>?

    /// Both values are the Air4 Pro's measured quirks, moved here verbatim from
    /// `DeviceController`, where they used to be hard-coded defaults.
    ///
    /// The offsets are measured from the connection, not chained end to end —
    /// see `DeviceController.settleMode` for why, and for the capture that
    /// bracketed the settle window.
    ///
    /// `var` so tests can shorten the schedule without waiting 45 s.
    public var policy = BackendPolicy(
        settleReads: [.seconds(2), .seconds(5), .seconds(10), .seconds(20), .seconds(45)],
        batteryInterval: .seconds(300)
    )

    public var onConnectionChange: (@MainActor (ConnectionState) -> Void)? {
        didSet { client?.onConnectionChange = onConnectionChange }
    }

    public var onDiscoveryUpdate: (@MainActor ([DiscoveredDevice]) -> Void)? {
        didSet { client?.onDiscoveryUpdate = onDiscoveryUpdate }
    }

    public init(transport: any GaiaTransport, client: GaiaClient? = nil) {
        self.transport = transport
        self.client = client
    }

    // MARK: - Lifecycle

    public func start() {
        client?.start()
        guard pump == nil else { return }
        let frames = transport.frames()
        // Inherits this method's MainActor isolation, so `yield` needs no hop.
        pump = Task { [weak self] in
            for await frame in frames {
                // AsyncStream.next() does not itself observe cancellation — a
                // frame already buffered before `release()` ran would still
                // resume this loop otherwise, and reach `hub` after the
                // backend was told to stop. Checked first, so a cancelled pump
                // forwards nothing rather than one last frame.
                guard let self, !Task.isCancelled else { return }
                for event in Self.events(for: frame) { self.hub.yield(event) }
            }
        }
    }

    public func release() {
        pump?.cancel()
        pump = nil
        client?.release()
    }

    public func adopt(_ ref: DeviceRef) {
        client?.adopt(ref)
    }

    public func connectedDevices() -> [DiscoveredDevice] {
        client?.connectedDevices() ?? []
    }

    public func startScan() { client?.startScan() }
    public func stopScan() { client?.stopScan() }

    public func events() -> AsyncStream<DeviceEvent> { hub.stream() }

    // MARK: - Actions

    public func setMode(_ mode: ANCMode) async throws {
        try await transport.write(.setMode, payload: [mode.rawValue])
    }

    /// Reads everything, including firmware.
    ///
    /// Return values are ignored on purpose: replies reach state through the
    /// frame stream, so there is one code path into `DeviceState` rather than
    /// two that can disagree.
    ///
    /// ponytail: re-reads the firmware on every wake, not just on connect. One
    /// extra GATT read per wake for a version string that cannot change while
    /// the Mac sleeps; split `refresh()` in two if that ever shows up.
    public func refresh() async {
        _ = try? await transport.request(.getFirmware)
        _ = try? await transport.request(.getMode)
        await refreshBattery()
    }

    public func refreshMode() async {
        _ = try? await transport.request(.getMode)
    }

    public func refreshBattery() async {
        _ = try? await transport.request(.getBatteryLeft)
        _ = try? await transport.request(.getBatteryRight)
    }

    // MARK: - Mapping

    /// One GAIA frame's worth of device events.
    ///
    /// `setMode` is never echoed back by this device, so it maps to nothing —
    /// the confirmation arrives later as an unsolicited `getMode`.
    static func events(for frame: GaiaFrame) -> [DeviceEvent] {
        switch frame.command {
        case .getMode:
            guard let mode = frame.mode else { return [] }
            return [.mode(mode)]
        case .getBatteryLeft:
            return [.batteryLeft(frame.percent)]
        case .getBatteryRight:
            return [.batteryRight(frame.percent)]
        case .getFirmware:
            guard let firmware = frame.ascii else { return [] }
            return [.firmware(firmware)]
        case .setMode:
            return []
        }
    }
}
