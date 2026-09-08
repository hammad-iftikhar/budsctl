import Foundation
import IOBluetooth

/// Samsung Galaxy Buds over Bluetooth Classic RFCOMM.
///
/// Two things make this structurally different from `GaiaClient`, and both are
/// worth knowing before changing anything here:
///
/// 1. **There is no queued connect.** `GaiaClient`'s entire auto-reconnect
///    design rests on CoreBluetooth's promise that `connect` on an unavailable
///    peripheral stays pending and completes when the peripheral appears.
///    IOBluetooth has no equivalent, so reconnect is driven by
///    `register(forConnectNotifications:)` plus a bounded retry.
/// 2. **RFCOMM is a byte stream.** GATT notifications arrive as discrete
///    values; `rfcommChannelData` arrives as arbitrary chunks. `SppReassembler`
///    owns that problem.
///
/// An `NSObject` subclass because IOBluetooth is selector-driven: the connect
/// notification, the SDP query and the RFCOMM channel all call back by
/// selector, so this type has to be visible to the ObjC runtime. That is also
/// why `EarbudsBackend` spells its teardown hook `disconnect()` — see the note
/// on that requirement.
@MainActor
public final class SamsungBackend: NSObject, EarbudsBackend {

    public static let id = "samsung"
    public static let displayName = "Samsung"

    /// Both empty: the buds push `EXTENDED_STATUS_UPDATED` when the channel
    /// opens and `STATUS_UPDATED` on every battery or wear change. Nothing to
    /// settle, nothing to poll.
    public let policy = BackendPolicy()

    public var onConnectionChange: (@MainActor (ConnectionState) -> Void)?
    public var onDiscoveryUpdate: (@MainActor ([DiscoveredDevice]) -> Void)?

    private let hub = EventHub()
    private let frameHub = SppFrameHub()

    private var adopted: DeviceRef?
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var reassembler = SppReassembler()

    /// The current channel's identity and yield target, for `rfcommChannelData`
    /// to consult without hopping to the main actor — see `DataRoute`'s own
    /// comment for why a fresh stream is made per channel rather than one for
    /// this object's whole lifetime.
    private let dataRoute = DataRoute()

    /// Consumes the current channel's byte stream. Started by
    /// `startDataPump(for:)` when a channel opens, cancelled in
    /// `closeChannel()` — it must not outlive the channel whose bytes it is
    /// reassembling.
    private var dataPump: Task<Void, Never>?

    private var sdpQueryContinuation: CheckedContinuation<Bool, Never>?

    /// Distinguishes one SDP query from the next, so a timeout belonging to a
    /// finished query cannot resume the one currently in flight. Without it,
    /// query #1 completing quickly and query #2 starting on the retry path
    /// inside the 3 s window lets #1's orphaned timeout fail #2 — reported to
    /// the user as an unreadable service list on hardware whose SDP is fine.
    private var sdpGeneration: UInt64 = 0
    private var sdpTimeoutTask: Task<Void, Never>?

    private var connectNotification: IOBluetoothUserNotification?
    private var openAttempt = 0
    private var retryTask: Task<Void, Never>?

    /// True while `openLink()` is between its first `await` and its return.
    ///
    /// `openLink` suspends over the SDP query, and it has four callers — adopt,
    /// the connect notification, the bounded retry and `refreshMode()`. Two of
    /// them landing close together would otherwise interleave inside that
    /// suspension, and both hazards that follow from it are real: the second
    /// call overwrites `sdpQueryContinuation`, leaking the first (a leaked
    /// continuation never resumes, so its caller hangs), and it opens a second
    /// RFCOMM channel whose `openComplete` the identity guard then discards,
    /// leaving an orphaned open channel behind. Dropping the later call is
    /// right rather than merely safe: it would have opened the same channel to
    /// the same device the in-flight call is already opening.
    private var isOpening = false

    /// Retry offsets for an RFCOMM open that fails while the baseband link is
    /// up — usually buds still settling after leaving the case. Bounded, so a
    /// device that genuinely refuses SPP does not spin forever; the next
    /// connect notification is the real recovery path.
    private static let openRetries: [Duration] = [.seconds(1), .seconds(3), .seconds(7)]

