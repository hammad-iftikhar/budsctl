import Foundation

/// GAIA V2 command IDs, all confirmed against a live Air4 Pro capture.
///
/// Only the 0x03xx group is listed, and deliberately so: 0x01xx and 0x02xx
/// contain device reset and power off. This app has no reason to name them.
public enum GaiaCommand: UInt16, Sendable, CaseIterable {
    case getBatteryLeft = 0x0306
    case getBatteryRight = 0x0307
    case getFirmware = 0x0309
    case getMode = 0x0310
    case setMode = 0x0311
}

/// A decoded GAIA reply or notification.
public struct GaiaFrame: Equatable, Sendable {
    public let command: GaiaCommand
    /// Advisory only. This firmware returns 0x01 for merely unsupported
    /// commands, so never gate behaviour on it — confirm state by reading.
    public let status: UInt8
    public let payload: [UInt8]

    public init(command: GaiaCommand, status: UInt8, payload: [UInt8]) {
        self.command = command
        self.status = status
        self.payload = payload
    }

    /// First payload byte read as a battery percentage.
    public var percent: Int? {
        guard let first = payload.first, first <= 100 else { return nil }
        return Int(first)
    }

    /// Payload read as an ASCII string, e.g. the firmware version.
    public var ascii: String? {
        guard !payload.isEmpty else { return nil }
        return String(decoding: payload, as: UTF8.self)
    }

    private static let vendor: [UInt8] = [0x00, 0x0A]
    private static let replyBit: UInt16 = 0x8000

    /// `<vendor:2 = 00 0A> <command:2> <payload...>`
    public static func encode(_ command: GaiaCommand, _ payload: [UInt8] = []) -> Data {
        var bytes = vendor
        bytes.append(UInt8(command.rawValue >> 8))
        bytes.append(UInt8(command.rawValue & 0xFF))
        bytes.append(contentsOf: payload)
        return Data(bytes)
    }

    /// `<vendor:2 = 00 0A> <command|0x8000:2> <status:1> <payload...>`
    ///
    /// Returns nil for anything that is not a well-formed reply from this
    /// vendor. A nil here means "ignore this notification", not "crash".
    public static func decode(_ data: Data) -> GaiaFrame? {
        let bytes = [UInt8](data)
        guard bytes.count >= 5 else { return nil }
        guard bytes[0] == vendor[0], bytes[1] == vendor[1] else { return nil }

        let raw = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        guard raw & replyBit != 0 else { return nil }
        guard let command = GaiaCommand(rawValue: raw & ~replyBit) else { return nil }

        return GaiaFrame(command: command, status: bytes[4], payload: Array(bytes[5...]))
    }
}
