import Testing
import Foundation
@testable import BudsKit

@Suite("SppFrame codec")
struct SppFrameCodecTests {

    /// Verbatim from GalaxyBudsClient's `Crc16.cs` worked example: the payload
    /// bytes and, as the last two, the checksum the reference documents for
    /// them. Pins our implementation against a third-party value rather than
    /// against itself.
    @Test("CRC16 matches the reference implementation's documented vector")
    func crcReferenceVector() {
        let data: [UInt8] = [0x61, 0x02, 0x00, 0x4B, 0x5F, 0x01, 0x00, 0x00,
                             0x00, 0x01, 0x05, 0x00, 0x02, 0x00, 0x13]
        // The reference writes the checksum little-endian, as bytes 0F F3.
        #expect(SppFrame.crc16(data) == 0xF30F)
    }

    @Test("CRC16 of nothing is zero, the documented initial value")
    func crcEmpty() {
        #expect(SppFrame.crc16([]) == 0)
    }

    @Test("encodes a set-mode frame exactly")
    func encodeNoiseControls() {
        // size = 1 (id) + 1 (payload) + 2 (crc) = 4
        let data = SppFrame.encode(.noiseControls, [0x01])
        let bytes = [UInt8](data)
        #expect(bytes[0] == 0xFD)                     // preamble
        #expect(bytes[1] == 0x04 && bytes[2] == 0x00) // header, little-endian
        #expect(bytes[3] == 120)                      // NOISE_CONTROLS
        #expect(bytes[4] == 0x01)                     // ANC
        let crc = SppFrame.crc16([120, 0x01])
        #expect(bytes[5] == UInt8(crc & 0xFF))
        #expect(bytes[6] == UInt8(crc >> 8))
        #expect(bytes[7] == 0xDD)                     // postamble
        #expect(bytes.count == 8)
    }

    @Test("encodes a payload-free frame")
    func encodeNoPayload() {
        let bytes = [UInt8](SppFrame.encode(.managerInfo))
        #expect(bytes[1] == 0x03 && bytes[2] == 0x00) // size = id + crc
        #expect(bytes.count == 7)
    }

    @Test("every message we send round-trips")
    func roundTrip() throws {
        let cases: [(SppMessageID, [UInt8])] = [
            (.noiseControls, [0x00]),
            (.noiseControls, [0x02]),
            (.managerInfo, [0x01, 0x02, 0x22]),
        ]
        for (id, payload) in cases {
            let frame = try #require(SppFrame.decode([UInt8](SppFrame.encode(id, payload))))
            #expect(frame.id == id)
            #expect(frame.payload == payload)
            #expect(frame.isFragment == false)
        }
    }

    @Test("decodes a frame whose id this app does not handle, keeping the raw id")
    func decodeUnknownID() throws {
        // id 0x2A is not in SppMessageID. The codec must still parse it, so the
        // reassembler can consume its bytes and the CLI probe can print it.
        var bytes: [UInt8] = [0xFD, 0x03, 0x00, 0x2A]
        let crc = SppFrame.crc16([0x2A])
        bytes += [UInt8(crc & 0xFF), UInt8(crc >> 8), 0xDD]
        let frame = try #require(SppFrame.decode(bytes))
        #expect(frame.rawID == 0x2A)
        #expect(frame.id == nil)
        #expect(frame.payload.isEmpty)
    }

    @Test("rejects a frame whose CRC does not match")
    func rejectsBadCRC() {
        var bytes = [UInt8](SppFrame.encode(.noiseControls, [0x01]))
        bytes[4] ^= 0x01     // flip a payload bit, leave the CRC alone
        #expect(SppFrame.decode(bytes) == nil)
    }

    @Test("rejects a wrong preamble or postamble")
    func rejectsBadDelimiters() {
        var badPreamble = [UInt8](SppFrame.encode(.noiseControls, [0x01]))
        badPreamble[0] = 0xFE
        #expect(SppFrame.decode(badPreamble) == nil)

        var badPostamble = [UInt8](SppFrame.encode(.noiseControls, [0x01]))
        badPostamble[badPostamble.count - 1] = 0xEE
        #expect(SppFrame.decode(badPostamble) == nil)
    }

    @Test("rejects a frame too short to hold an id and a checksum")
    func rejectsRunt() {
        #expect(SppFrame.decode([0xFD, 0x00, 0x00, 0xDD]) == nil)
        #expect(SppFrame.decode([0xFD]) == nil)
        #expect(SppFrame.decode([]) == nil)
    }

    @Test("reads the fragment bit without treating it as size")
    func decodesFragmentFlag() throws {
        var bytes = [UInt8](SppFrame.encode(.noiseControls, [0x01]))
        bytes[2] |= 0x20     // bit 13 of the little-endian header
        let frame = try #require(SppFrame.decode(bytes))
        #expect(frame.isFragment)
        #expect(frame.id == .noiseControls)
    }

