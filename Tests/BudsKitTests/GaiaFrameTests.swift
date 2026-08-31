import Testing
import Foundation
@testable import BudsKit

@Suite("GaiaFrame codec")
struct GaiaFrameTests {

    // Bytes below are verbatim from the spec's Appendix: a real PacketLogger
    // capture of the official SoundPEATS app talking to an Air4 Pro.

    @Test("encode set-mode frames exactly as captured")
    func encodeSetMode() {
        #expect(GaiaFrame.encode(.setMode, [0x00]) == Data([0x00, 0x0A, 0x03, 0x11, 0x00]))
        #expect(GaiaFrame.encode(.setMode, [0x01]) == Data([0x00, 0x0A, 0x03, 0x11, 0x01]))
        #expect(GaiaFrame.encode(.setMode, [0x02]) == Data([0x00, 0x0A, 0x03, 0x11, 0x02]))
    }

    @Test("encode getters with no payload")
    func encodeGetters() {
        #expect(GaiaFrame.encode(.getMode) == Data([0x00, 0x0A, 0x03, 0x10]))
        #expect(GaiaFrame.encode(.getBatteryLeft) == Data([0x00, 0x0A, 0x03, 0x06]))
        #expect(GaiaFrame.encode(.getBatteryRight) == Data([0x00, 0x0A, 0x03, 0x07]))
        #expect(GaiaFrame.encode(.getFirmware) == Data([0x00, 0x0A, 0x03, 0x09]))
    }

    @Test("decode a mode reply")
    func decodeMode() throws {
        let frame = try #require(GaiaFrame.decode(Data([0x00, 0x0A, 0x83, 0x10, 0x00, 0x01])))
        #expect(frame.command == .getMode)
        #expect(frame.status == 0x00)
        #expect(frame.payload == [0x01])
    }

    @Test("decode a battery reply, 0x55 is 85 percent")
    func decodeBattery() throws {
        let frame = try #require(GaiaFrame.decode(Data([0x00, 0x0A, 0x83, 0x06, 0x00, 0x55])))
        #expect(frame.command == .getBatteryLeft)
        #expect(frame.percent == 85)
    }

    @Test("decode the captured firmware string")
    func decodeFirmware() throws {
        let ascii = "AIR4PRO-BS588R2E_20241112_v0.2.1"
        var bytes: [UInt8] = [0x00, 0x0A, 0x83, 0x09, 0x00]
        bytes.append(contentsOf: Array(ascii.utf8))
        let frame = try #require(GaiaFrame.decode(Data(bytes)))
        #expect(frame.command == .getFirmware)
        #expect(frame.ascii == ascii)
    }

    @Test("the reply bit is stripped, so a request echo is not mistaken for a reply")
    func rejectNonReply() {
        // 0x0310 without the 0x8000 reply bit set. This is what we send, never
        // what we receive; accepting it would let a loopback look like a device.
        #expect(GaiaFrame.decode(Data([0x00, 0x0A, 0x03, 0x10, 0x00, 0x01])) == nil)
    }

    @Test("malformed frames decode to nil rather than trapping")
    func rejectMalformed() {
        #expect(GaiaFrame.decode(Data()) == nil)                                  // empty
        #expect(GaiaFrame.decode(Data([0x00, 0x0A, 0x83])) == nil)                 // no status byte
        #expect(GaiaFrame.decode(Data([0xFF, 0xFF, 0x83, 0x10, 0x00, 0x01])) == nil) // wrong vendor
        #expect(GaiaFrame.decode(Data([0x00, 0x0A, 0x83, 0xFF, 0x00])) == nil)     // unknown command
    }

    @Test("percent is nil when the payload cannot be a percentage")
    func percentGuards() throws {
        let noPayload = try #require(GaiaFrame.decode(Data([0x00, 0x0A, 0x83, 0x06, 0x00])))
        #expect(noPayload.percent == nil)
        let overflow = try #require(GaiaFrame.decode(Data([0x00, 0x0A, 0x83, 0x06, 0x00, 0xFF])))
        #expect(overflow.percent == nil)   // 255% is not a battery level
    }
}
