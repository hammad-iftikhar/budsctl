import Foundation
import Observation

/// Sole owner and sole writer of `DeviceState`.
///
/// Everything here assumes the device's two documented quirks: `setMode`
/// produces no reply, and the confirming `0x0310` arrives unsolicited about
/// 1.4 s later — or never.
@MainActor
@Observable
public final class DeviceController {

    public let state = DeviceState()

    private let transport: GaiaTransport
    private let bridge: StateBridge
    private let onStateChanged: @MainActor @Sendable () -> Void

    private var frameTask: Task<Void, Never>?
    private var batteryTask: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?

    /// How long to wait for the device's unsolicited confirmation.
    public var setTimeout: Duration = .seconds(3)
    /// Battery refresh interval while connected.
    public var batteryInterval: Duration = .seconds(300)

    public init(
        transport: GaiaTransport,
        bridge: StateBridge,
        onStateChanged: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.transport = transport
        self.bridge = bridge
        self.onStateChanged = onStateChanged
    }

    // MARK: - Lifecycle

    /// Begin consuming device frames. Idempotent.
    public func start() {
        guard frameTask == nil else { return }
        let stream = transport.frames()
        // Task inherits this method's MainActor isolation, so `apply` needs no
        // hop and no await.
        frameTask = Task { [weak self] in
            for await frame in stream {
                guard let self else { return }
                self.apply(frame)
            }
        }
        batteryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.batteryInterval else { return }
                try? await Task.sleep(for: interval)
                guard let self else { return }
                guard self.state.connection.isReady else { continue }
                await self.refreshBattery()
            }
        }
    }

    public func stop() {
        frameTask?.cancel(); frameTask = nil
        batteryTask?.cancel(); batteryTask = nil
        inFlight?.cancel(); inFlight = nil
    }

    // MARK: - Inbound frames

    private func apply(_ frame: GaiaFrame) {
        switch frame.command {
        case .getMode:
            guard let mode = frame.mode else { return }
            state.mode = mode
            if state.pendingMode == mode { state.pendingMode = nil }
            publish()

        case .getBatteryLeft:
            state.batteryLeft = frame.percent
            publish()

        case .getBatteryRight:
            state.batteryRight = frame.percent
            publish()

        case .getFirmware:
            guard let firmware = frame.ascii else { return }
            state.firmware = firmware
            if !firmware.contains(BudsCtl.knownGoodFirmware) {
                state.lastError = "Untested firmware (\(firmware)). Modes may not respond."
            }

        case .setMode:
            break   // never echoed back by this device
        }
    }

    private func publish() {
        bridge.publish(state.snapshot)
        onStateChanged()
    }

    // MARK: - Actions

    /// Fire and forget. Returns immediately with the UI already showing the
    /// newest target, and coalesces: the newest target owns the displayed state
    /// until it settles.
    ///
    /// Sets are queued behind one another rather than cancelling one another.
    /// Every click must reach the device — dropping one strands it on an
    /// intermediate mode — and two sets written back to back can be applied and
    /// confirmed out of order, which would leave the device on an older target.
    public func setMode(_ target: ANCMode) {
        let previous = inFlight
        state.pendingMode = target
        inFlight = Task { [weak self] in
            _ = await previous?.value
            await self?.performSet(target)
        }
    }

    public func cycleMode() {
        // No confirmed mode yet: assume off, so the first press turns ANC on —
        // the mode a user reaching for this control almost always wants.
        setMode((state.displayMode ?? .normal).next)
    }

    public func handle(_ request: BridgeRequest) {
        switch request {
        case .setMode(let mode): setMode(mode)
        case .cycleMode: cycleMode()
        }
    }

    private func performSet(_ target: ANCMode) async {
        // Subscribe before writing. The confirmation is unsolicited and can
        // arrive before a later-started listener would exist.
        let stream = transport.frames()

        do {
            try await transport.write(.setMode, payload: [target.rawValue])
        } catch {
            if state.pendingMode == target { state.pendingMode = nil }
            state.lastError = "Could not reach the earbuds"
            publish()
            return
        }

        let confirmed = await withTimeout(setTimeout) {
            for await frame in stream where frame.mode == target { return true }
            return false
        } ?? false

        // Stopped, or the connection went away while we waited.
        guard !Task.isCancelled else { return }

        // Only the newest target may clear the optimistic state; a superseded
        // set still reports what the device did, but must not stop the spinner.
        if confirmed {
            state.mode = target
            if state.pendingMode == target { state.pendingMode = nil }
            state.lastError = nil
            publish()
            return
        }

        // The set may have been silently lost. Read the truth once, then stop.
        // Reconcile and clear the optimistic state in the same turn: anything
        // that sees `isBusy` go false must already be looking at the settled mode.
        let reconciled = try? await transport.request(.getMode)
        if state.pendingMode == target { state.pendingMode = nil }
        if let actual = reconciled?.mode {
            state.mode = actual
            state.lastError = actual == target ? nil : "The earbuds did not change mode"
        } else {
            state.lastError = "No response from the earbuds"
        }
        publish()
    }

    // MARK: - Refreshes

    /// Run once per connection, after the notify subscription has landed.
    public func refreshAfterConnect() async {
        // Replies are handled by `apply` via the frame stream; the return
        // values are ignored on purpose so there is one code path into state.
        _ = try? await transport.request(.getFirmware)
        _ = try? await transport.request(.getMode)
        await refreshBattery()
        state.connection = .ready
        publish()
    }

    public func refreshBattery() async {
        _ = try? await transport.request(.getBatteryLeft)
        _ = try? await transport.request(.getBatteryRight)
    }

    /// After wake, the link usually survives but the state may be stale.
    public func refreshOnWake() async {
        guard state.connection.isReady else { return }
        _ = try? await transport.request(.getMode)
        await refreshBattery()
    }

    public func connectionChanged(_ new: ConnectionState) async {
        state.connection = new
        if !new.isReady {
            inFlight?.cancel()
            state.pendingMode = nil
            // Drop battery: a stale percentage is worse than no percentage.
            // Mode is kept — it is still the last thing the device reported.
            state.batteryLeft = nil
            state.batteryRight = nil
        }
        publish()
        if new.isReady { await refreshAfterConnect() }
    }
}
