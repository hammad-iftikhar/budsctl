import Foundation

public enum GaiaError: Error, Equatable {
    case notConnected
    case timedOut(GaiaCommand)
    case writeFailed(String)
}

/// Everything `DeviceController` knows about the radio.
///
/// `frames()` returns a *fresh* stream per caller, so concurrent waiters do not
/// steal each other's frames. Buffering is unbounded-but-newest so a slow
/// consumer cannot stall the BLE callback queue.
public protocol GaiaTransport: Sendable {
    func frames() -> AsyncStream<GaiaFrame>
    func write(_ command: GaiaCommand, payload: [UInt8]) async throws
}

public extension GaiaTransport {

    func write(_ command: GaiaCommand) async throws {
        try await write(command, payload: [])
    }

    /// Write a getter and wait for its matching reply.
    ///
    /// The stream is opened *before* the write. Opening it after would drop a
    /// reply that arrives faster than we can subscribe — the same class of bug
    /// as writing before the notify subscription lands.
    func request(
        _ command: GaiaCommand,
        timeout: Duration = .seconds(3)
    ) async throws -> GaiaFrame {
        let stream = frames()
        try await write(command)
        // withTimeout returns T? and T is itself GaiaFrame?, hence two levels.
        let raced: GaiaFrame?? = await withTimeout(timeout) { () -> GaiaFrame? in
            for await frame in stream where frame.command == command { return frame }
            return nil
        }
        guard let inner = raced, let frame = inner else {
            throw GaiaError.timedOut(command)
        }
        return frame
    }

    /// Wait for an unsolicited frame, e.g. the `0x0310` that follows a set.
    func awaitFrame(
        _ command: GaiaCommand,
        matching predicate: @escaping @Sendable (GaiaFrame) -> Bool = { _ in true },
        timeout: Duration
    ) async -> GaiaFrame? {
        let stream = frames()
        let raced: GaiaFrame?? = await withTimeout(timeout) { () -> GaiaFrame? in
            for await frame in stream where frame.command == command && predicate(frame) {
                return frame
            }
            return nil
        }
        return raced ?? nil
    }
}