    // GalaxyBudsClient sets bit 12 for Response on encode and reads it as
    // Request on decode — an asymmetry in the reference. We neither set nor
    // read it, so a frame with it set must decode identically.
    @Test("ignores the type bit entirely")
    func ignoresTypeBit() throws {
        var bytes = [UInt8](SppFrame.encode(.noiseControls, [0x02]))
        bytes[2] |= 0x10     // bit 12
        let frame = try #require(SppFrame.decode(bytes))
        #expect(frame.id == .noiseControls)
        #expect(frame.payload == [0x02])
        #expect(frame.isFragment == false)
    }
}

@Suite("SppReassembler")
struct SppReassemblerTests {

    private func frame(_ id: SppMessageID, _ payload: [UInt8] = []) -> [UInt8] {
        [UInt8](SppFrame.encode(id, payload))
    }

    @Test("a whole frame in one chunk yields one frame")
    func singleChunk() {
        var reassembler = SppReassembler()
        let frames = reassembler.append(Data(frame(.noiseControls, [0x01])))
        #expect(frames.count == 1)
        #expect(frames.first?.id == .noiseControls)
    }

    @Test("a frame split across three chunks yields one frame, once")
    func splitFrame() {
        var reassembler = SppReassembler()
        let bytes = frame(.noiseControlsUpdate, [0x02])
        #expect(reassembler.append(Data(bytes[0..<2])).isEmpty)
        #expect(reassembler.append(Data(bytes[2..<5])).isEmpty)
        let frames = reassembler.append(Data(bytes[5...]))
        #expect(frames.count == 1)
        #expect(frames.first?.payload == [0x02])
    }

    @Test("a byte-at-a-time delivery still yields exactly one frame")
    func byteAtATime() {
        var reassembler = SppReassembler()
        let bytes = frame(.noiseControlsUpdate, [0x01])
        var total: [SppFrame] = []
        for byte in bytes { total += reassembler.append(Data([byte])) }
        #expect(total.count == 1)
        #expect(total.first?.payload == [0x01])
    }

    @Test("three frames coalesced into one chunk yield three frames, in order")
    func coalescedFrames() {
        var reassembler = SppReassembler()
        let bytes = frame(.noiseControlsUpdate, [0x00])
            + frame(.noiseControlsUpdate, [0x01])
            + frame(.noiseControlsUpdate, [0x02])
        let frames = reassembler.append(Data(bytes))
        #expect(frames.count == 3)
        #expect(frames.map(\.payload) == [[0x00], [0x01], [0x02]])
    }

    @Test("leading garbage is skipped and the frame behind it is found")
    func resyncsAfterGarbage() {
        var reassembler = SppReassembler()
        let frames = reassembler.append(Data([0x00, 0x11, 0x22] + frame(.noiseControls, [0x01])))
        #expect(frames.count == 1)
        #expect(frames.first?.id == .noiseControls)
    }

    /// The important one: a corrupt frame must not desynchronise the stream and
    /// swallow everything after it.
    @Test("a bad-CRC frame is dropped and the next good frame is still decoded")
    func resyncsAfterCorruptFrame() {
        var reassembler = SppReassembler()
        var corrupt = frame(.noiseControlsUpdate, [0x01])
        corrupt[4] ^= 0xFF
        let frames = reassembler.append(Data(corrupt + frame(.noiseControlsUpdate, [0x02])))
        #expect(frames.count == 1)
        #expect(frames.first?.payload == [0x02])
    }

    @Test("a frame claiming an impossible size is dropped, not waited on forever")
    func dropsOversizedClaim() {
        var reassembler = SppReassembler()
        // size field claims 0x3FF bytes that will never arrive, then a real frame.
        let liar: [UInt8] = [0xFD, 0xFF, 0x03, 0x77]
        _ = reassembler.append(Data(liar))
        let frames = reassembler.append(Data(frame(.noiseControlsUpdate, [0x01])))
        #expect(frames.count == 1)
        #expect(frames.first?.payload == [0x01])
    }

    @Test("fragmented frames are consumed but never surfaced")
    func dropsFragments() {
        var reassembler = SppReassembler()
        var fragment = frame(.noiseControlsUpdate, [0x01])
        fragment[2] |= 0x20
        let frames = reassembler.append(Data(fragment + frame(.noiseControlsUpdate, [0x02])))
        #expect(frames.count == 1, "the fragment is dropped, the frame after it is not")
        #expect(frames.first?.payload == [0x02])
    }

    @Test("the buffer is bounded when nothing valid ever arrives")
    func boundsTheBuffer() {
        var reassembler = SppReassembler()
        for _ in 0..<16 {
            _ = reassembler.append(Data(repeating: 0xFD, count: 1024))
        }
        #expect(reassembler.bufferedByteCount <= SppReassembler.bufferLimit)
    }

    @Test("a frame still parses after the buffer was cleared for overflow")
    func recoversAfterOverflow() {
        var reassembler = SppReassembler()
        for _ in 0..<16 { _ = reassembler.append(Data(repeating: 0xFD, count: 1024)) }
        let frames = reassembler.append(Data(frame(.noiseControls, [0x00])))
        #expect(frames.count == 1)
    }
}
