import Foundation
import Observation

/// Sole owner and sole writer of `DeviceState`.
///
/// Device-agnostic: it speaks only `EarbudsBackend`, and every quirk of a
/// particular radio or wire protocol lives behind that. What it does assume is
/// that a `setMode` may never be confirmed — some devices acknowledge it, some
/// announce the change unprompted, and some do neither — which is why
/// `setMode` publishes optimistically and `performSet` waits, then reconciles
/// by reading rather than trusting the write.
@MainActor
@Observable
public final class DeviceController {

    public let state = DeviceState()

    /// The device family currently driving this controller. Swapped by `use`.
    private var backend: any EarbudsBackend
    private let bridge: StateBridge
    private let onStateChanged: @MainActor @Sendable () -> Void

    private var frameTask: Task<Void, Never>?
    private var batteryTask: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    /// Bounded re-read of the mode over the first minute of a connection.
    /// See `settleMode` for why one read on connect is not enough.
    private var settleTask: Task<Void, Never>?
    /// Serializes only the write step of successive `setMode` calls, so a
    /// superseded click's write cannot land after a newer one's. See
    /// `performSet` for why this is not the same thing as the queue that was
    /// reverted from `setMode`.
    private var writeOrder: Task<Bool, Never>?

    /// How long to wait for the device's unsolicited confirmation.
    public var setTimeout: Duration = .seconds(3)

    public init(
        backend: any EarbudsBackend,
        bridge: StateBridge,
        onStateChanged: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.backend = backend
        self.bridge = bridge
        self.onStateChanged = onStateChanged
    }

    // MARK: - Lifecycle

