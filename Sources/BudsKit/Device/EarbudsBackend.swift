import Foundation

/// Identifies a pair of earbuds across app launches, and says which backend
/// owns it.
///
/// Two backends, two kinds of identifier: CoreBluetooth hands out a
/// `CBPeripheral.identifier` (a `UUID`), IOBluetooth hands out a Bluetooth MAC
/// address. Neither is meaningful to the other, so the backend travels with
/// the id rather than being guessed from its shape.
public struct DeviceRef: Hashable, Codable, Sendable, CustomStringConvertible {

    /// The owning backend's `EarbudsBackend.id`. Persisted — never change an
    /// existing value, or every user's saved device becomes unreachable.
    public let backend: String

    /// Backend-private. A CoreBluetooth UUID string, or a MAC address.
    public let id: String

    public init(backend: String, id: String) {
        self.backend = backend
        self.id = id
    }

    /// `"<backend>:<id>"`.
    ///
    /// A colon is safe as the separator because neither id form contains one:
    /// a `UUID` string uses hyphens, and IOBluetooth's `addressString` is
    /// hyphen-separated too (`"98-80-bb-41-1a-93"`), not colon-separated as
    /// most Bluetooth tooling writes MACs.
    public var persistedForm: String { "\(backend):\(id)" }

    public var description: String { persistedForm }

    /// Parses `persistedForm`, and migrates what came before it.
    ///
    /// A value with no separator is a bare `CBPeripheral` UUID written by
    /// v1.2, which predates this type and had only one backend to belong to.
    /// Reading it as a GAIA device is what lets an upgraded install keep its
    /// selected Air4 Pro instead of silently forgetting it.
    public init(persisted: String) {
        guard let separator = persisted.firstIndex(of: ":") else {
            self.backend = Self.legacyBackendID
            self.id = persisted
            return
        }
        self.backend = String(persisted[persisted.startIndex..<separator])
        self.id = String(persisted[persisted.index(after: separator)...])
    }

    /// The only backend that existed before `DeviceRef` did.
    ///
    /// Spelled out rather than referencing `GaiaBackend.id` so this file has no
    /// dependency on a backend implementation, and so the migration cannot
    /// break if that backend is ever renamed — the *stored* value is history
    /// and does not change with the code.
    static let legacyBackendID = "gaia"
}

/// One thing a device told us.
///
/// Deliberately at the altitude of what the app needs, not of the wire. GAIA
/// has per-side battery *getters*; Samsung *pushes* one combined status
/// message. A shared command vocabulary would have to invent commands one side
/// cannot honour, so the shared vocabulary is the answers instead.
///
/// Left and right are separate cases rather than one `battery(left:right:)`
/// so nil unambiguously means "unknown", never "no news about this side".
public enum DeviceEvent: Sendable, Equatable {
    case mode(ANCMode)
    case batteryLeft(Int?)
    case batteryRight(Int?)
    case firmware(String)
}

/// Device quirks `DeviceController` cannot discover for itself.
///
/// Not speculative configuration: both fields differ between the two shipping
/// devices. The Air4 Pro serves unreliable reads for ~45 s after connect and
/// never announces its battery, so it needs both. Galaxy Buds push their full
/// state on connect and their battery on change, so it needs neither.
public struct BackendPolicy: Sendable {

    /// Offsets from the moment the connection landed at which to re-read the
    /// mode. Empty means the device pushes its state and there is nothing to
    /// settle — which is what switches off `DeviceController.settleMode`
    /// entirely, loader included.
    public var settleReads: [Duration]

    /// How often to poll the battery while connected, or nil when the device
    /// pushes battery updates itself.
    public var batteryInterval: Duration?

    public init(settleReads: [Duration] = [], batteryInterval: Duration? = nil) {
        self.settleReads = settleReads
        self.batteryInterval = batteryInterval
    }
}

