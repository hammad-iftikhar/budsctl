import Testing
import Foundation
@testable import BudsKit

@MainActor
@Suite("GaiaBackend")
struct GaiaBackendTests {

    /// Collects events from a fresh stream until `count` have arrived.
    private func collect(
        _ backend: GaiaBackend,
        count: Int,
        timeout: Duration = .seconds(2),
        while body: () async -> Void
    ) async -> [DeviceEvent] {
        let stream = backend.events()
        let task = Task { () -> [DeviceEvent] in
            var events: [DeviceEvent] = []
            for await event in stream {
                events.append(event)
                if events.count == count { return events }
            }
            return events
        }
        await body()
        let raced = await withTimeout(timeout) { await task.value }
        task.cancel()
        return raced ?? []
    }

    @Test("has the persisted backend id")
    func backendID() {
        #expect(GaiaBackend.id == "gaia")
    }

    @Test("the policy carries the Air4 Pro's two quirks")
    func policy() {
        let backend = GaiaBackend(transport: FakeTransport())
        #expect(backend.policy.settleReads.isEmpty == false,
                "the device serves unreliable reads for ~45 s after connect")
        #expect(backend.policy.batteryInterval != nil,
                "the device never announces its battery")
    }

    @Test("a mode frame becomes a mode event")
    func modeEvent() async {
        let transport = FakeTransport(mode: .normal)
        let backend = GaiaBackend(transport: transport)
        backend.start()
        let events = await collect(backend, count: 1) {
            transport.emitModeChange(.passthrough)
        }
        #expect(events == [.mode(.passthrough)])
    }

    @Test("battery frames become per-side events")
    func batteryEvents() async {
        let transport = FakeTransport()
        transport.batteryLeft = 71
        transport.batteryRight = 64
        let backend = GaiaBackend(transport: transport)
        backend.start()
        let events = await collect(backend, count: 2) {
            await backend.refreshBattery()
        }
        #expect(events.contains(.batteryLeft(71)))
        #expect(events.contains(.batteryRight(64)))
    }

    @Test("a firmware frame becomes a firmware event")
    func firmwareEvent() async {
        let transport = FakeTransport()
        transport.firmware = "AIR4PRO-BS588R2E_20241112_v0.2.1"
        let backend = GaiaBackend(transport: transport)
        backend.start()
        let events = await collect(backend, count: 1) {
            _ = try? await transport.request(.getFirmware)
        }
        #expect(events == [.firmware("AIR4PRO-BS588R2E_20241112_v0.2.1")])
    }

    @Test("a battery reading above 100 becomes nil, not a bogus percentage")
    func implausibleBattery() async {
        let transport = FakeTransport()
        transport.batteryLeft = 0xFF
        let backend = GaiaBackend(transport: transport)
        backend.start()
        let events = await collect(backend, count: 1) {
            _ = try? await transport.request(.getBatteryLeft)
        }
        #expect(events == [.batteryLeft(nil)])
    }

    @Test("setMode writes the mode byte to the transport")
    func setModeWrites() async throws {
        let transport = FakeTransport(applyDelay: .milliseconds(10))
        let backend = GaiaBackend(transport: transport)
        backend.start()
        try await backend.setMode(.anc)
        let writes = transport.recordedWrites()
        #expect(writes.contains { $0.0 == .setMode && $0.1 == [ANCMode.anc.rawValue] })
    }

    @Test("refresh reads firmware, mode and both batteries")
    func refreshReadsEverything() async {
        let transport = FakeTransport()
        let backend = GaiaBackend(transport: transport)
        backend.start()
        await backend.refresh()
        let commands = transport.recordedWrites().map(\.0)
        #expect(commands.contains(.getFirmware))
        #expect(commands.contains(.getMode))
        #expect(commands.contains(.getBatteryLeft))
        #expect(commands.contains(.getBatteryRight))
        #expect(commands.contains(.setMode) == false, "refreshing must not write a mode")
    }

    @Test("a write failure propagates instead of being swallowed")
    func writeFailurePropagates() async {
        let transport = FakeTransport()
        transport.failWrites = true
        let backend = GaiaBackend(transport: transport)
        backend.start()
        await #expect(throws: (any Error).self) { try await backend.setMode(.anc) }
    }

    @Test("each caller gets its own stream, so no one steals another's event")
    func streamsAreIndependent() async {
        let transport = FakeTransport()
        let backend = GaiaBackend(transport: transport)
        backend.start()
        let first = backend.events()
        let second = backend.events()
        // Explicit return type: without it the trailing `return nil` cannot be
        // inferred against the `return event` above it.
        let a = Task { () -> DeviceEvent? in
            for await event in first { return event }
            return nil
        }
        let b = Task { () -> DeviceEvent? in
            for await event in second { return event }
            return nil
        }
        transport.emitModeChange(.anc)
        #expect(await a.value == .mode(.anc))
        #expect(await b.value == .mode(.anc))
    }

    @Test("stop ends the mapping, so a later frame produces nothing")
    func stopEndsMapping() async {
        let transport = FakeTransport()
        let backend = GaiaBackend(transport: transport)
        backend.start()
        backend.disconnect()
        let stream = backend.events()
        transport.emitModeChange(.anc)
        let raced = await withTimeout(.milliseconds(200)) { () -> DeviceEvent? in
            for await event in stream { return event }
            return nil
        }
        #expect((raced ?? nil) == nil)
    }
}
