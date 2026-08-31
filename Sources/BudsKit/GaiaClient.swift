import Foundation
import CoreBluetooth

public struct DiscoveredDevice: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String

    /// Whether to show this in the default, filtered device list.
    public var isLikelyMatch: Bool {
        name.uppercased().contains("SOUNDPEATS")
    }

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Fans one device's frames out to every concurrent waiter.
///
/// Needed because `DeviceController` keeps a long-lived observation stream
/// while `request` and `performSet` open short-lived ones. A single shared
/// AsyncStream would let one consumer steal another's frame.
public final class FrameHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<GaiaFrame>.Continuation] = [:]

    public init() {}

    public func stream() -> AsyncStream<GaiaFrame> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    public func yield(_ frame: GaiaFrame) {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets { continuation.yield(frame) }
    }
}

/// GAIA V2 over BLE, with the pending-connection reconnect strategy.
///
/// The key CoreBluetooth behaviour this relies on: `connect` on a peripheral
/// that is not currently available does not fail — it stays queued and
/// completes the moment the peripheral appears. That single fact is the entire
/// auto-reconnect design. We never scan after first run.
@MainActor
public final class GaiaClient: NSObject, GaiaTransport {

    private let bridge: StateBridge
    private let hub = FrameHub()

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var responseCharacteristic: CBCharacteristic?

    /// One writer awaiting its ATT write response.
    ///
    /// The `id` is what makes single-resume structural: position in the FIFO is
    /// no longer an entry's only identity, so a write that times out can remove
    /// *itself* without desynchronising everyone behind it.
    private struct PendingWrite {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    /// FIFO of writers awaiting their ATT write response. CoreBluetooth
    /// delivers `didWriteValueFor` in submission order, so `didWriteValueFor`
    /// resumes the oldest *remaining* entry. Every entry leaves this array in
    /// exactly one of three ways — `didWriteValueFor`, `timeOutWrite`, or
    /// `failPendingWrites` — and each removes before it resumes.
    private var pendingWrites: [PendingWrite] = []
    private var lastWriteID: UInt64 = 0

    /// Bounds every write in time. CoreBluetooth is *supposed* to always call
    /// `didWriteValueFor`, but the whole radio layer deadlocks if it ever does
    /// not (a stale continuation would take the next write's completion), and a
    /// `CheckedContinuation` retained in an array produces no runtime warning.
    /// Comfortably above any real ATT round trip, including one queued behind
    /// another write.
    private static let writeTimeout: Duration = .seconds(5)

    private var discovered: [UUID: DiscoveredDevice] = [:]

    public var onConnectionChange: (@MainActor (ConnectionState) -> Void)?
    public var onDiscoveryUpdate: (@MainActor ([DiscoveredDevice]) -> Void)?
    public private(set) var deviceName: String?

    public init(bridge: StateBridge) {
        self.bridge = bridge
        super.init()
        // Main queue so every delegate callback is already on the main actor.
        self.central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Kick things off. Safe to call before Bluetooth is powered on — the
    /// state callback will drive the rest.
    public func start() {
        centralManagerDidUpdateState(central)
    }

    // MARK: - GaiaTransport

    public nonisolated func frames() -> AsyncStream<GaiaFrame> {
        hub.stream()
    }

    public nonisolated func write(_ command: GaiaCommand, payload: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                self.submitWrite(GaiaFrame.encode(command, payload), continuation)
            }
        }
    }

