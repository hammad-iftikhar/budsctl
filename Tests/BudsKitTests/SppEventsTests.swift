import Testing
import Foundation
@testable import BudsKit

@Suite("SppFrame device events")
struct SppEventsTests {

    private func frame(_ id: SppMessageID, _ payload: [UInt8]) -> SppFrame {
        SppFrame(rawID: id.rawValue, payload: payload)
    }

    /// A plausible EXTENDED_STATUS_UPDATED for Buds FE: revision, ear type,
    /// battery L/R, coupled, main connection, placement, case battery, then the
    /// fields up to the noise control mode at index 12.
    private func extendedStatus(
        batteryLeft: UInt8 = 82,
        batteryRight: UInt8 = 79,
        mode: UInt8 = 1
    ) -> SppFrame {
        frame(.extendedStatusUpdated, [
            0x05,           //  0 revision
            0x00,           //  1 ear type
            batteryLeft,    //  2
            batteryRight,   //  3
            0x01,           //  4 coupled
            0x01,           //  5 main connection
            0x11,           //  6 placement L/R nibbles
            0x64,           //  7 case battery — read and discarded
            0x00,           //  8 adjust sound sync
            0x02,           //  9 equaliser mode
            0x80,           // 10 touch lock bitfield
            0x30,           // 11 touch options L/R nibbles
            mode,           // 12 noise control mode
            0x00,           // 13 voice wake-up
        ])
    }

    // MARK: - Mode

    @Test("a noise control update carries the mode")
    func noiseControlsUpdate() {
        #expect(frame(.noiseControlsUpdate, [0x00]).events == [.mode(.normal)])
        #expect(frame(.noiseControlsUpdate, [0x01]).events == [.mode(.anc)])
        #expect(frame(.noiseControlsUpdate, [0x02]).events == [.mode(.passthrough)])
    }

    /// Adaptive is out of scope. Dropping it leaves the last known mode
    /// standing, which beats displaying a mode the app cannot represent.
    @Test("adaptive mode is dropped, not guessed at")
    func dropsAdaptive() {
        #expect(frame(.noiseControlsUpdate, [0x03]).events.isEmpty)
        #expect(frame(.noiseControlsUpdate, [0xFF]).events.isEmpty)
    }

    @Test("an empty noise control update yields nothing")
    func emptyNoiseControlsUpdate() {
        #expect(frame(.noiseControlsUpdate, []).events.isEmpty)
    }

    @Test("an ack for a mode set carries the mode that was applied")
    func acknowledgesNoiseControls() {
        let ack = frame(.acknowledgement, [SppMessageID.noiseControls.rawValue, 0x02])
        #expect(ack.events == [.mode(.passthrough)])
    }

    @Test("an ack for some other message is ignored")
    func ignoresUnrelatedAck() {
        let ack = frame(.acknowledgement, [SppMessageID.managerInfo.rawValue, 0x02])
        #expect(ack.events.isEmpty)
    }

    @Test("a truncated ack is ignored rather than read past its end")
    func ignoresTruncatedAck() {
        #expect(frame(.acknowledgement, [SppMessageID.noiseControls.rawValue]).events.isEmpty)
        #expect(frame(.acknowledgement, []).events.isEmpty)
    }

    // MARK: - Battery

    @Test("a status update carries both battery levels")
    func statusUpdate() {
        let status = frame(.statusUpdated, [0x05, 82, 79, 0x01, 0x01, 0x11, 0x64, 0x00])
        #expect(status.events == [.batteryLeft(82), .batteryRight(79)])
    }

    @Test("an out-of-range battery reads as unknown, not as a bogus percentage")
    func implausibleBattery() {
        let status = frame(.statusUpdated, [0x05, 0xFF, 79, 0x01, 0x01, 0x11, 0x64, 0x00])
        #expect(status.events == [.batteryLeft(nil), .batteryRight(79)])
    }

    @Test("a truncated status update yields nothing")
    func truncatedStatusUpdate() {
        #expect(frame(.statusUpdated, [0x05, 82]).events.isEmpty)
    }

    // MARK: - Extended status

    @Test("extended status carries both batteries and the mode")
    func extendedStatusFull() {
        let events = extendedStatus(batteryLeft: 82, batteryRight: 79, mode: 1).events
        #expect(events.contains(.batteryLeft(82)))
        #expect(events.contains(.batteryRight(79)))
        #expect(events.contains(.mode(.anc)))
        #expect(events.count == 3, "case battery is deliberately discarded")
    }

    /// Spec §2.5. Byte 12 is the one offset not confirmed against a capture, so
    /// an out-of-range value must leave the mode unknown — the UI then honestly
    /// reads "Reading mode…" instead of presenting a misparse as a selection.
    @Test("an out-of-range mode byte yields battery but no mode")
    func rejectsImplausibleMode() {
        let events = extendedStatus(mode: 0x30).events
        #expect(events.contains(.batteryLeft(82)))
        #expect(events.contains(.mode(.anc)) == false)
        #expect(events.contains { if case .mode = $0 { true } else { false } } == false)
    }

    /// The whole-message plausibility gate: if the batteries are impossible,
    /// the offsets are probably wrong, so byte 12 is not to be trusted either.
    @Test("an implausible extended status is rejected outright")
    func rejectsImplausibleExtendedStatus() {
        #expect(extendedStatus(batteryLeft: 200).events.isEmpty)
        #expect(extendedStatus(batteryRight: 101).events.isEmpty)
    }

    @Test("an extended status too short to reach byte 12 is rejected")
    func rejectsShortExtendedStatus() {
        #expect(frame(.extendedStatusUpdated, [0x05, 0x00, 82, 79]).events.isEmpty)
    }

    // MARK: - Everything else

    @Test("messages this app does not handle yield nothing")
    func ignoresOtherMessages() {
        #expect(SppFrame(rawID: 0x2A, payload: [0x01, 0x02]).events.isEmpty)
        #expect(frame(.managerInfo, [0x01]).events.isEmpty)
        #expect(frame(.noiseControls, [0x01]).events.isEmpty)
    }
}
