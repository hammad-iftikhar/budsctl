import Testing
import Foundation
@testable import BudsKit

@Suite("DeviceRef")
struct DeviceRefTests {

    @Test("round-trips through its persisted form")
    func roundTrip() {
        let ref = DeviceRef(backend: "samsung", id: "98-80-bb-41-1a-93")
        #expect(DeviceRef(persisted: ref.persistedForm) == ref)
    }

    @Test("persisted form is backend, colon, id")
    func persistedForm() {
        let ref = DeviceRef(backend: "gaia", id: "2B4A9F10-0000-0000-0000-000000000000")
        #expect(ref.persistedForm == "gaia:2B4A9F10-0000-0000-0000-000000000000")
        #expect(ref.description == ref.persistedForm)
    }

    // The v1.2 defaults value was a bare CBPeripheral UUID string. An install
    // upgrading from it must keep its selected Air4 Pro, not silently forget it.
    @Test("a bare UUID predates DeviceRef and belongs to the gaia backend")
    func migratesLegacyValue() {
        let ref = DeviceRef(persisted: "2B4A9F10-0000-0000-0000-000000000000")
        #expect(ref.backend == "gaia")
        #expect(ref.id == "2B4A9F10-0000-0000-0000-000000000000")
    }

    // IOBluetooth's addressString uses hyphens ("98-80-bb-41-1a-93"), never
    // colons, which is what makes ":" a safe separator. Verified against
    // IOBluetoothDevice.pairedDevices() on macOS 26.
    @Test("a MAC address survives parsing, because it has no colons")
    func macAddressHasNoColons() {
        let ref = DeviceRef(persisted: "samsung:98-80-bb-41-1a-93")
        #expect(ref.backend == "samsung")
        #expect(ref.id == "98-80-bb-41-1a-93")
    }

    @Test("an empty id parses without crashing")
    func emptyID() {
        let ref = DeviceRef(persisted: "samsung:")
        #expect(ref.backend == "samsung")
        #expect(ref.id == "")
    }

    @Test("is Codable, so it can travel in defaults or JSON")
    func codable() throws {
        let ref = DeviceRef(backend: "samsung", id: "98-80-bb-41-1a-93")
        let data = try JSONEncoder().encode(ref)
        #expect(try JSONDecoder().decode(DeviceRef.self, from: data) == ref)
    }
}
