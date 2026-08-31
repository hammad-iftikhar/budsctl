import Testing
import Foundation
@testable import BudsKit

@Suite("Transport contract")
struct TransportTests {

    @Test("request writes the getter and returns its reply")
    func requestRoundTrip() async throws {
        let transport = FakeTransport(mode: .passthrough)
        let frame = try await transport.request(.getMode)
        #expect(frame.mode == .passthrough)
        #expect(transport.recordedWrites().map(\.0) == [.getMode])
    }

    @Test("request surfaces a timeout rather than hanging")
    func requestTimesOut() async {
        let transport = FakeTransport()
        transport.swallowSetNotification = true
        // setMode never replies at all, which is exactly what request must not
        // be used for. Assert the failure is loud and bounded.
        await #expect(throws: GaiaError.timedOut(.setMode)) {
            _ = try await transport.request(.setMode, timeout: .milliseconds(50))
        }
    }

    @Test("request propagates a write failure")
    func requestWriteFails() async {
        let transport = FakeTransport()
        transport.failWrites = true
        await #expect(throws: GaiaError.writeFailed("fake")) {
            _ = try await transport.request(.getMode)
        }
    }

    @Test("awaitFrame catches the delayed unsolicited notification after a set")
    func awaitDelayedNotification() async throws {
        let transport = FakeTransport(mode: .normal, applyDelay: .milliseconds(50))
        // Subscribe first, write second — the real order in DeviceController.
        async let waited = transport.awaitFrame(
            .getMode,
            matching: { $0.mode == .anc },
            timeout: .seconds(1)
        )
        try await transport.write(.setMode, payload: [ANCMode.anc.rawValue])
        let frame = try #require(await waited)
        #expect(frame.mode == .anc)
    }

    @Test("awaitFrame returns nil when the notification never comes")
    func awaitTimesOut() async {
        let transport = FakeTransport(applyDelay: .milliseconds(50))
        transport.swallowSetNotification = true
        try? await transport.write(.setMode, payload: [ANCMode.anc.rawValue])
        let frame = await transport.awaitFrame(.getMode, timeout: .milliseconds(100))
        #expect(frame == nil)
    }

    @Test("two concurrent waiters both see the same frame")
    func fanOut() async throws {
        let transport = FakeTransport(applyDelay: .milliseconds(50))
        async let a = transport.awaitFrame(.getMode, timeout: .seconds(1))
        async let b = transport.awaitFrame(.getMode, timeout: .seconds(1))
        try await Task.sleep(for: .milliseconds(20))
        transport.emitModeChange(.passthrough)
        #expect(await a?.mode == .passthrough)
        #expect(await b?.mode == .passthrough)
    }

    @Test("a set-mode write carries the bare mode byte and nothing else")
    func setModePayload() async throws {
        let transport = FakeTransport(applyDelay: .milliseconds(10))
        try await transport.write(.setMode, payload: [ANCMode.passthrough.rawValue])
        let writes = transport.recordedWrites()
        #expect(writes.count == 1)
        #expect(writes[0].0 == .setMode)
        #expect(writes[0].1 == [0x02])
    }
}