    /// Tried in order at connect time. Buds2 and later, Buds FE included,
    /// publish the first; Buds Pro, Buds Live and Buds+ publish the second.
    ///
    /// Index 0 doubles as the discovery test in `connectedDevices()` — it is
    /// Samsung-specific. Index 1 must never be used for discovery: it is the
    /// generic serial-port UUID that many devices publish, the Air4 Pro
    /// included.
    static let serviceUUIDs: [[UInt8]] = [
        // 2e73a4ad-332d-41fc-90e2-16bef06523f2
        [0x2e, 0x73, 0xa4, 0xad, 0x33, 0x2d, 0x41, 0xfc,
         0x90, 0xe2, 0x16, 0xbe, 0xf0, 0x65, 0x23, 0xf2],
        // 00001101-0000-1000-8000-00805f9b34fb  (standard SPP)
        [0x00, 0x00, 0x11, 0x01, 0x00, 0x00, 0x10, 0x00,
         0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb],
    ]

    public override init() {
        super.init()
    }

    // MARK: - Lifecycle

    /// No radio to bring up: IOBluetooth has no central-manager state machine,
    /// and `pairedDevices()` works as soon as the process starts. Discovery is
    /// already available, so this only arms reconnect.
    public func start() {
        armConnectNotification()
    }

    public func adopt(_ ref: DeviceRef) {
        // Re-selecting the same device is a *retry* whenever there is no live
        // channel to protect — after a `.failed(…)` it is the only way back,
        // and swallowing it leaves the user with a dead picker.
        guard adopted != ref || channel == nil else { return }
        disconnect()
        adopted = ref
        armConnectNotification()
        Task { await openLink() }
    }

    public func disconnect() {
        retryTask?.cancel()
        retryTask = nil
        adopted = nil
        openAttempt = 0
        closeChannel()
        device = nil
        // `disconnect()` means "stop owning this device", so dropping the
        // reconnect arm is intended, not collateral: an unregistered
        // notification is also the only way IOBluetooth stops retaining `self`.
        // `start()` and `adopt()` both re-arm, so nothing is lost.
        connectNotification?.unregister()
        connectNotification = nil
    }

    private func closeChannel() {
        // Above the `channel == nil` guard, deliberately: the pump and route
        // must come down whenever this is called, not only when there is a
        // channel to close. Nothing takes that path today, but the moment
        // some future caller nils `channel` without going through here, a
        // guarded teardown would leak the pump task and leave a stale route
        // behind it.
        dataPump?.cancel()
        dataPump = nil
        // `finish()`, not just clearing the route: cancelling `dataPump` stops
        // the *consumer*, but termination should not rest on cancellation
        // alone — a stream nobody ever finishes is a suspended `for await`
        // with no way to wake on its own. `finish()` after a `yield` (or with
        // no consumer at all) is a documented no-op, so this is safe to call
        // unconditionally.
        dataRoute.value?.continuation.finish()
        dataRoute.value = nil
        guard let channel else { return }
        channel.setDelegate(nil)
        channel.close()
        self.channel = nil
        reassembler = SppReassembler()
        // Nothing else to unwind: `send` is synchronous, so there is never a
        // write in flight across a suspension for this to have to fail.
    }

