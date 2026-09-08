import Foundation

/// Samsung SPP message IDs, decimal to match GalaxyBudsClient's naming.
///
/// Only the six this app needs. The buds push plenty of others; those decode
/// structurally (see `SppFrame.rawID`) and are ignored, rather than being
/// enumerated here for no reason.
public enum SppMessageID: UInt8, Sendable, CaseIterable {
    /// Reply to a set. Payload: acked message id, then the value applied.
    case acknowledgement = 66
    /// Pushed on battery or wear change.
    case statusUpdated = 96
    /// Pushed when the SPP channel opens. The only source of the mode at
    /// connect time.
    case extendedStatusUpdated = 97
    /// Pushed on every mode change, from any source.
    case noiseControlsUpdate = 119
    /// Sent to change the mode. Payload: the mode byte.
    case noiseControls = 120
    /// Sent on connect to announce ourselves.
    case managerInfo = 136
}

/// One decoded Samsung SPP message.
public struct SppFrame: Equatable, Sendable {

    /// The id byte as it arrived, known or not.
    public let rawID: UInt8
    public let payload: [UInt8]
    /// Bit 13 of the header. Only firmware images and core dumps are
    /// fragmented, so callers drop these.
    public let isFragment: Bool

    /// nil for a message this app does not handle.
    public var id: SppMessageID? { SppMessageID(rawValue: rawID) }

    public init(rawID: UInt8, payload: [UInt8], isFragment: Bool = false) {
        self.rawID = rawID
        self.payload = payload
        self.isFragment = isFragment
    }

    // MARK: - Framing constants

    static let preamble: UInt8 = 0xFD
    static let postamble: UInt8 = 0xDD
    /// `size` counts the id byte plus the payload plus the two CRC bytes.
    static let sizeOverhead = 3
    /// preamble + header(2) + id + crc(2) + postamble.
    static let minimumSize = 7
    /// Bits 0-9 of the header.
    static let sizeMask: UInt16 = 0x03FF
    /// Bit 13.
    static let fragmentBit: UInt16 = 0x2000

    /// Total wire length of the frame at the front of `bytes`.
    ///
    /// Only valid once `decode` has accepted that frame — it re-reads the
    /// header rather than re-validating it, so the reassembler can consume
    /// exactly the right number of bytes without parsing twice.
    static func frameLength(_ bytes: [UInt8]) -> Int {
        4 + Int((UInt16(bytes[1]) | UInt16(bytes[2]) << 8) & sizeMask)
    }

    // MARK: - Checksum

    /// CRC16-CCITT/XMODEM: polynomial 0x1021, initial value 0x0000, MSB-first,
    /// no reflection, no final XOR. Computed over `id ‖ payload`.
    ///
    /// ponytail: bitwise, not the reference implementation's 256-entry table.
    /// Six lines beats a table for messages that are never more than a few
    /// dozen bytes; swap in a table if a profile ever says this matters.
    public static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    // MARK: - Encode

    /// `FD | size_lo size_hi | id | payload… | crc_lo crc_hi | DD`
    ///
    /// Bit 12 (type) is left clear: everything this app sends is a request.
    public static func encode(_ id: SppMessageID, _ payload: [UInt8] = []) -> Data {
        let size = UInt16(sizeOverhead + payload.count)
        let crc = crc16([id.rawValue] + payload)
        var bytes: [UInt8] = [preamble, UInt8(size & 0xFF), UInt8(size >> 8), id.rawValue]
        bytes += payload
        bytes += [UInt8(crc & 0xFF), UInt8(crc >> 8), postamble]
        return Data(bytes)
    }

    // MARK: - Decode

