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
    /// Serializes only the write step of successive `setMode` calls, so a
    /// superseded click's write cannot land after a newer one's. See
    /// `performSet` for why this is not the same thing as the queue that was
    /// reverted from `setMode`.
    private var writeOrder: Task<Bool, Never>?

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
                // Sleep returns early when cancelled, so check before doing
                // any work: otherwise a cancelled task still issues one last
                // refreshBattery() — two GATT writes — before the while
                // re-check ends the loop.
                guard !Task.isCancelled else { return }
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
        // Dropping the reference only. Neither GaiaClient.write nor
        // FakeTransport.write checks Task.isCancelled, so cancelling the write
        // chain cannot abort a GATT write already queued behind an earlier one.
        // What actually prevents a late write from mutating state or publishing
        // after stop() is the !Task.isCancelled guard in performSet, made true
        // by inFlight?.cancel() above — not by this call.
        writeOrder?.cancel(); writeOrder = nil
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
            // Publishes like the other three cases. It used to rely on
            // `refreshAfterConnect` publishing straight after; that tail
            // publish is gone, so without this the firmware string and its
            // warning would never reach the UI or the bridge.
            publish()

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
    /// target, and coalesces: a newer target cancels the older wait.
    public func setMode(_ target: ANCMode) {
        inFlight?.cancel()
        state.pendingMode = target
        inFlight = Task { [weak self] in await self?.performSet(target) }
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

        // The write itself is chained onto the previous write, not onto the
        // previous *wait*: `transport.write` is a fast, synchronous hand-off,
        // so this adds no perceptible latency, but it guarantees writes reach
        // the transport in the order they were issued. Without it, this
        // task's write and a click that supersedes it race on the concurrent
        // executor and can land out of order — cancelling `inFlight` above
        // only cancels the (potentially seconds-long) confirmation wait
        // below, on purpose, so the write must not depend on it either.
        let previousWrite = writeOrder
        let thisWrite = Task { [transport] in
            _ = await previousWrite?.value
            do {
                try await transport.write(.setMode, payload: [target.rawValue])
                return true
            } catch {
                return false
            }
        }
        writeOrder = thisWrite

        guard await thisWrite.value else {
            // Stopped, or superseded and the controller torn down, while this
            // write was queued behind an earlier one: do not mutate state or
            // publish after being told to stop.
            guard !Task.isCancelled else { return }
            if state.pendingMode == target { state.pendingMode = nil }
            // A refused write on a live link almost always means the buds are
            // busy with a phone. Retrying is pointless; the next unsolicited
            // notification will reconcile us.
            state.lastError = state.connection.isReady
                ? "In use by another device"
                : "Earbuds not connected"
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
        // Re-checked after the await, not only before it: a superseded set that
        // resumes here must not write `state.mode` from its own read, nor flash
        // "did not change mode" over a newer set that already succeeded.
        guard !Task.isCancelled else { return }
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
        // Nothing at the tail on purpose. `connectionChanged` already set and
        // published `.ready` before calling this, and it is the sole writer of
        // `state.connection`. Re-asserting `.ready` here after up to ~12 s of
        // awaits would resurrect a connection the user has since lost: the app
        // dispatches every connection event as its own unstructured Task, so a
        // `connectionChanged(.waiting)` can complete correctly while this task
        // is suspended inside a request. Each reply publishes via `apply`.
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
