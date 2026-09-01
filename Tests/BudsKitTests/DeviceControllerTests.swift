import Testing
import Foundation
@testable import BudsKit

@MainActor
@Suite("DeviceController set-mode flow")
struct DeviceControllerTests {

    private func makeController(
        mode: ANCMode = .normal,
        applyDelay: Duration = .milliseconds(30)
    ) -> (DeviceController, FakeTransport, StateBridge) {
        let transport = FakeTransport(mode: mode, applyDelay: applyDelay)
        let suite = "budsctl.test.\(UUID().uuidString)"
        let bridge = StateBridge(defaults: UserDefaults(suiteName: suite)!)
        let controller = DeviceController(transport: transport, bridge: bridge)
        controller.setTimeout = .milliseconds(300)
        controller.state.connection = .ready
        controller.state.mode = mode
        controller.start()
        return (controller, transport, bridge)
    }

    /// Counts `onStateChanged` calls. MainActor-isolated, so it is Sendable
    /// enough for the controller's `@MainActor @Sendable` callback.
    @MainActor final class PublishCount { var count = 0 }

    /// Poll a condition instead of sleeping a fixed amount. Keeps the suite fast
    /// and non-flaky without pulling in an expectation framework.
    private func until(
        _ label: String,
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for: \(label)")
    }

    @Test("the pending mode is visible immediately, before the device confirms")
    func optimisticUpdateIsSynchronous() async throws {
        // A realistic 1.4 s delay: the whole point is that the UI must not wait.
        let (controller, _, _) = makeController(applyDelay: .milliseconds(1400))
        controller.setMode(.anc)
        // No await between setMode and this assertion.
        #expect(controller.state.pendingMode == .anc)
        #expect(controller.state.displayMode == .anc)
        #expect(controller.state.isBusy == true)
        #expect(controller.state.mode == .normal)   // not yet confirmed
        controller.stop()
    }

    @Test("a set is confirmed by the delayed unsolicited notification")
    func confirmOnNotification() async throws {
        let (controller, transport, bridge) = makeController()
        controller.setMode(.anc)
        try await until("mode confirmed") { controller.state.mode == .anc }
        #expect(controller.state.pendingMode == nil)
        #expect(controller.state.isBusy == false)
        #expect(controller.state.lastError == nil)
        #expect(bridge.readSnapshot().mode == .anc)
        #expect(transport.recordedWrites().contains { $0.0 == .setMode && $0.1 == [0x01] })
        controller.stop()
    }

    @Test("no notification falls back to one getter read")
    func fallbackPoll() async throws {
        let (controller, transport, _) = makeController()
        transport.swallowSetNotification = true
        // The device applied the change but never announced it. `swallowSetNotification`
        // alone leaves the fake's internal mode untouched, so say what getMode reports.
        transport.reportedModeOverride = .passthrough
        controller.setMode(.passthrough)
        try await until("fallback poll issued") {
            transport.recordedWrites().filter { $0.0 == .getMode }.count == 1
        }
        try await until("state settled") { controller.state.pendingMode == nil }
        // The fake still holds the mode it was set to, so the reconcile agrees.
        #expect(controller.state.mode == .passthrough)
        #expect(controller.state.lastError == nil)
        controller.stop()
    }

    @Test("a device that ignores the set is reported honestly, not optimistically")
    func deviceRefusedTheChange() async throws {
        let (controller, transport, _) = makeController(mode: .normal)
        transport.swallowSetNotification = true
        transport.reportedModeOverride = .normal   // device stayed put
        controller.setMode(.anc)
        try await until("error surfaced") { controller.state.lastError != nil }
        #expect(controller.state.mode == .normal)      // truth, not the target
        #expect(controller.state.pendingMode == nil)
        controller.stop()
    }

    @Test("a write failure surfaces an error and clears the optimistic state")
    func writeFailure() async throws {
        let (controller, transport, _) = makeController()
        transport.failWrites = true
        controller.setMode(.anc)
        try await until("error surfaced") { controller.state.lastError != nil }
        #expect(controller.state.pendingMode == nil)
        #expect(controller.state.mode == .normal)
        controller.stop()
    }