    /// Decodes exactly one frame from the front of `bytes`.
    ///
    /// Returns nil for anything malformed — wrong delimiters, a size that does
    /// not match the buffer, or a failed checksum. A nil means "not a frame",
    /// never "crash": this is a reverse-engineered protocol on a channel the
    /// buds share with their own chatter.
    public static func decode(_ bytes: [UInt8]) -> SppFrame? {
        guard bytes.count >= minimumSize else { return nil }
        guard bytes[0] == preamble else { return nil }

        let header = UInt16(bytes[1]) | UInt16(bytes[2]) << 8
        let size = Int(header & sizeMask)
        guard size >= sizeOverhead else { return nil }

        let total = 4 + size          // preamble + header(2) + size + postamble
        guard bytes.count >= total, bytes[total - 1] == postamble else { return nil }

        let rawID = bytes[3]
        let payloadEnd = total - 3    // before crc(2) + postamble
        let payload = Array(bytes[4..<payloadEnd])

        // Little-endian, matching what `encode` writes.
        let received = UInt16(bytes[payloadEnd]) | UInt16(bytes[payloadEnd + 1]) << 8
        guard crc16([rawID] + payload) == received else { return nil }

        return SppFrame(
            rawID: rawID,
            payload: payload,
            isFragment: header & fragmentBit != 0
        )
    }
}

/// Turns RFCOMM's byte stream into frames.
///
/// Needed because `rfcommChannelData` delivers arbitrary chunks — a frame can
/// arrive split across three callbacks, or three frames can arrive in one.
/// GATT notifications on the BLE side are discrete, so `GaiaFrame` needs
/// nothing like this.
public struct SppReassembler: Sendable {

    /// ponytail: a flat array with `removeFirst`, not a ring buffer. Frames are
    /// under a few dozen bytes and arrive a handful at a time; reach for a ring
    /// buffer only if a profile ever shows this copying.
    private var buffer: [UInt8] = []

    /// A control channel this far behind is not going to recover by buffering
    /// more, and an unbounded buffer on a byte stream is how a hung peer
    /// becomes a memory leak.
    public static let bufferLimit = 4096

    public init() {}

    /// For tests and diagnostics.
    public var bufferedByteCount: Int { buffer.count }

    /// Appends a chunk and returns every complete, valid, non-fragment frame it
    /// completed. Incomplete tails stay buffered for the next call.
    public mutating func append(_ chunk: Data) -> [SppFrame] {
        buffer.append(contentsOf: chunk)
        var frames: [SppFrame] = []

        parse: while true {
            // Discard anything before the first preamble.
            guard let start = buffer.firstIndex(of: SppFrame.preamble) else {
                buffer.removeAll()
                break parse
            }
            if start > 0 { buffer.removeFirst(start) }

            guard buffer.count >= SppFrame.minimumSize else { break parse }

            if let frame = SppFrame.decode(buffer) {
                buffer.removeFirst(SppFrame.frameLength(buffer))
                // Fragments are consumed so the stream stays aligned, but never
                // surfaced: they only ever carry firmware images and core dumps.
                if !frame.isFragment { frames.append(frame) }
                continue parse
            }

            // The front will not decode. Two possibilities, and they look
            // identical from here: a real frame that has not finished
            // arriving, or garbage whose size field is lying to us.
            //
            // Tell them apart by proof, not by a heuristic on the claimed
            // size. Resync only if a *valid* frame can be found at a later
            // preamble; otherwise keep waiting for more bytes.
            //
            // A size cap was tried first and rejected: adjacent garbage
            // trivially produces a claim just under any fixed bound (a pair of
            // stray 0xFD bytes claims 253, sliding under a 256 cap), so the
            // cap only moves the stall rather than removing it.
            //
            // ponytail: O(n²) over adversarial garbage, bounded by
            // `bufferLimit` below — 4 KB on a channel that carries a few dozen
            // bytes a minute. Index-based decoding would remove the slice copy
            // if a profile ever shows it.
            var probe = 1
            var resyncTo: Int?
            while probe < buffer.count {
                guard let next = buffer[probe...].firstIndex(of: SppFrame.preamble) else { break }
                if SppFrame.decode(Array(buffer[next...])) != nil {
                    resyncTo = next
                    break
                }
                probe = next + 1
            }
            guard let resyncTo else { break parse }
            buffer.removeFirst(resyncTo)
        }

        // Checked after parsing, never before: clearing first would throw away
        // bytes that were about to complete a frame.
        if buffer.count > Self.bufferLimit { buffer.removeAll() }
        return frames
    }
}