    /// Starts consuming a just-opened channel's bytes.
    ///
    /// **Called from `openLink()`, immediately after `channel = opened` — not
    /// from `rfcommChannelOpenComplete`, even though that is where the
    /// equivalent per-chunk `Task` used to live.** IOBluetooth serializes
    /// callbacks on its own queue, so `rfcommChannelData` can fire — and
    /// deliver the very first bytes, `EXTENDED_STATUS_UPDATED` among them —
    /// while the `Task { @MainActor }` hop out of `rfcommChannelOpenComplete`
    /// is still enqueued and has not yet run. A route that only exists once
    /// that hop lands would drop every chunk that arrives in that window,
    /// silently: `rfcommChannelData`'s identity guard fails, not fatally, so
    /// there is nothing to see except a reassembler that never hears about
    /// the frame this whole feature exists to read. Calling this here means
    /// the route exists from the same instant `self.channel` does, before
    /// IOBluetooth has any path to deliver a single byte.
    ///
    /// A fresh `AsyncStream`/`Continuation` pair per call, not one shared
    /// stream for this object's whole lifetime: `AsyncStream` terminates for
    /// good the moment the task consuming it is cancelled — documented on
    /// `Continuation.onTermination`, "invoked ... if the task calling
    /// `next()` is cancelled" — and a second consumer attached afterward gets
    /// nothing back, not even values already yielded and buffered. Reusing
    /// one stream across a reconnect would silently drop every chunk from the
    /// second connection onward; confirmed with a standalone repro before
    /// writing this rather than assumed. A fresh pair per channel sidesteps
    /// the whole hazard: nothing is ever asked to out-live the one consumer
    /// it was made for.
    private func startDataPump(for channel: IOBluetoothRFCOMMChannel) {
        dataPump?.cancel()
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        dataRoute.value = DataRoute.Target(identifier: ObjectIdentifier(channel), continuation: continuation)
        // Same shape as `GaiaBackend`'s pump and `DeviceController`'s event
        // loop: `!Task.isCancelled` checked first, because `AsyncStream`
        // does not itself observe cancellation for an element already
        // buffered before `closeChannel()` cancels this task — that chunk
        // would otherwise still resume the loop and reach the reassembler
        // for a channel this backend has already left.
        dataPump = Task { [weak self] in
            for await chunk in chunks {
                guard let self, !Task.isCancelled else { return }
                for frame in self.reassembler.append(chunk) {
                    self.frameHub.yield(frame)
                    for event in frame.events { self.hub.yield(event) }
                }
            }
        }
    }

    private func report(_ state: ConnectionState) {
        onConnectionChange?(state)
    }

    // MARK: - Discovery

    /// Paired classic devices that plausibly are Galaxy Buds, with no inquiry.
    ///
    /// Returns instantly and works with the buds in your ears, which is what
    /// makes it usable as the default list in Settings.
    ///
    /// **The filter is not optional.** `pairedDevices()` is not service-filtered
    /// the way CoreBluetooth's `retrieveConnectedPeripherals(withServices:)` is —
    /// it returns *everything* ever paired with this Mac. Measured on the
    /// development machine it returned nine devices: a soundbar, a PS5
    /// controller, two keyboards, a mouse, a phone and another Mac. Listing
    /// those under a "Samsung" header would be nonsense.
    ///
    /// Two tests, OR'd, because each covers the other's blind spot:
    ///
    /// - **Publishes `SppNew`.** Samsung-specific, so no false positives. But a
    ///   freshly-paired device may have no cached SDP records until something
    ///   runs a query against it, and this method deliberately does not.
    /// - **Name contains `BUDS`.** Samsung names the entire lineup "Buds …"
    ///   ("Buds FE", "Buds2 Pro", "Galaxy Buds+ (1234)"), so this catches the
    ///   models that publish only the generic `SppStandard` — Buds Pro, Buds
    ///   Live, Buds+. It misses a renamed device, which is what the UUID test
    ///   is for.
    ///
    /// `SppStandard` is deliberately **not** a discovery test: it is the generic
    /// serial-port UUID, and the SoundPEATS Air4 Pro publishes it (verified —
    /// on RFCOMM channel 12). Filtering on it would offer the user their
    /// SoundPEATS buds under the Samsung backend, where every frame this
    /// backend sent would go unanswered. It stays a *connect-time* fallback in
    /// `serviceRecord(on:)`, reached only after the user explicitly picked the
    /// device.
    public func connectedDevices() -> [DiscoveredDevice] {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let samsungSpp = IOBluetoothSDPUUID(bytes: Self.serviceUUIDs[0], length: 16)
        return paired.compactMap { device -> DiscoveredDevice? in
            guard let address = device.addressString, !address.isEmpty else { return nil }
            let name = device.name ?? address
            let named = name.uppercased().contains("BUDS")
            let publishes = device.getServiceRecord(for: samsungSpp) != nil
            guard named || publishes else { return nil }
            return DiscoveredDevice(
                id: DeviceRef(backend: Self.id, id: address),
                name: name,
                // Unconditional, and honest: the guard above already dropped
                // everything that passes neither test, so whatever reaches
                // here is a likely match by definition.
                isLikelyMatch: true
            )
        }
        .sorted { $0.name < $1.name }
    }

