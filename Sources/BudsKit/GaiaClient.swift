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

    /// FIFO of writers awaiting their ATT write response. CoreBluetooth
    /// delivers `didWriteValueFor` in submission order.
    private var pendingWrites: [CheckedContinuation<Void, Error>] = []

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
        pendingWrites.append(continuation)
        // .withResponse: what the official app uses, and it gives ATT-level
        // delivery confirmation. Note this is *not* a GAIA ack — 0x0311 never
        // produces one.
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
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
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        commandCharacteristic = nil
        responseCharacteristic = nil
        bridge.savePeripheralIdentifier(nil)
        report(.notConfigured)
    }
}

extension GaiaClient: @MainActor CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            attemptConnect()
        case .poweredOff:
            failPendingWrites(GaiaError.notConnected)
            report(.bluetoothOff)
        case .unauthorized:
            report(.failed("BudsCtl is not allowed to use Bluetooth. Check Privacy & Security settings."))
        case .unsupported:
            report(.failed("This Mac has no Bluetooth LE support."))
        case .resetting, .unknown:
            report(.waiting)
        @unknown default:
            report(.waiting)
        }
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

    private func failPendingWrites(_ error: Error) {
        let waiting = pendingWrites
        pendingWrites.removeAll()
        for continuation in waiting { continuation.resume(throwing: error) }
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
        guard !pendingWrites.isEmpty else { return }
        let continuation = pendingWrites.removeFirst()
        if let error {
            continuation.resume(throwing: GaiaError.writeFailed(error.localizedDescription))
        } else {
            continuation.resume()
        }
    }
}
