import Testing
import Foundation
@testable import BudsKit

@Suite("StateBridge")
struct StateBridgeTests {

    /// A private, empty defaults domain per test. No App Group entitlement
    /// needed, so these run under `swift test` with no signing at all.
    private func scratchDefaults() -> UserDefaults {
        let suite = "budsctl.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("a published snapshot reads back identically")
    func snapshotRoundTrip() {
        let bridge = StateBridge(defaults: scratchDefaults())
        let snapshot = ModeSnapshot(mode: .passthrough, connected: true, batteryLeft: 42, batteryRight: 43)
        bridge.publish(snapshot)
        #expect(bridge.readSnapshot() == snapshot)
    }

    @Test("reading before anything is published gives a disconnected snapshot")
    func snapshotDefault() {
        let bridge = StateBridge(defaults: scratchDefaults())
        let snapshot = bridge.readSnapshot()
        #expect(snapshot.connected == false)
        #expect(snapshot.mode == nil)
    }

    @Test("a posted request is taken exactly once")
    func requestTakenOnce() {
        let bridge = StateBridge(defaults: scratchDefaults())
        bridge.postRequest(.setMode(.anc))
        #expect(bridge.takeRequest() == .setMode(.anc))
        // A coalesced or replayed Darwin notification must not re-fire the set.
        #expect(bridge.takeRequest() == nil)
    }

    @Test("taking with no request pending gives nil")
    func noRequest() {
        let bridge = StateBridge(defaults: scratchDefaults())
        #expect(bridge.takeRequest() == nil)
    }

    @Test("a newer request supersedes an untaken older one")
    func newestRequestWins() {
        let bridge = StateBridge(defaults: scratchDefaults())
        bridge.postRequest(.setMode(.anc))
        bridge.postRequest(.cycleMode)
        // Darwin notifications coalesce, so the agent may only wake once.
        // It must see the newest intent, not the stale one.
        #expect(bridge.takeRequest() == .cycleMode)
        #expect(bridge.takeRequest() == nil)
    }

    @Test("the peripheral identifier persists and can be cleared")
    func peripheralIdentifier() {
        let bridge = StateBridge(defaults: scratchDefaults())
        #expect(bridge.peripheralIdentifier == nil)
        let id = UUID()
        bridge.savePeripheralIdentifier(id)
        #expect(bridge.peripheralIdentifier == id)
        bridge.savePeripheralIdentifier(nil)   // the re-pair recovery path
        #expect(bridge.peripheralIdentifier == nil)
    }

    @Test("a corrupt stored identifier is treated as absent, not fatal")
    func corruptIdentifier() {
        let defaults = scratchDefaults()
        defaults.set("not-a-uuid", forKey: "peripheralIdentifier")
        let bridge = StateBridge(defaults: defaults)
        #expect(bridge.peripheralIdentifier == nil)
    }

    @Test("both request cases survive a JSON round trip")
    func requestCoding() throws {
        for request in [BridgeRequest.setMode(.normal), .setMode(.passthrough), .cycleMode] {
            let data = try JSONEncoder().encode(request)
            #expect(try JSONDecoder().decode(BridgeRequest.self, from: data) == request)
        }
    }

    @Test("postRequest returns a monotonically increasing seq")
    func seqIncreases() {
        let bridge = StateBridge(defaults: scratchDefaults())
        let first = bridge.postRequest(.cycleMode)
        let second = bridge.postRequest(.cycleMode)
        #expect(second == first + 1)
    }

    @Test("handledSeq advances only when a request is taken")
    func handledSeqTracking() {
        let bridge = StateBridge(defaults: scratchDefaults())
        let seq = bridge.postRequest(.setMode(.anc))
        #expect(bridge.handledSeq < seq)
        _ = bridge.takeRequest()
        #expect(bridge.handledSeq == seq)
    }

    @Test("waitForHandling returns false when nobody is listening")
    func waitForHandlingTimesOut() async {
        let bridge = StateBridge(defaults: scratchDefaults())
        let seq = bridge.postRequest(.cycleMode)
        // This is the "agent is not running" signal the intent uses to decide
        // whether to launch the app.
        #expect(await bridge.waitForHandling(of: seq, timeout: .milliseconds(200)) == false)
    }

    @Test("waitForHandling returns true once the agent takes the request")
    func waitForHandlingSucceeds() async {
        let bridge = StateBridge(defaults: scratchDefaults())
        let seq = bridge.postRequest(.cycleMode)
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            _ = bridge.takeRequest()
        }
        #expect(await bridge.waitForHandling(of: seq, timeout: .seconds(2)) == true)
    }
}