    /// No-ops on purpose.
    ///
    /// `IOBluetoothDeviceInquiry` could find *unpaired* devices, but Galaxy Buds
    /// have to be paired in System Settings before SPP is reachable at all —
    /// which is already how this app tells users to get started. An inquiry
    /// would add a scan that cannot lead anywhere new.
    public func startScan() { onDiscoveryUpdate?(connectedDevices()) }
    public func stopScan() {}

    // MARK: - Connecting

    private func armConnectNotification() {
        guard connectNotification == nil else { return }
        // Fires when any paired device forms a baseband connection. The
        // replacement for CoreBluetooth's queued connect, which IOBluetooth
        // does not offer.
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
    }

    /// Delivered on IOBluetooth's own queue, **not** the main run loop.
    ///
    /// `register(forConnectNotifications:selector:)` takes no queue parameter
    /// and calls back on `com.apple.bluetooth.iobluetooth.coordinatorQueue`.
    /// That is the difference from `GaiaClient`, which constructs its
    /// `CBCentralManager` with `queue: .main` and so can be `@MainActor`
    /// throughout. An `@MainActor` body here traps under Swift 6 isolation
    /// checking before its first line — including before its `guard` — so the
    /// crash happens whenever any classic-Bluetooth accessory is already
    /// connected when `start()` runs.
    ///
    /// Hence `nonisolated`: take the one `Sendable` value needed, then hop.
    /// `IOBluetoothDevice` is not `Sendable` and must not cross.
    @objc nonisolated private func deviceConnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        let address = device.addressString
        Task { @MainActor [weak self] in
            guard let self, let adopted = self.adopted, address == adopted.id else { return }
            self.openAttempt = 0
            await self.openLink()
        }
    }

    private func openLink() async {
        // Named `ref`, not `adopted`, so it cannot shadow the property: a local
        // by that name is what made an earlier version of the re-checks below
        // compare `intended` to itself and silently pass.
        guard let ref = self.adopted else { return }
        guard channel == nil else { return }
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }

        guard let device = IOBluetoothDevice(addressString: ref.id) else {
            report(.failed("These earbuds are not paired with this Mac."))
            return
        }
        self.device = device
        report(.connecting)

        // The RFCOMM open API does not do this for us, and the SDP query needs
        // it too.
        if !device.isConnected() {
            let status = device.openConnection()
            guard status == kIOReturnSuccess else {
                // Timeout here means the buds are in the case. Not a failure —
                // wait for the connect notification.
                report(.waiting)
                return
            }
        }

        // A snapshot of which device this call is for, taken before the
        // suspension point below. `self.adopted` is the *live* value and can
        // change across that await — `disconnect()` nils it, `adopt(otherRef)`
        // replaces it — so comparing the two afterwards is the whole mechanism
        // that stops a resumed call acting for a device the user has left.
        let intended = ref

        // Unfiltered on purpose: an SDP query with UUIDs specified silently
        // fails on macOS Ventura and later.
        guard await performSDPQuery(device) else {
            report(.failed("Could not read the earbuds' service list."))
            return
        }

        // Re-validated after the await, and this is load-bearing. `disconnect()`
        // or `adopt(otherRef)` can run while the SDP query is in flight, and
        // `isOpening` swallows the replacement `openLink()` — so without this a
        // resumed call opens a channel to a device the user has already left,
        // assigns it to `self.channel` (making every identity guard downstream
        // pass), and the newly selected earbuds never connect.
        guard self.adopted == intended, channel == nil else {
            // `self.` because the local `let device` shadows the property here.
            self.device = nil
            // A *different* device was adopted while this call was suspended.
            // Its own `openLink()` was swallowed by `isOpening`, and there may
            // be no later trigger to rescue it — `register(forConnectNotifications:)`
            // fires on a baseband connect, which has already happened for buds
            // that are still linked. So drive it here, as this call unwinds.
            //
            // Safe against a switch to another *backend*: `AppModel.select`
            // calls `disconnect()` on the backends it did not pick, which nils
            // `adopted`, so the condition below is false and nothing is driven.
            // Scheduled rather than awaited so `isOpening`'s `defer` has run by
            // the time it executes.
            if let current = self.adopted, current != intended {
                Task { [weak self] in await self?.openLink() }
            }
            return
        }

        guard let (record, channelID) = serviceRecord(on: device) else {
            report(.failed("These earbuds do not expose the Samsung SPP service."))
            return
        }
        _ = record

        var opened: IOBluetoothRFCOMMChannel?
        let status = device.openRFCOMMChannelAsync(
            &opened,
            withChannelID: channelID,
            delegate: self
        )
        // Readiness is reported from `rfcommChannelOpenComplete`, never from
        // this return value: the reference implementation documents it coming
        // back as an error even when the channel opens fine.
        guard let opened else {
            _ = status
            scheduleOpenRetry()
            return
        }
        // `openRFCOMMChannelAsync` is another window on the same hazard: it can
        // return having already run the main run loop.
        guard self.adopted == intended, channel == nil else {
            opened.setDelegate(nil)
            opened.close()
            self.device = nil
            // Same situation one step later, so the same re-drive — see the
            // post-SDP bail-out above for why it is needed and why a backend
            // switch cannot trigger it.
            if let current = self.adopted, current != intended {
                Task { [weak self] in await self?.openLink() }
            }
            return
        }
        channel = opened
        // Here, not in `rfcommChannelOpenComplete` — see `startDataPump(for:)`
        // for why the placement is load-bearing rather than cosmetic.
        startDataPump(for: opened)
    }

    private func performSDPQuery(_ device: IOBluetoothDevice) async -> Bool {
        sdpGeneration += 1
        let generation = sdpGeneration
        return await withCheckedContinuation { continuation in
            sdpQueryContinuation = continuation
            guard device.performSDPQuery(self) == kIOReturnSuccess else {
                // Do not fail hard: the records may already be cached from a
                // previous query, so let the lookup below decide.
                resumeSDPQuery(true, generation: generation)
                return
            }
            // Bounded, so a query that never completes cannot strand the link.
            // Tracked rather than fire-and-forget so that finishing a query
            // cancels its own timeout instead of leaving it to fire into
            // whatever query is in flight three seconds later.
            sdpTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.resumeSDPQuery(false, generation: generation)
            }
        }
    }

    /// Resumes exactly once, whichever of the callback or the timeout arrives
    /// first — and only for the query that is actually in flight.
    ///
    /// `generation` is what makes a late or duplicate arrival a no-op rather
    /// than a wrong verdict: a stale timeout, or a completion for a device the
    /// backend has since left, carries an older generation and is dropped.
    private func resumeSDPQuery(_ success: Bool, generation: UInt64) {
        guard generation == sdpGeneration else { return }
        guard let continuation = sdpQueryContinuation else { return }
        sdpQueryContinuation = nil
        sdpTimeoutTask?.cancel()
        sdpTimeoutTask = nil
        continuation.resume(returning: success)
    }

    private func serviceRecord(
        on device: IOBluetoothDevice
    ) -> (IOBluetoothSDPServiceRecord, BluetoothRFCOMMChannelID)? {
        for bytes in Self.serviceUUIDs {
            // IOBluetoothSDPUUID(bytes:length:) is non-optional; only the
            // record lookup can fail.
            let uuid = IOBluetoothSDPUUID(bytes: bytes, length: 16)
            guard let record = device.getServiceRecord(for: uuid) else { continue }
            var channelID: BluetoothRFCOMMChannelID = 0
            guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { continue }
            return (record, channelID)
        }
        return nil
    }

    private func scheduleOpenRetry() {
        guard openAttempt < Self.openRetries.count else {
            // Give up and wait for the next connect notification rather than
            // spinning on a device that will not serve SPP.
            report(.waiting)
            return
        }
        let delay = Self.openRetries[openAttempt]
        openAttempt += 1
        report(.waiting)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.openLink()
        }
    }

    // MARK: - Events

    public func events() -> AsyncStream<DeviceEvent> { hub.stream() }

    /// Raw frames, before event mapping. For `budsctl-cli samsung`, which
    /// exists to print everything the buds send — including the messages this
    /// app ignores.
    public func frames() -> AsyncStream<SppFrame> { frameHub.stream() }

    // MARK: - Actions

    public func setMode(_ mode: ANCMode) async throws {
        try send(.noiseControls, [mode.rawValue])
    }

    /// Deliberately does nothing.
    ///
    /// This is the *connect* hook, and on connect there is nothing to ask for:
    /// the buds push `EXTENDED_STATUS_UPDATED` — mode and both batteries — the
    /// moment the channel opens. It is already on its way before this is
    /// called.
    ///
    /// **Do not make this reopen the channel.** Reopening re-fires
    /// `rfcommChannelOpenComplete` → `report(.ready)` →
    /// `DeviceController.connectionChanged(.ready)` → `refreshAfterConnect()` →
    /// here, which is an infinite reconnect loop. The channel reopen lives in
    /// `refreshMode()`, which nothing in the connect path calls.
    public func refresh() async {}

    /// Reopens the channel — the wake path's lever, and the only one there is.
    ///
    /// No message requests `EXTENDED_STATUS_UPDATED`; the buds send it when the
    /// channel opens, so reopening is the only way to ask "what is your state
    /// now?". Cheaper than it sounds: SPP is a control channel and A2DP audio
    /// runs independently, so the user hears nothing.
    ///
    /// Two callers, neither of them in the connect path — which is what keeps
    /// this out of the loop described on `refresh()` above. `policy.settleReads`
    /// is empty, so the settle loop never reaches it here.
    ///
    /// - `DeviceController.refreshOnWake()`, the intended one.
    /// - `DeviceController.readMode()`, from `performSet`'s reconcile after an
    ///   unconfirmed set. That one is heavy: a lost set tears the channel down
    ///   and rebuilds it, SDP query included, inside the set timeout. It stays
    ///   acceptable only because Samsung acks its sets, so the reconcile is
    ///   rare.
    ///
    /// ponytail: the blunt instrument. If a firmware ever answers message 97 as
    /// a request, send that instead and keep the channel up.
    public func refreshMode() async {
        guard adopted != nil else { return }
        closeChannel()
        openAttempt = 0
        await openLink()
    }

    /// Never called: `policy.batteryInterval` is nil, because the buds push
    /// `STATUS_UPDATED` on every battery change.
    public func refreshBattery() async {}

    /// Chunked to the channel MTU. Every message this app sends is under a
    /// dozen bytes, so the loop never runs twice — kept because dropping it
    /// would silently truncate if a longer message is ever added.
    ///
    /// `writeSync`, deliberately, not `writeAsync`. The async variant takes a
    /// pointer it may read after returning, and a Swift buffer pointer is only
    /// guaranteed valid inside its closure — the header promises only that the
    /// data "was buffered", and states elsewhere that IOBluetooth does not
    /// buffer. This blocks until the bytes reach the hardware, so there is no
    /// lifetime question. The cost is a bounded main-actor block on a payload
    /// that is never more than a dozen bytes.
    ///
    /// Synchronous also means there is no write completion to wait for, which
    /// is why this backend has no pending-write table: the return value *is*
    /// the result.
    ///
    /// ponytail: blocks the main actor for the duration of a write. Bounded and
    /// tiny for a dozen bytes on an open channel; if flow control ever stalls
    /// one (`isTransmissionPaused` exists to detect that), move `send` off the
    /// main actor rather than going back to `writeAsync`.
    private func send(_ id: SppMessageID, _ payload: [UInt8] = []) throws {
        guard let channel, channel.isOpen() else { throw SamsungError.notConnected }
        var bytes = [UInt8](SppFrame.encode(id, payload))
        let mtu = Int(channel.getMTU())
        // A zero MTU would make `count` zero and spin this loop forever on the
        // main actor — a hung menu bar with no crash to report. Unreachable
        // behind `isOpen()`, guarded anyway because the cost of being wrong is
        // a beachball and the cost of the guard is one line.
        guard mtu > 0 else { throw SamsungError.writeFailed }
        var offset = 0
        while offset < bytes.count {
            let count = min(mtu, bytes.count - offset)
            let status: IOReturn = bytes[offset..<(offset + count)]
                .withUnsafeMutableBufferPointer { channel.writeSync($0.baseAddress, length: UInt16(count)) }
            guard status == kIOReturnSuccess else { throw SamsungError.writeFailed }
            offset += count
        }
    }
}