    /// Recording the continuation and calling `writeValue` must happen in one
    /// main-actor step, so the FIFO order of `pendingWrites` matches the order
    /// CoreBluetooth will report `didWriteValueFor` in.
    private func submitWrite(
        _ data: Data,
        _ continuation: CheckedContinuation<Void, Error>
    ) {
        guard let peripheral,
              let characteristic = commandCharacteristic,
              peripheral.state == .connected
        else {
            continuation.resume(throwing: GaiaError.notConnected)
            return
        }
        lastWriteID += 1
        let id = lastWriteID
        pendingWrites.append(PendingWrite(id: id, continuation: continuation))
        // .withResponse: what the official app uses, and it gives ATT-level
        // delivery confirmation. Note this is *not* a GAIA ack — 0x0311 never
        // produces one.
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        // Not a retry and not a poll: it only ever resumes a continuation that
        // is still waiting, so nothing is re-sent to the device.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.writeTimeout)
            self?.timeOutWrite(id)
        }
    }

    /// Resumes `id` only if it is still pending. If `didWriteValueFor` or
    /// `failPendingWrites` got there first the entry is gone and this is a
    /// no-op, which is what makes a double resume impossible.
    private func timeOutWrite(_ id: UInt64) {
        guard let index = pendingWrites.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingWrites.remove(at: index)
        pending.continuation.resume(
            throwing: GaiaError.writeFailed("The earbuds did not acknowledge the write.")
        )
    }

    // MARK: - Connection

    private func report(_ state: ConnectionState) {
        onConnectionChange?(state)
    }

    private func attemptConnect() {
        guard let identifier = bridge.peripheralIdentifier else {
            report(.notConfigured)
            return
        }
        let known = central.retrievePeripherals(withIdentifiers: [identifier])
        guard let found = known.first else {
            // The identifier is dead — the user re-paired. Do not spin on it.
            bridge.savePeripheralIdentifier(nil)
            report(.notConfigured)
            return
        }
        // Selecting a different device must release the old one. Otherwise
        // device A stays connected, subscribed and delegated to us, and its
        // unsolicited 0x0310 frames keep overwriting state for a device the
        // user explicitly de-selected — while its LE link never closes.
        // `!==` so re-connecting the same peripheral does not cancel the link
        // we are about to use.
        if peripheral !== found { releasePeripheral() }
        peripheral = found
        found.delegate = self
        deviceName = found.name
        report(.connecting)
        // Stays pending indefinitely if the buds are in the case. This is the
        // auto-reconnect mechanism, not a failure.
        central.connect(found, options: nil)
    }

    // MARK: - Discovery

    /// LE peripherals already connected to this Mac. No scan, so this returns
    /// instantly and works with the buds in your ears — which is what makes it
    /// usable as the default list in settings.
    ///
    /// A caveat worth knowing before you try to "fix" this: CoreBluetooth
    /// cannot enumerate all connected Bluetooth devices. The only lookup it
    /// offers is by service UUID, and classic-Bluetooth audio profiles are
    /// invisible to it entirely. So we ask for the GAIA service and the
    /// standard battery service, which between them cover the LE side of any
    /// buds worth controlling. Anything exposing neither is reachable via
    /// `startScan()`.
    public func connectedDevices() -> [DiscoveredDevice] {
        let services = [
            CBUUID(string: GaiaUUIDs.service),
            CBUUID(string: GaiaUUIDs.batteryService),
        ]
        var found: [UUID: DiscoveredDevice] = [:]
        for peripheral in central.retrieveConnectedPeripherals(withServices: services) {
            guard let name = peripheral.name, !name.isEmpty else { continue }
            found[peripheral.identifier] = DiscoveredDevice(
                id: peripheral.identifier,
                name: name
            )
        }
        return found.values.sorted { $0.name < $1.name }
    }

    /// Escalation for buds that are not currently connected to this Mac.
    ///
    /// Unfiltered on purpose: the GAIA service need not appear in the
    /// advertisement payload, so a service-filtered scan can miss the very
    /// device we are looking for. The settings list filters by name instead.
    public func startScan() {
        guard central.state == .poweredOn else { return }
        // Seed with the connected devices so the list never appears to shrink
        // when a scan starts.
        discovered = Dictionary(
            uniqueKeysWithValues: connectedDevices().map { ($0.id, $0) }
        )
        onDiscoveryUpdate?(discovered.values.sorted { $0.name < $1.name })
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    public func stopScan() {
        central.stopScan()
    }

    private func record(_ peripheral: CBPeripheral, name: String?) {
        guard let name, !name.isEmpty else { return }
        let device = DiscoveredDevice(id: peripheral.identifier, name: name)
        guard discovered[device.id] != device else { return }
        discovered[device.id] = device
        onDiscoveryUpdate?(discovered.values.sorted { $0.name < $1.name })
    }

    public func select(_ device: DiscoveredDevice) {
        stopScan()
        bridge.savePeripheralIdentifier(device.id)
        attemptConnect()
    }

    public func forgetDevice() {
        releasePeripheral()
        bridge.savePeripheralIdentifier(nil)
        report(.notConfigured)
    }

    /// Lets go of the adopted peripheral completely: closes the link, drops the
    /// delegate so its notifications can no longer reach us, and fails anything
    /// waiting on a write to it.
    ///
    /// That last part is not optional. The `didDisconnectPeripheral` that
    /// follows `cancelPeripheralConnection` hits the `peripheral === self.peripheral`
    /// identity guard and returns early, so it will not drain `pendingWrites`
    /// for us — leaking a continuation here would take the *next* write's
    /// completion and deadlock every write from then on.
    private func releasePeripheral() {
        guard let current = peripheral else { return }
        current.delegate = nil
        central.cancelPeripheralConnection(current)
        peripheral = nil
        commandCharacteristic = nil
        responseCharacteristic = nil
        failPendingWrites(GaiaError.notConnected)
    }
}

