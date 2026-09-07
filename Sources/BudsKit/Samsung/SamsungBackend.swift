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
/// Deliberately **not** an `NSObject` subclass, even though IOBluetooth is
/// selector-driven: `EarbudsBackend.release()` and `NSObject.release()` are the
/// same Swift signature, so the compiler sees two exact witnesses and refuses
/// the conformance — and nothing on the conforming side can disambiguate it
/// (`@objc(otherSelector)` does not, and renaming the protocol requirement
/// would reach into every backend and call site). The `@objc` surface
/// IOBluetooth needs therefore lives on `SamsungRadio` below, which forwards.
@MainActor
public final class SamsungBackend: EarbudsBackend {

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

    /// The `@objc` target IOBluetooth calls back on. Held strongly for this
    /// backend's whole life; it holds the backend weakly.
    private let radio = SamsungRadio()

    private var sdpQueryContinuation: CheckedContinuation<Bool, Never>?
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

    /// One writer awaiting its `rfcommChannelWriteComplete`.
    ///
    /// Keyed by `refcon` rather than by FIFO position, for the same reason
    /// `GaiaClient.PendingWrite` carries an id: a write that times out can then
    /// remove *itself* without desynchronising everyone behind it.
    private var pendingWrites: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var lastWriteID: UInt64 = 0

    /// Bounds every write in time. IOBluetooth is supposed to always call
    /// `rfcommChannelWriteComplete`, but a stale continuation would take the
    /// next write's completion and deadlock every write from then on, and a
    /// `CheckedContinuation` held in a dictionary produces no runtime warning.
    private static let writeTimeout: Duration = .seconds(5)

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

    public init() {
        radio.owner = self
    }

    // MARK: - Lifecycle

    /// No radio to bring up: IOBluetooth has no central-manager state machine,
    /// and `pairedDevices()` works as soon as the process starts. Discovery is
    /// already available, so this only arms reconnect.
    public func start() {
        armConnectNotification()
    }

    public func adopt(_ ref: DeviceRef) {
        guard adopted != ref else { return }
        release()
        adopted = ref
        armConnectNotification()
        Task { await openLink() }
    }

    public func release() {
        retryTask?.cancel()
        retryTask = nil
        adopted = nil
        openAttempt = 0
        closeChannel()
        device = nil
    }

