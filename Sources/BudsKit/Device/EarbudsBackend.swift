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