extension GaiaClient: @MainActor CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            // One call, before the per-state reporting, rather than one per
            // case: every non-powered-on state invalidates outstanding writes,
            // and a `.resetting` (a bluetoothd restart) or a revoked
            // authorisation is not guaranteed to produce a
            // `didDisconnectPeripheral` to drain them. Placed here so a state
            // added later cannot forget it.
            failPendingWrites(GaiaError.notConnected)
            switch central.state {
            case .poweredOff:
                report(.bluetoothOff)
            case .unauthorized:
                report(.failed("BudsCtl is not allowed to use Bluetooth. Check Privacy & Security settings."))
            case .unsupported:
                report(.failed("This Mac has no Bluetooth LE support."))
            default:
                // .resetting, .unknown, and anything future.
                report(.waiting)
            }
            return
        }
        attemptConnect()
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        record(peripheral, name: peripheral.name ?? advertised)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // A forgotten peripheral can still complete a connect that was in
        // flight before `forgetDevice()` ran. Ignore it — `attemptConnect` is
        // the only place that adopts a peripheral.
        guard peripheral === self.peripheral else { return }
        deviceName = peripheral.name
        peripheral.discoverServices([CBUUID(string: GaiaUUIDs.service)])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral === self.peripheral else { return }
        report(.waiting)
        central.connect(peripheral, options: nil)   // re-arm
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral === self.peripheral else { return }
        commandCharacteristic = nil
        responseCharacteristic = nil
        failPendingWrites(GaiaError.notConnected)
        report(.waiting)
        central.connect(peripheral, options: nil)   // re-arm immediately
    }

    /// Drains everything, resuming each entry exactly once. Cleared before any
    /// resume so a re-entrant call cannot see the same entry twice.
    private func failPendingWrites(_ error: Error) {
        let waiting = pendingWrites
        pendingWrites.removeAll()
        for pending in waiting { pending.continuation.resume(throwing: error) }
    }
}

extension GaiaClient: @MainActor CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard let service = peripheral.services?.first(where: {
            $0.uuid == CBUUID(string: GaiaUUIDs.service)
        }) else {
            report(.failed("These earbuds do not expose the GAIA service."))
            return
        }
        peripheral.discoverCharacteristics(
            [CBUUID(string: GaiaUUIDs.command), CBUUID(string: GaiaUUIDs.response)],
            for: service
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard peripheral === self.peripheral else { return }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case CBUUID(string: GaiaUUIDs.command): commandCharacteristic = characteristic
            case CBUUID(string: GaiaUUIDs.response): responseCharacteristic = characteristic
            default: break
            }
        }
        guard let responseCharacteristic else {
            report(.failed("The earbuds' response endpoint is missing."))
            return
        }
        // Subscribe before anything is written, or replies are lost.
        peripheral.setNotifyValue(true, for: responseCharacteristic)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral === self.peripheral else { return }
        guard characteristic.uuid == CBUUID(string: GaiaUUIDs.response) else { return }
        if let error {
            report(.failed("Could not subscribe to the earbuds: \(error.localizedDescription)"))
            return
        }
        // Ready is gated on the subscription, never on didConnect.
        report(.ready)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // The one callback that used to lack this guard. A de-selected but
        // still-connected peripheral must not feed the frame hub.
        guard peripheral === self.peripheral else { return }
        guard let data = characteristic.value else { return }
        guard let frame = GaiaFrame.decode(data) else {
            // Unknown or malformed traffic is expected from a reverse
            // engineered protocol. Log the bytes, ignore the frame.
            print("[GaiaClient] undecodable frame: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
            return
        }
        hub.yield(frame)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral === self.peripheral else { return }
        // The oldest *remaining* entry: a timed-out write has already removed
        // its own id, so removeFirst() cannot resume someone else's write.
        guard !pendingWrites.isEmpty else { return }
        let pending = pendingWrites.removeFirst()
        if let error {
            pending.continuation.resume(throwing: GaiaError.writeFailed(error.localizedDescription))
        } else {
            pending.continuation.resume()
        }
    }
}
