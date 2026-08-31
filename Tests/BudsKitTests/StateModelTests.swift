import Testing
import Foundation
@testable import BudsKit

@Suite("State model")
struct StateModelTests {

    @Test("cycling walks normal to ANC to passthrough and wraps")
    func cycleOrder() {
        #expect(ANCMode.normal.next == .anc)
        #expect(ANCMode.anc.next == .passthrough)
        #expect(ANCMode.passthrough.next == .normal)
    }

    @Test("raw values match the captured protocol bytes")
    func rawValues() {
        #expect(ANCMode.normal.rawValue == 0x00)
        #expect(ANCMode.anc.rawValue == 0x01)
        #expect(ANCMode.passthrough.rawValue == 0x02)
    }

    @Test("a mode reply frame yields a mode")
    func frameMode() throws {
        let frame = try #require(GaiaFrame.decode(Data([0x00, 0x0A, 0x83, 0x10, 0x00, 0x02])))
        #expect(frame.mode == .passthrough)
    }

    @Test("a battery frame is not read as a mode")
    func batteryIsNotAMode() throws {
        let frame = try #require(GaiaFrame.decode(Data([0x00, 0x0A, 0x83, 0x06, 0x00, 0x01])))
        #expect(frame.mode == nil)
    }

    @Test("an out-of-range mode byte yields nil rather than a wrong mode")
    func unknownModeByte() throws {
        let frame = try #require(GaiaFrame.decode(Data([0x00, 0x0A, 0x83, 0x10, 0x00, 0x07])))
        #expect(frame.mode == nil)
    }

    @MainActor
    @Test("the pending mode wins the display while a set is in flight")
    func displayPrecedence() {
        let state = DeviceState()
        state.mode = .normal
        #expect(state.displayMode == .normal)
        #expect(state.isBusy == false)

        state.pendingMode = .anc
        #expect(state.displayMode == .anc)
        #expect(state.isBusy == true)

        state.pendingMode = nil
        state.mode = .anc
        #expect(state.displayMode == .anc)
        #expect(state.isBusy == false)
    }

    @MainActor
    @Test("the snapshot reflects the confirmed mode, never the optimistic one")
    func snapshotUsesConfirmedMode() {
        let state = DeviceState()
        state.connection = .ready
        state.mode = .normal
        state.pendingMode = .anc
        state.batteryLeft = 85
        state.batteryRight = 90

        // The widget must not be told a mode the device has not confirmed —
        // Control Center has no way to show "in progress".
        #expect(state.snapshot.mode == .normal)
        #expect(state.snapshot.connected == true)
        #expect(state.snapshot.batteryLeft == 85)
        #expect(state.snapshot.batteryRight == 90)
    }

    @MainActor
    @Test("a snapshot from a non-ready connection is not connected")
    func snapshotWhenWaiting() {
        let state = DeviceState()
        state.connection = .waiting
        state.mode = .anc
        #expect(state.snapshot.connected == false)
    }

    @Test("snapshots survive a JSON round trip, including the nil mode case")
    func snapshotCoding() throws {
        for snapshot in [
            ModeSnapshot(mode: .anc, connected: true, batteryLeft: 85, batteryRight: 90),
            ModeSnapshot(mode: nil, connected: false),
        ] {
            let data = try JSONEncoder().encode(snapshot)
            #expect(try JSONDecoder().decode(ModeSnapshot.self, from: data) == snapshot)
        }
    }
}