public enum SamsungError: Error, Equatable {
    case notConnected
    case writeFailed
}

// MARK: - Radio callbacks

/// Everything IOBluetooth hands back.
///
/// Each channel callback re-checks that the channel it was given is the channel
/// this backend currently owns. Without that guard a channel the user
/// de-selected — closing asynchronously, still delivering — can feed state for
/// the wrong device, a bug `GaiaClient`'s peripheral guards exist because of.
///
/// There is no `rfcommChannelWriteComplete`: `send` is synchronous, so nothing
/// is waiting to hear about a write.
///
/// **None of these three, nor `sdpQueryComplete:status:` below, are documented
/// to arrive on the main run loop.** Neither `IOBluetoothRFCOMMChannel.h` nor
/// `IOBluetoothDevice.h` says which thread or queue calls back — the same
/// silence `register(forConnectNotifications:selector:)` left, and that one
/// turned out to call back on `com.apple.bluetooth.iobluetooth.coordinatorQueue`
/// (see `deviceConnected` above). Absent a documented guarantee, and with one
/// sibling API in this same header already proven to violate the assumption,
/// all four are treated as arriving off-main: `nonisolated`, extract what's
/// `Sendable`, then either hop or hand off. `IOBluetoothRFCOMMChannel` and
/// `IOBluetoothDevice` are not `Sendable` and must not cross — the identity
/// check that used to compare the delegate call's channel against
/// `self.channel` now compares `ObjectIdentifier`s (a `Sendable` value)
/// instead of the channel references themselves, and every actual channel
/// operation runs against `self.channel` on the main actor, never against the
/// parameter that arrived with the call.
///
/// `rfcommChannelData` is the one exception to "hop with a `Task`": see its
/// own doc comment and `DataRoute` for why a stateful byte-stream parser
/// needs `AsyncStream`'s ordering guarantee instead.
extension SamsungBackend: IOBluetoothRFCOMMChannelDelegate {