    @Test("rapid clicks coalesce to the newest target")
    func coalesceRapidClicks() async throws {
        let (controller, transport, _) = makeController(applyDelay: .milliseconds(60))
        controller.setMode(.anc)
        controller.setMode(.passthrough)
        controller.setMode(.normal)
        #expect(controller.state.pendingMode == .normal)

        try await until("settled on the newest target") {
            controller.state.mode == .normal && controller.state.pendingMode == nil
        }
        // Every click is written — the device is the thing that must end up
        // right, and dropping writes would strand it on an intermediate mode.
        // What must not happen is an *older* target winning the final state.
        #expect(controller.state.mode == .normal)
        #expect(transport.recordedWrites().last { $0.0 == .setMode }?.1 == [0x00])
        controller.stop()
    }

    // Regression guard: a prior implementation silently replaced the
    // single-slot cancel design with a serial await-chain, so each new
    // `setMode` awaited the *entire* previous attempt — including its
    // confirmation wait, up to `setTimeout` — before its own write even
    // reached the transport. `setTimeout` here is made huge and the fake is
    // told to swallow the confirmation, guaranteeing the first attempt is
    // still waiting when the second click happens; under the serial-chain
    // design the second write would not land until the (10 s) timeout
    // elapsed, so a generous 500 ms budget still leaves an enormous margin
    // against flakiness while unambiguously distinguishing the two designs.
    @Test("a newer click's write is not held behind an older click's confirmation wait")
    func newerClickDoesNotWaitOutOlderConfirmation() async throws {
        let (controller, transport, _) = makeController()
        transport.swallowSetNotification = true
        controller.setTimeout = .seconds(10)

        let start = ContinuousClock.now
        controller.setMode(.anc)
        controller.setMode(.passthrough)

        try await until("both writes reached the transport", timeout: .milliseconds(500)) {
            transport.recordedWrites().filter { $0.0 == .setMode }.count == 2
        }
        #expect(ContinuousClock.now - start < .milliseconds(500))
        controller.stop()
    }

    @Test("a mode change made on the buds or the phone updates state unprompted")
    func externalModeChange() async throws {
        let (controller, transport, bridge) = makeController(mode: .normal)
        transport.emitModeChange(.passthrough)
        try await until("external change applied") { controller.state.mode == .passthrough }
        #expect(bridge.readSnapshot().mode == .passthrough)
        // Nothing was written: this path must never provoke a set.
        #expect(transport.recordedWrites().isEmpty)
        controller.stop()
    }

    @Test("cycleMode advances from the confirmed mode and wraps")
    func cycle() async throws {
        let (controller, _, _) = makeController(mode: .passthrough)
        controller.cycleMode()
        try await until("wrapped to normal") { controller.state.mode == .normal }
        controller.cycleMode()
        try await until("advanced to anc") { controller.state.mode == .anc }
        controller.stop()
    }

    @Test("cycleMode with no known mode assumes normal and sets ANC")
    func cycleFromUnknown() async throws {
        let (controller, _, _) = makeController()
        controller.state.mode = nil
        controller.cycleMode()
        #expect(controller.state.pendingMode == .anc)
        controller.stop()
    }

    @Test("a bridge request is executed like a local action")
    func handleBridgeRequests() async throws {
        let (controller, _, _) = makeController(mode: .normal)
        controller.handle(.setMode(.passthrough))
        try await until("set from bridge") { controller.state.mode == .passthrough }
        controller.handle(.cycleMode)
        try await until("cycled from bridge") { controller.state.mode == .normal }
        controller.stop()
    }

    @Test("connect refresh reads firmware, mode and both batteries once each")
    func refreshAfterConnect() async throws {
        let (controller, transport, _) = makeController(mode: .anc)
        controller.state.mode = nil
        await controller.refreshAfterConnect()
        try await until("all fields populated") {
            controller.state.mode == .anc
                && controller.state.batteryLeft == 85
                && controller.state.batteryRight == 90
                && controller.state.firmware != nil
        }
        #expect(controller.state.connection == .ready)
        let commands = transport.recordedWrites().map(\.0)
        #expect(commands.filter { $0 == .getFirmware }.count == 1)
        #expect(commands.filter { $0 == .getMode }.count == 1)
        #expect(commands.contains(.getBatteryLeft))
        #expect(commands.contains(.getBatteryRight))
        #expect(commands.contains(.setMode) == false)   // connecting must not write modes
        controller.stop()
    }