/// One family of earbuds: its radio, its wire format, and its reconnect
/// strategy. `DeviceController` talks to nothing else.
///
/// Adding a device family means one conformance and one line in
/// `Backends.all`. If a new family needs `DeviceController`, `DeviceState`,
/// `ModeSnapshot` or the intents changed, this seam is in the wrong place and
/// should be moved rather than worked around.
@MainActor
public protocol EarbudsBackend: AnyObject {

    /// Stable key, stored inside every `DeviceRef`. **Never change one** — it
    /// is how a saved device finds its way back to this backend after a
    /// restart.
    static var id: String { get }

    /// Vendor name, for the Settings section header.
    static var displayName: String { get }

    var onConnectionChange: (@MainActor (ConnectionState) -> Void)? { get set }
    var onDiscoveryUpdate: (@MainActor ([DiscoveredDevice]) -> Void)? { get set }

    /// Bring the radio up and make discovery work. Must **not** connect: every
    /// backend is started so both brands show up in Settings, while only the
    /// one holding the user's saved device is adopted.
    func start()

    /// Devices already reachable, without scanning. Cheap enough to call every
    /// time Settings opens.
    func connectedDevices() -> [DiscoveredDevice]

    func startScan()
    func stopScan()

    /// Take ownership of this device and keep it connected across
    /// case-in/case-out cycles.
    func adopt(_ ref: DeviceRef)

    /// Drop the link and stop reporting connection state. Must leave nothing
    /// behind that can still mutate state — a de-selected device's
    /// notifications reaching `DeviceController` is a bug with history on the
    /// GAIA side.
    ///
    /// **Not** named `release()`, and do not rename it back. IOBluetooth is
    /// selector-driven, so a Classic backend has to be an `NSObject` subclass —
    /// and `NSObject.release()` is a witness candidate for a protocol
    /// requirement of that name even though ARC makes it unavailable. Two exact
    /// candidates means no conformance, from the *protocol* side, with nothing
    /// the backend can do about it. `disconnect()` says what it does anyway:
    /// this drops a device, not a retain count.
    func disconnect()

    /// A **fresh** stream per caller.
    ///
    /// `DeviceController` keeps one long-lived stream while `performSet` opens
    /// short-lived ones; a single shared stream would let one consumer steal
    /// another's event. Same contract, and the same reason, as
    /// `GaiaTransport.frames()`.
    func events() -> AsyncStream<DeviceEvent>

    func setMode(_ mode: ANCMode) async throws

    /// Read everything the device can tell us. Called once per connection and
    /// again on wake. A device that pushes its state implements this as
    /// whatever re-triggers that push.
    func refresh() async

    /// Re-read just the mode.
    ///
    /// Called from `DeviceController.refreshOnWake()`, and from the settle loop
    /// when `policy.settleReads` is non-empty. This — never `refresh()` — is
    /// where a backend may tear a link down and rebuild it, because nothing in
    /// the connect path calls it.
    func refreshMode() async

    /// Re-read just the battery. Called only by the battery poll, so only
    /// reachable when `policy.batteryInterval` is non-nil.
    func refreshBattery() async

    var policy: BackendPolicy { get }
}

/// Fans one device's events out to every concurrent waiter.
///
/// Identical in shape and purpose to `FrameHub` in `GaiaClient.swift`, one
/// level up: that one fans out `GaiaFrame`, this one fans out `DeviceEvent`.
/// Both backends need it, so it lives here.
public final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<DeviceEvent>.Continuation] = [:]

    public init() {}

    public func stream() -> AsyncStream<DeviceEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    public func yield(_ event: DeviceEvent) {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets { continuation.yield(event) }
    }
}

/// Every device family this app can drive.
public enum Backends {

    /// **The one list.** Adding a device family is one line here.
    ///
    /// All of them are started so both brands show up in Settings; only the one
    /// owning the user's saved device is adopted.
    @MainActor
    public static func all() -> [any EarbudsBackend] {
        // GaiaBackend needs the client twice over: as its data plane (a
        // GaiaTransport) and as its connection plane. Same object, two roles.
        let client = GaiaClient()
        return [
            GaiaBackend(transport: client, client: client),
            SamsungBackend(),
        ]
    }
}