    /// Begin consuming device events. Idempotent.
    public func start() {
        guard frameTask == nil else { return }
        let stream = backend.events()
        // Task inherits this method's MainActor isolation, so `apply` needs no
        // hop and no await.
        frameTask = Task { [weak self] in
            for await event in stream {
                // `!Task.isCancelled` is load-bearing, and it is new here.
                // `AsyncStream`'s iteration does not itself observe
                // cancellation: an element already buffered when `stop()` ran
                // resumes this loop anyway. Demonstrated — three events
                // buffered before `cancel()` all reached the body without this
                // guard, and none reached it with the guard.
                //
                // It matters most for `use(_:)`. Switching device families
                // calls `stop()` and then clears the readings; an event
                // buffered from the *previous* pair of earbuds would otherwise
                // land in `DeviceState` on a later main-actor turn, after the
                // clear, and be shown as this device's mode or battery.
                guard let self, !Task.isCancelled else { return }
                self.apply(event)
            }
        }
        // Only for devices that do not announce their battery. Galaxy Buds push
        // STATUS_UPDATED on every change, so polling them would be two writes
        // every five minutes for information already in hand.
        guard let interval = backend.policy.batteryInterval else { return }
        batteryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                // Sleep returns early when cancelled, so check before doing
                // any work: otherwise a cancelled task still issues one last
                // refreshBattery() — two GATT writes — before the while
                // re-check ends the loop.
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.state.connection.isReady else { continue }
                await self.backend.refreshBattery()
            }
        }
    }

    public func stop() {
        frameTask?.cancel(); frameTask = nil
        batteryTask?.cancel(); batteryTask = nil
        inFlight?.cancel(); inFlight = nil
        settleTask?.cancel(); settleTask = nil
        state.isResolvingMode = false
        // Dropping the reference only. Neither GaiaClient.write nor
        // FakeTransport.write checks Task.isCancelled, so cancelling the write
        // chain cannot abort a GATT write already queued behind an earlier one.
        // What actually prevents a late write from mutating state or publishing
        // after stop() is the !Task.isCancelled guard in performSet, made true
        // by inFlight?.cancel() above — not by this call.
        writeOrder?.cancel(); writeOrder = nil
    }

    /// Switch to a different device family.
    ///
    /// Only called when the user selects a device on the other radio; a
    /// selection within the same family goes straight to `adopt`, which already
    /// releases the previous peripheral.
    ///
    /// Clears the readings rather than keeping them: unlike a reconnect, where
    /// the last mode the device reported is still the best information we have,
    /// a mode read from a *different* pair of earbuds is not information about
    /// this one.
    public func use(_ backend: any EarbudsBackend) {
        stop()
        self.backend = backend
        state.mode = nil
        state.pendingMode = nil
        state.batteryLeft = nil
        state.batteryRight = nil
        state.firmware = nil
        state.lastError = nil
        // The clear has to reach the App Group snapshot, not just the in-process
        // observers: the Control Center widget and the intents read only that,
        // so without this they keep showing the *previous* device's mode and
        // battery — still marked connected — until the new backend's first
        // `connectionChanged` publishes.
        publish()
        start()
    }

    // MARK: - Inbound events

    private func apply(_ event: DeviceEvent) {
        switch event {
        case .mode(let mode):
            state.mode = mode
            if state.pendingMode == mode { state.pendingMode = nil }
            // Only for a backend that pushes its state unprompted: its first
            // mode IS the trustworthy one, so it is what clears the loader.
            // For GAIA the opposite holds — the read taken as the link comes up
            // is the least trustworthy one we ever take (see `settleMode`), so
            // its loader stays owned by the settle sequence and must not be
            // cleared here.
            //
            // Depends on an ordering worth naming here, because the fix and the
            // failure would be far apart: this is the *only* thing that lowers
            // the loader for a pushing backend, so a `.mode` arriving before
            // `connectionChanged(.ready)` raised it would leave the picker
            // disabled for the whole connection. It cannot arrive first. RFCOMM
            // delivers no data before the channel reports open, and IOBluetooth
            // serializes `rfcommChannelOpenComplete` and `rfcommChannelData` on
            // one queue — so the task carrying `.ready` to the main actor, and
            // the `connectionChanged` it spawns, are enqueued strictly before
            // any data frame's job. A backend that pushes its state over some
            // other transport must preserve that ordering or own its loader.
            if backend.policy.settleReads.isEmpty { clearResolving() }
            publish()

        case .batteryLeft(let percent):
            state.batteryLeft = percent
            publish()

        case .batteryRight(let percent):
            state.batteryRight = percent
            publish()

        case .firmware(let firmware):
            // Only the GAIA family emits this. Left as a plain check rather than a
            // per-backend "known good firmware" policy field: one device reports a
            // version, so a policy field would be configuration for a value that
            // never varies.
            state.firmware = firmware
            if !firmware.contains(BudsCtl.knownGoodFirmware) {
                state.lastError = "Untested firmware (\(firmware)). Modes may not respond."
            }
            // Publishes like the other three cases. It used to rely on
            // `refreshAfterConnect` publishing straight after; that tail
            // publish is gone, so without this the firmware string and its
            // warning would never reach the UI or the bridge.
            publish()
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
        // The user has told us what the mode is. Nothing the settle sequence
        // could read afterwards is worth more than that, and a re-read that
        // resolved while the device was still stale would overwrite it.
        settleTask?.cancel(); settleTask = nil
        // A mode the user picked is not something to show a loader over.
        state.isResolvingMode = false
        inFlight?.cancel()
        state.pendingMode = target
        // Publish before the write, not after the confirmation: this is the
        // only thing that repaints the Control Center button, and waiting for
        // the device made a tap look like it did nothing for ~1.4 s.
        publish()
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
        let stream = backend.events()

        // The write itself is chained onto the previous write, not onto the
        // previous *wait*: `transport.write` is a fast, synchronous hand-off,
        // so this adds no perceptible latency, but it guarantees writes reach
        // the transport in the order they were issued. Without it, this
        // task's write and a click that supersedes it race on the concurrent
        // executor and can land out of order — cancelling `inFlight` above
        // only cancels the (potentially seconds-long) confirmation wait
        // below, on purpose, so the write must not depend on it either.
        let previousWrite = writeOrder
        let thisWrite = Task { [backend] in
            _ = await previousWrite?.value
            do {
                try await backend.setMode(target)
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
            for await event in stream where event == .mode(target) { return true }
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
        let reconciled = await readMode(timeout: setTimeout)
        // Re-checked after the await, not only before it: a superseded set that
        // resumes here must not write `state.mode` from its own read, nor flash
        // "did not change mode" over a newer set that already succeeded.
        guard !Task.isCancelled else { return }
        if state.pendingMode == target { state.pendingMode = nil }
        if let actual = reconciled {
            state.mode = actual
            state.lastError = actual == target ? nil : "The earbuds did not change mode"
        } else {
            state.lastError = "No response from the earbuds"
        }
        publish()
    }

    /// Ask the device for its mode and wait for the answer.
    ///
    /// The stream is opened before the read is triggered. Opening it after
    /// would drop an answer that arrives faster than we can subscribe — the
    /// same class of bug as writing before the notify subscription lands.
    private func readMode(timeout: Duration) async -> ANCMode? {
        let stream = backend.events()
        // Not awaited: `refreshMode()` has its own internal timeout, and
        // awaiting it before opening the window below serialised the two into a
        // ~9 s worst case for a set that never confirms. The answer arrives on
        // the event stream regardless of who is waiting, so start the read and
        // watch for it concurrently.
        Task { [backend] in await backend.refreshMode() }
        let raced: ANCMode?? = await withTimeout(timeout) { () -> ANCMode? in
            for await event in stream {
                if case .mode(let mode) = event { return mode }
            }
            return nil
        }
        return raced ?? nil
    }

    // MARK: - Refreshes

    /// Run once per connection, after the notify subscription has landed.
    public func refreshAfterConnect() async {
        await backend.refresh()
        // Nothing at the tail on purpose. `connectionChanged` already set and
        // published `.ready` before calling this, and it is the sole writer of
        // `state.connection`. Re-asserting `.ready` here after up to ~12 s of
        // awaits would resurrect a connection the user has since lost: the app
        // dispatches every connection event as its own unstructured Task, so a
        // `connectionChanged(.waiting)` can complete correctly while this task
        // is suspended inside a request. Each reply publishes via `apply`.
    }

    /// Re-read the mode a few times over the first minute of a connection.
    ///
    /// Measured on an Air4 Pro (firmware `..._v0.2.1`): the earbuds do not
    /// reliably serve GAIA reads in the window right after the link comes up.
    /// A read taken there either times out outright or answers `0x00` (Off)
    /// while the buds are actually in ANC — and the device sends *nothing*
    /// when it later adopts its saved mode. Thirty-three seconds of complete
    /// notification silence were recorded after a case-exit connect, while a
    /// read taken afterwards reported ANC correctly.
    ///
    /// So the single read in `refreshAfterConnect` is not enough on its own,
    /// and there is no notification that would ever correct it. That is the
    /// whole bug: the app showed "Off" for the rest of the connection.
    ///
    /// This is not the plan's "never poll the mode" rule being broken. It is
    /// bounded, runs at most once per connection, stops the moment the user
    /// sets a mode, and issues five reads rather than a steady stream.
    ///
    /// The offsets are measured from the connection, not chained end to end.
    /// Chaining them let one timed-out read — and an unsettled device times
    /// reads out, which is the whole problem here — push every later read out
    /// by the 3 s timeout, so a nominal 5/20/60 s schedule really fired at
    /// 5/25/85 s. Anchoring to a start instant keeps the last read where it
    /// says it is however many earlier ones failed.
    ///
    /// ponytail: fixed offsets, not a characterised settle window — the window
    /// was only ever bracketed as "wrong at connect, right within 44 s", so
    /// the early reads are cheap guesses at the near edge and the 45 s one is
    /// the backstop. Re-reads are safe to pile on because the device settles
    /// one way: once it answers with the real mode it does not go back to
    /// `0x00`. If buds turn up that settle later, extend the list rather than
    /// making it continuous.
    private func settleMode() async {
        // No `defer` clearing the flag on the way out. Every exit from this
        // loop is a cancellation, and all three cancellers — connectionChanged,
        // setMode, stop — clear it themselves, synchronously. A defer here
        // would run whenever this task next got scheduled, which can be after
        // a *later* connection has raised the flag again, and would then clear
        // that connection's loader instead of this one's.
        let start = ContinuousClock.now
        for offset in backend.policy.settleReads {
            let remaining = start + offset - ContinuousClock.now
            if remaining > .zero { try? await Task.sleep(for: remaining) }
            // Re-checked after every sleep: the buds can go back in the case,
            // and a set in flight is a better source of truth than a re-read.
            guard !Task.isCancelled,
                  state.connection.isReady,
                  state.pendingMode == nil
            else { return }
            // The answer reaches `state` through `apply`, like every other read.
            await backend.refreshMode()
            // The UI stops waiting after the *first* of these lands, not after
            // all of them. The later reads are silent corrections; blocking the
            // picker for 45 s to wait them out would be far worse than showing
            // the best answer so far.
            clearResolving()
        }
    }

    private func clearResolving() {
        guard state.isResolvingMode else { return }
        state.isResolvingMode = false
        publish()
    }

    public func refreshBattery() async {
        await backend.refreshBattery()
    }

    /// After wake, the link usually survives but the state may be stale.
    ///
    /// Deliberately `refreshMode()` + `refreshBattery()` rather than
    /// `refresh()`, which restores this method's original behaviour exactly
    /// (it read the mode and both batteries, never the firmware) — and, more
    /// importantly, breaks a reconnect loop.
    ///
    /// `refresh()` is the *connect* hook. On a device that pushes its state
    /// when a link comes up, prompting it means tearing the link down and
    /// rebuilding it, which re-fires `connectionChanged(.ready)` and calls
    /// `refreshAfterConnect` again — forever. Keeping the wake path on the
    /// narrower hooks means the only method that may reopen a link is one
    /// nothing in the connect path calls.
    public func refreshOnWake() async {
        guard state.connection.isReady else { return }
        await backend.refreshMode()
        await backend.refreshBattery()
    }

    public func connectionChanged(_ new: ConnectionState) async {
        let wasReady = state.connection.isReady
        state.connection = new
        // An error belongs to the connection that produced it: "Earbuds not
        // connected" from a set attempted while they were away outlived the
        // reconnect and sat there next to a green dot until the next set.
        // Only on a readiness *change*, so a redundant .ready -> .ready cannot
        // wipe a live "In use by another device". Cleared before
        // `refreshAfterConnect()`, which is what raises the firmware warning.
        if new.isReady != wasReady { state.lastError = nil }
        // Cancelled on every transition, including .ready -> .ready: a settle
        // sequence belongs to the connection that started it.
        settleTask?.cancel(); settleTask = nil
        if !new.isReady {
            inFlight?.cancel()
            state.pendingMode = nil
            // Drop battery: a stale percentage is worse than no percentage.
            // Mode is kept — it is still the last thing the device reported.
            state.batteryLeft = nil
            state.batteryRight = nil
        }
        // Raised before the reads, not after: the connect read is exactly the
        // one the UI must not present as settled truth. Assigned from
        // `new.isReady` rather than set to `true` here and `false` in the
        // branch above, so there is one place that decides it and no ordering
        // to get wrong.
        state.isResolvingMode = new.isReady
        publish()
        guard state.connection.isReady else { return }
        await refreshAfterConnect()
        // Started after the refresh, and only if the link is still up: the
        // refresh takes up to ~12 s of awaits, and the buds can be back in
        // the case by the time it returns.
        guard state.connection.isReady else { return }
        // A device that pushes its state on connect has no settle sequence to
        // run — but the loader must NOT clear here. `displayMode` is still nil
        // at this point, and the panel renders a nil mode as `.normal` with the
        // picker enabled: a confident "Off" for a device whose mode we have not
        // read. That is exactly the failure the byte-12 guards in `SppEvents`
        // exist to prevent, and the comment there promises this behaviour.
        // The loader is cleared by `apply(.mode)` instead, when a real mode
        // actually arrives.
        guard !backend.policy.settleReads.isEmpty else { return }
        settleTask = Task { [weak self] in await self?.settleMode() }
    }
}