    @Test("unexpected firmware is warned about, not refused")
    func firmwareWarning() async throws {
        let (controller, transport, _) = makeController()
        transport.firmware = "AIR4PRO-BS588R2E_20991231_v9.9.9"
        await controller.refreshAfterConnect()
        try await until("warning surfaced") { controller.state.lastError != nil }
        #expect(controller.state.firmware == "AIR4PRO-BS588R2E_20991231_v9.9.9")
        #expect(controller.state.connection == .ready)   // still usable
        controller.stop()
    }

    @Test("known-good firmware raises no warning")
    func firmwareOK() async throws {
        let (controller, _, _) = makeController()
        await controller.refreshAfterConnect()
        try await until("firmware read") { controller.state.firmware != nil }
        #expect(controller.state.lastError == nil)
        controller.stop()
    }

    @Test("a connect refresh cannot resurrect a connection that has since dropped")
    func refreshDoesNotResurrectReady() async throws {
        let (controller, _, bridge) = makeController(mode: .anc)
        // Stands in for the real interleaving: connectionChanged(.ready) starts
        // this refresh, the buds go back in the case, connectionChanged(.waiting)
        // runs to completion, and only then does the refresh resume.
        controller.state.connection = .waiting
        await controller.refreshAfterConnect()
        #expect(controller.state.connection == .waiting)
        #expect(bridge.readSnapshot().connected == false)
        controller.stop()
    }

    @Test("the firmware reply publishes, so its warning reaches the UI and the bridge")
    func firmwarePublishes() async throws {
        let transport = FakeTransport(mode: .anc, applyDelay: .milliseconds(30))
        let suite = "budsctl.test.\(UUID().uuidString)"
        let bridge = StateBridge(defaults: UserDefaults(suiteName: suite)!)
        let published = PublishCount()
        let controller = DeviceController(
            transport: transport,
            bridge: bridge,
            onStateChanged: { published.count += 1 }
        )
        controller.state.connection = .ready
        controller.start()
        // Only the firmware getter is issued, so any publish observed here is
        // the one the `.getFirmware` case makes.
        try? await transport.write(.getFirmware)
        try await until("firmware applied") { controller.state.firmware != nil }
        #expect(published.count >= 1)
        controller.stop()
    }

    @Test("losing the connection clears live values but keeps the last known mode")
    func connectionLost() async throws {
        let (controller, _, bridge) = makeController(mode: .anc)
        controller.state.batteryLeft = 85
        await controller.connectionChanged(.waiting)
        #expect(controller.state.connection == .waiting)
        #expect(controller.state.pendingMode == nil)
        #expect(controller.state.batteryLeft == nil)   // stale battery is a lie
        #expect(controller.state.mode == .anc)         // last known mode is useful
        #expect(bridge.readSnapshot().connected == false)
        controller.stop()
    }

    @Test("a write refused while connected reads as another device holding the buds")
    func inUseByAnotherDevice() async throws {
        let (controller, transport, _) = makeController()
        controller.state.connection = .ready
        transport.failWrites = true
        controller.setMode(.anc)
        try await until("error surfaced") { controller.state.lastError != nil }
        // The buds are reachable but the write was refused — almost always
        // because they are actively in use by a phone.
        #expect(controller.state.lastError == "In use by another device")
        controller.stop()
    }

    @Test("a write that fails with no link reads as disconnected")
    func writeWithNoLink() async throws {
        let (controller, transport, _) = makeController()
        controller.state.connection = .waiting
        transport.failWrites = true
        controller.setMode(.anc)
        try await until("error surfaced") { controller.state.lastError != nil }
        #expect(controller.state.lastError == "Earbuds not connected")
        controller.stop()
    }

