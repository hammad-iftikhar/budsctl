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

    @Test("a request this build cannot decode is left unhandled, not silently eaten")
    func undecodableRequest() {
        let defaults = scratchDefaults()
        let bridge = StateBridge(defaults: defaults)
        // What version skew looks like: an agent older than the extension,
        // after a BridgeRequest case it does not know about was added.
        defaults.set(Data("{\"seq\":7,\"request\":{\"quantumMode\":{}}}".utf8), forKey: "request")
        #expect(bridge.takeRequest() == nil)
        // The important half. If handledSeq advanced here, waitForHandling
        // would report true and the intent would claim success for a request
        // nobody applied; leaving it alone makes the intent launch the agent.
        #expect(bridge.handledSeq == 0)
    }

    @Test("the seq travels inside the request blob, so one read sees both or neither")
    func requestAndSeqAreOneValue() {
        let defaults = scratchDefaults()
        let bridge = StateBridge(defaults: defaults)
        let seq = bridge.postRequest(.setMode(.anc))
        // A single key holds the payload; there is no separate seq key that
        // could be read stale beside a fresh payload.
        #expect(defaults.data(forKey: "request") != nil)
        #expect(defaults.object(forKey: "requestSeq") == nil)
        #expect(bridge.takeRequest() == .setMode(.anc))
        #expect(bridge.handledSeq == seq)
    }

    @Test("a request whose blob is lost still gets a seq the agent has not passed")
    func seqSurvivesALostPayload() {
        let defaults = scratchDefaults()
        let bridge = StateBridge(defaults: defaults)
        let first = bridge.postRequest(.cycleMode)
        #expect(bridge.takeRequest() == .cycleMode)
        // The seq no longer has its own key, so it lives or dies with the blob.
        defaults.removeObject(forKey: "request")
        let second = bridge.postRequest(.setMode(.anc))
        #expect(second > first)
        #expect(bridge.takeRequest() == .setMode(.anc))
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

    @Test("waitForSnapshot returns immediately when the current snapshot already matches")
    func waitForSnapshotAlreadyMatches() async {
        let bridge = StateBridge(defaults: scratchDefaults())
        bridge.publish(ModeSnapshot(mode: .anc, connected: true))
        let start = ContinuousClock.now
        let snapshot = await bridge.waitForSnapshot(timeout: .seconds(2)) {
            $0.connected && $0.mode == .anc
        }
        #expect(snapshot.mode == .anc)
        #expect(start.duration(to: .now) < .milliseconds(500))
    }

    @Test("waitForSnapshot catches a match published while it is polling")
    func waitForSnapshotCatchesLateMatch() async {
        let bridge = StateBridge(defaults: scratchDefaults())
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            bridge.publish(ModeSnapshot(mode: .passthrough, connected: true))
        }
        let start = ContinuousClock.now
        let snapshot = await bridge.waitForSnapshot(timeout: .seconds(2)) {
            $0.connected && $0.mode == .passthrough
        }
        #expect(snapshot.mode == .passthrough)
        // Caught well before the 2 s timeout, proving the loop polls rather
        // than only checking once at the deadline.
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test("waitForSnapshot gives up and returns the last snapshot when nothing ever matches")
    func waitForSnapshotTimesOut() async {
        let bridge = StateBridge(defaults: scratchDefaults())
        bridge.publish(ModeSnapshot(mode: .normal, connected: true))
        let snapshot = await bridge.waitForSnapshot(timeout: .milliseconds(300)) {
            $0.mode == .anc
        }
        // The mismatching snapshot is still returned honestly, not nil'd out.
        #expect(snapshot.mode == .normal)
    }
}