    private func closeChannel() {
        guard let channel else { return }
        channel.setDelegate(nil)
        channel.close()
        self.channel = nil
        reassembler = SppReassembler()
        // Not optional. A leaked continuation would take the next write's
        // completion and deadlock every write after it — the same hazard
        // `GaiaClient.releasePeripheral` documents.
        failPendingWrites(SamsungError.notConnected)
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
                // Named *and* publishing is as sure as this gets without
                // connecting; either alone still belongs in the list.
                isLikelyMatch: named || publishes
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
            forConnectNotifications: radio,
            selector: #selector(SamsungRadio.deviceConnected(_:device:))
        )
    }

    fileprivate func handleDeviceConnected(_ device: IOBluetoothDevice) {
        guard let adopted, device.addressString == adopted.id else { return }
        openAttempt = 0
        Task { await openLink() }
    }

    private func openLink() async {
        guard let adopted else { return }
        guard channel == nil else { return }
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }

        guard let device = IOBluetoothDevice(addressString: adopted.id) else {
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

        // Unfiltered on purpose: an SDP query with UUIDs specified silently
        // fails on macOS Ventura and later.
        guard await performSDPQuery(device) else {
            report(.failed("Could not read the earbuds' service list."))
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
            delegate: radio
        )
        // Readiness is reported from `rfcommChannelOpenComplete`, never from
        // this return value: the reference implementation documents it coming
        // back as an error even when the channel opens fine.
        guard let opened else {
            _ = status
            scheduleOpenRetry()
            return
        }
        channel = opened
    }

    private func performSDPQuery(_ device: IOBluetoothDevice) async -> Bool {
        await withCheckedContinuation { continuation in
            sdpQueryContinuation = continuation
            guard device.performSDPQuery(radio) == kIOReturnSuccess else {
                // Do not fail hard: the records may already be cached from a
                // previous query, so let the lookup below decide.
                resumeSDPQuery(true)
                return
            }
            // Bounded, so a query that never completes cannot strand the link.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.resumeSDPQuery(false)
            }
        }
    }

    /// Resumes exactly once, whichever of the callback or the timeout arrives
    /// first.
    private func resumeSDPQuery(_ success: Bool) {
        guard let continuation = sdpQueryContinuation else { return }
        sdpQueryContinuation = nil
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
        try await send(.noiseControls, [mode.rawValue])
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
    /// Reached only from `DeviceController.refreshOnWake()` — `policy.settleReads`
    /// is empty, so the settle loop never runs for this backend. That single
    /// caller is what keeps it out of the connect path, and out of the loop
    /// described on `refresh()` above.
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

    private func send(_ id: SppMessageID, _ payload: [UInt8] = []) async throws {
        let data = SppFrame.encode(id, payload)
        try await withCheckedThrowingContinuation { continuation in
            submitWrite(data, continuation)
        }
    }

    /// Recording the continuation and calling `writeAsync` happen in one
    /// main-actor step, so a completion cannot arrive before its `refcon` is in
    /// the table.
    private func submitWrite(
        _ data: Data,
        _ continuation: CheckedContinuation<Void, Error>
    ) {
        guard let channel, channel.isOpen() else {
            continuation.resume(throwing: SamsungError.notConnected)
            return
        }
        lastWriteID += 1
        let id = lastWriteID
        pendingWrites[id] = continuation

        // Chunked to the channel MTU. Every message this app sends is under a
        // dozen bytes, so the loop never runs twice — kept because dropping it
        // would silently truncate if a longer message is ever added.
        var bytes = [UInt8](data)
        let mtu = Int(channel.getMTU())
        var status = kIOReturnSuccess
        while !bytes.isEmpty, status == kIOReturnSuccess {
            let count = min(bytes.count, mtu)
            var chunk = Array(bytes.prefix(count))
            status = chunk.withUnsafeMutableBufferPointer { buffer in
                channel.writeAsync(
                    buffer.baseAddress,
                    length: UInt16(count),
                    refcon: UnsafeMutableRawPointer(bitPattern: UInt(id))
                )
            }
            bytes.removeFirst(count)
        }

        guard status == kIOReturnSuccess else {
            completeWrite(id, error: SamsungError.writeFailed)
            return
        }

        // Not a retry and not a poll: it only ever resumes a continuation that
        // is still waiting, so nothing is re-sent to the device.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.writeTimeout)
            self?.completeWrite(id, error: SamsungError.writeFailed)
        }
    }

    /// Resumes `id` only if it is still pending. Whoever gets here first —
    /// completion, timeout, or teardown — removes the entry before resuming,
    /// which is what makes a double resume impossible.
    private func completeWrite(_ id: UInt64, error: Error?) {
        guard let continuation = pendingWrites.removeValue(forKey: id) else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    /// Drains everything, resuming each entry exactly once. Cleared before any
    /// resume so a re-entrant call cannot see the same entry twice.
    private func failPendingWrites(_ error: Error) {
        let waiting = pendingWrites
        pendingWrites.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
}

public enum SamsungError: Error, Equatable {
    case notConnected
    case writeFailed
}

// MARK: - Radio callbacks

/// Everything IOBluetooth hands back, one method per callback.
///
/// Each one re-checks that the channel it was given is the channel this backend
/// currently owns. Without that guard a channel the user de-selected — closing
/// asynchronously, still delivering — can feed state for the wrong device, a
/// bug `GaiaClient`'s peripheral guards exist because of.
extension SamsungBackend {

    fileprivate func handleOpenComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel?,
        status error: IOReturn
    ) {
        guard let rfcommChannel, rfcommChannel === channel else { return }
        guard error == kIOReturnSuccess, rfcommChannel.isOpen() else {
            channel = nil
            scheduleOpenRetry()
            return
        }
        openAttempt = 0
        report(.ready)
        // Announce ourselves, the way the reference implementation does on
        // connect. The buds push EXTENDED_STATUS_UPDATED without being asked,
        // so nothing here requests state.
        Task { try? await send(.managerInfo, [0x01, 0x02, 0x22]) }
    }

    fileprivate func handleData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel?,
        _ chunk: Data
    ) {
        guard let rfcommChannel, rfcommChannel === channel else { return }
        for frame in reassembler.append(chunk) {
            frameHub.yield(frame)
            for event in frame.events { hub.yield(event) }
        }
    }

    fileprivate func handleWriteComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel?,
        refcon: UnsafeMutableRawPointer?,
        status error: IOReturn
    ) {
        guard let rfcommChannel, rfcommChannel === channel else { return }
        let id = UInt64(UInt(bitPattern: refcon))
        completeWrite(id, error: error == kIOReturnSuccess ? nil : SamsungError.writeFailed)
    }

    fileprivate func handleClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel?) {
        guard let rfcommChannel, rfcommChannel === channel else { return }
        closeChannel()
        // Wait for the next connect notification rather than spinning. The buds
        // are usually back in the case.
        report(.waiting)
    }

    fileprivate func handleSDPQueryComplete(status error: IOReturn) {
        resumeSDPQuery(error == kIOReturnSuccess)
    }
}

/// The `@objc` half of the backend: an `NSObject` so IOBluetooth can reach it
/// by selector, and nothing else.
///
/// Exists only because `SamsungBackend` cannot itself be an `NSObject`
/// subclass — see the note on that class. Holds its owner weakly, so the
/// backend's `radio` reference is not a cycle.
///
/// ponytail: hand-written forwarding, six methods of it. Collapse it back into
/// the backend the day `EarbudsBackend.release()` is renamed to something that
/// does not collide with `NSObject.release()`.
@MainActor
final class SamsungRadio: NSObject {

    weak var owner: SamsungBackend?

    /// Fires when any paired device forms a baseband connection.
    @objc func deviceConnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        owner?.handleDeviceConnected(device)
    }

    /// SDP query completion. Declared `@objc` because `performSDPQuery(_:)`
    /// takes an untyped target and calls this by selector.
    @objc(sdpQueryComplete:status:)
    func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        owner?.handleSDPQueryComplete(status: status)
    }
}

extension SamsungRadio: @MainActor IOBluetoothRFCOMMChannelDelegate {

    func rfcommChannelOpenComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        status error: IOReturn
    ) {
        owner?.handleOpenComplete(rfcommChannel, status: error)
    }

    func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        guard let dataPointer, dataLength > 0 else { return }
        owner?.handleData(rfcommChannel, Data(bytes: dataPointer, count: dataLength))
    }

    func rfcommChannelWriteComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        refcon: UnsafeMutableRawPointer!,
        status error: IOReturn
    ) {
        owner?.handleWriteComplete(rfcommChannel, refcon: refcon, status: error)
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        owner?.handleClosed(rfcommChannel)
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