    @Test("wake refresh re-reads mode and battery, and does nothing when not ready")
    func wakeRefresh() async throws {
        let (controller, transport, _) = makeController(mode: .anc)
        await controller.refreshOnWake()
        let commands = transport.recordedWrites().map(\.0)
        #expect(commands.contains(.getMode))
        #expect(commands.contains(.getBatteryLeft))
        #expect(commands.contains(.setMode) == false)

        let (idle, idleTransport, _) = makeController()
        idle.state.connection = .waiting
        await idle.refreshOnWake()
        #expect(idleTransport.recordedWrites().isEmpty)
        controller.stop(); idle.stop()
    }
    // MARK: - The post-connect settle re-read

    @Test("a stale mode read at connect is corrected by the settle re-read")
    func settleCorrectsStaleModeRead() async throws {
        // The device answers Off while it is still waking, then tells the
        // truth. It never notifies — exactly what the hardware was measured
        // doing, and the reason one read on connect is not enough.
        let (controller, transport, _) = makeController(mode: .normal)
        controller.settleReads = [.milliseconds(20)]
        controller.state.mode = nil

        await controller.connectionChanged(.ready)
        try await until("the bad first read landed") { controller.state.mode == .normal }

        transport.reportedModeOverride = .anc
        try await until("settle corrected it") { controller.state.mode == .anc }
        controller.stop()
    }

    @Test("a set outranks the settle re-read, so a stale read cannot overwrite it")
    func settleDoesNotClobberAUserSet() async throws {
        let (controller, transport, _) = makeController(mode: .normal)
        // Long enough that the re-read would land well after the set if it
        // were still armed.
        controller.settleReads = [.milliseconds(50)]
        await controller.connectionChanged(.ready)

        // The device is still stale and would report Off if asked again.
        transport.reportedModeOverride = .normal
        controller.setMode(.passthrough)
        try await until("the set was confirmed") { controller.state.mode == .passthrough }

        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.state.mode == .passthrough)
        controller.stop()
    }

    @Test("the settle re-read stops when the earbuds go away")
    func settleStopsOnDisconnect() async throws {
        let (controller, transport, _) = makeController(mode: .normal)
        controller.settleReads = [.milliseconds(50)]
        await controller.connectionChanged(.ready)
        let afterConnect = transport.recordedWrites().filter { $0.0 == .getMode }.count

        await controller.connectionChanged(.waiting)
        try await Task.sleep(for: .milliseconds(150))
        #expect(transport.recordedWrites().filter { $0.0 == .getMode }.count == afterConnect)
        controller.stop()
    }

    @Test("the mode reads as unresolved until the first settle read lands")
    func resolvingClearsOnFirstSettleRead() async throws {
        let (controller, _, _) = makeController(mode: .normal)
        controller.settleReads = [.milliseconds(30), .seconds(45)]
        controller.state.mode = nil

        await controller.connectionChanged(.ready)
        // The connect read has landed, but it is the untrustworthy one.
        #expect(controller.state.isResolvingMode)

        try await until("first settle read landed") { !controller.state.isResolvingMode }
        // Cleared by the first read, not by the whole 45 s schedule finishing.
        #expect(controller.state.mode == .normal)
        controller.stop()
    }

    @Test("a set clears the loader rather than making the user wait it out")
    func settingAModeClearsResolving() async throws {
        let (controller, _, _) = makeController(mode: .normal)
        controller.settleReads = [.seconds(45)]
        await controller.connectionChanged(.ready)
        #expect(controller.state.isResolvingMode)

        controller.setMode(.anc)
        #expect(controller.state.isResolvingMode == false)
        controller.stop()
    }

    @Test("losing the earbuds clears the loader")
    func disconnectClearsResolving() async throws {
        let (controller, _, _) = makeController(mode: .normal)
        controller.settleReads = [.seconds(45)]
        await controller.connectionChanged(.ready)
        #expect(controller.state.isResolvingMode)

        await controller.connectionChanged(.waiting)
        #expect(controller.state.isResolvingMode == false)
        controller.stop()
    }

}