    public nonisolated func rfcommChannelOpenComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        status error: IOReturn
    ) {
        guard let rfcommChannel else { return }
        let identifier = ObjectIdentifier(rfcommChannel)
        let succeeded = error == kIOReturnSuccess
        Task { @MainActor [weak self] in
            guard let self, let channel = self.channel, ObjectIdentifier(channel) == identifier else { return }
            guard succeeded, channel.isOpen() else {
                // `closeChannel()`, not a hand-rolled teardown: `startDataPump`
                // now runs at channel-assignment time in `openLink()`, before
                // this callback is even known to fire, so by the time a failed
                // open reaches here the pump and route already exist and must
                // come down too — `closeChannel()` is where that is done.
                self.closeChannel()
                self.scheduleOpenRetry()
                return
            }
            self.openAttempt = 0
            self.report(.ready)
            // Announce ourselves, the way the reference implementation does on
            // connect. The buds push EXTENDED_STATUS_UPDATED without being asked,
            // so nothing here requests state.
            try? self.send(.managerInfo, [0x01, 0x02, 0x22])
        }
    }

    /// No `Task` here, unlike the other three callbacks in this file — see
    /// `DataRoute` and `startDataPump(for:)` for why. `AsyncStream.yield` is
    /// documented to preserve the order chunks are yielded in and to be safe
    /// to call from any thread, which an unstructured `Task` per chunk is
    /// not; a stateful byte-stream reassembler is precisely where that
    /// distinction is load-bearing rather than academic.
    public nonisolated func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        guard let rfcommChannel, let dataPointer, dataLength > 0 else { return }
        // `ObjectIdentifier`, not `===`, because the channel itself cannot
        // cross this hop-free comparison — but that is weaker than identity
        // in general: a deallocated object's address can be reused, which is
        // why `sdpGeneration` exists to distinguish one SDP query's callback
        // from a later one's. It does not apply here, though: `dataRoute` is
        // only ever set in `startDataPump(for:)`, immediately after
        // `self.channel` is assigned the same object, and only ever cleared
        // in `closeChannel()`, in the same breath as releasing `self.channel`.
        // So the identifier this route holds always names an object
        // `self.channel` is *currently, strongly* holding — for it to name a
        // dead object, that object would have to be deallocated while
        // `self.channel` still referenced it, which cannot happen. A
        // `channelGeneration` counter mirroring `sdpGeneration` was
        // considered and rejected on this basis: it would guard against a
        // hazard `ObjectIdentifier` cannot actually hit here.
        guard let target = dataRoute.value, target.identifier == ObjectIdentifier(rfcommChannel) else { return }
        // Copied into a `Sendable` buffer immediately — the raw pointer is
        // only valid for the duration of this callback.
        let chunk = Data(bytes: dataPointer, count: dataLength)
        target.continuation.yield(chunk)
    }

    public nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        guard let rfcommChannel else { return }
        let identifier = ObjectIdentifier(rfcommChannel)
        Task { @MainActor [weak self] in
            guard let self, let channel = self.channel, ObjectIdentifier(channel) == identifier else { return }
            self.closeChannel()
            // Wait for the next connect notification rather than spinning. The buds
            // are usually back in the case.
            self.report(.waiting)
        }
    }
}

