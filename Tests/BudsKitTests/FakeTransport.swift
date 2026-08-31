import Foundation
@testable import BudsKit

/// Reproduces the two behaviours that make this device awkward:
///
/// 1. `0x0311` (set mode) produces **no** GAIA reply at all.
/// 2. The device instead emits an unsolicited `0x0310` after ~1.4 s.
///
/// Tests pass a short `applyDelay` so the suite stays fast; one test uses a
/// realistic delay to prove the optimistic UI window behaves.
final class FakeTransport: GaiaTransport, @unchecked Sendable {

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<GaiaFrame>.Continuation] = [:]
    private var _writes: [(GaiaCommand, [UInt8])] = []
    private var currentMode: ANCMode
    private let applyDelay: Duration

    /// Make every write throw, to exercise the write-failure path.
    var failWrites = false
    /// Accept the set but never emit the confirming notification, to exercise
    /// the timeout-then-poll fallback.
    var swallowSetNotification = false
    /// What `getMode` reports, when it should disagree with what was set.
    var reportedModeOverride: ANCMode?

    var firmware = "AIR4PRO-BS588R2E_20241112_v0.2.1"
    var batteryLeft: UInt8 = 85
    var batteryRight: UInt8 = 90

    init(mode: ANCMode = .normal, applyDelay: Duration = .milliseconds(1400)) {
        self.currentMode = mode
        self.applyDelay = applyDelay
    }

    func recordedWrites() -> [(GaiaCommand, [UInt8])] {
        lock.withLock { _writes }
    }

    func frames() -> AsyncStream<GaiaFrame> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    /// Simulate the user tapping a bud or changing mode from their phone.
    func emitModeChange(_ mode: ANCMode) {
        lock.withLock { currentMode = mode }
        emit(GaiaFrame(command: .getMode, status: 0, payload: [mode.rawValue]))
    }

    private func emit(_ frame: GaiaFrame) {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets { continuation.yield(frame) }
    }

    func write(_ command: GaiaCommand, payload: [UInt8]) async throws {
        if failWrites { throw GaiaError.writeFailed("fake") }
        lock.withLock { _writes.append((command, payload)) }

        switch command {
        case .setMode:
            guard let target = payload.first.flatMap(ANCMode.init(rawValue:)) else { return }
            // No GAIA reply. The device answers late, unsolicited, or not at all.
            guard !swallowSetNotification else { return }
            Task { [applyDelay] in
                try? await Task.sleep(for: applyDelay)
                self.emitModeChange(target)
            }

        case .getMode:
            let reported = lock.withLock { reportedModeOverride ?? currentMode }
            emit(GaiaFrame(command: .getMode, status: 0, payload: [reported.rawValue]))

        case .getBatteryLeft:
            emit(GaiaFrame(command: .getBatteryLeft, status: 0, payload: [batteryLeft]))

        case .getBatteryRight:
            emit(GaiaFrame(command: .getBatteryRight, status: 0, payload: [batteryRight]))

        case .getFirmware:
            emit(GaiaFrame(command: .getFirmware, status: 0, payload: Array(firmware.utf8)))
        }
    }
}