extension SamsungBackend {
    /// SDP query completion. Declared `@objc` because `performSDPQuery(_:)`
    /// takes an untyped target and calls this by selector.
    ///
    /// `nonisolated` for the same reason as the RFCOMM delegate methods above:
    /// no documented run-loop guarantee. `device` is unused and dropped rather
    /// than crossing the hop — only `status`, an `IOReturn` (`Int32`, already
    /// `Sendable`), is needed.
    @objc(sdpQueryComplete:status:) nonisolated
    func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        let succeeded = status == kIOReturnSuccess
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.resumeSDPQuery(succeeded, generation: self.sdpGeneration)
        }
    }
}

/// The channel `rfcommChannelData` should currently trust, and where to yield
/// its bytes — read from whatever queue IOBluetooth calls that method back
/// on, written from the main actor whenever a channel opens or closes.
///
/// Same shape as `SppFrameHub`/`EventHub` below: a small `@unchecked Sendable`
/// box around an `NSLock`. Holds an `ObjectIdentifier` rather than the
/// channel itself because `IOBluetoothRFCOMMChannel` is not `Sendable` and
/// must not cross into `rfcommChannelData`'s nonisolated context from the
/// main actor that sets this value; it holds the `Continuation` itself
/// because that type *is* `Sendable`, so the value can be read and used
/// directly without a hop back to the main actor for every chunk.
final class DataRoute: @unchecked Sendable {
    struct Target {
        let identifier: ObjectIdentifier
        let continuation: AsyncStream<Data>.Continuation
    }

    private let lock = NSLock()
    private var target: Target?

    var value: Target? {
        get { lock.withLock { target } }
        set { lock.withLock { target = newValue } }
    }
}

/// Fans raw frames out to every concurrent waiter, for the CLI probe.
///
/// Same shape as `FrameHub` and `EventHub`; kept separate because it carries
/// `SppFrame`, which only this backend and the probe know about.
final class SppFrameHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<SppFrame>.Continuation] = [:]

    func stream() -> AsyncStream<SppFrame> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    func yield(_ frame: SppFrame) {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets { continuation.yield(frame) }
    }
}
