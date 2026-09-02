import Testing
import Foundation
@testable import BudsKit

@Suite("App Intents")
struct IntentsTests {

    private func scratchBridge() -> StateBridge {
        let suite = "budsctl.test.\(UUID().uuidString)"
        return StateBridge(defaults: UserDefaults(suiteName: suite)!)
    }

    /// A reference box for handing a value out of a detached `Task` closure.
    /// `perform()` now waits on the bridge for up to 2 seconds before falling
    /// back to launching the app, so these tests simulate an already-running
    /// agent draining the request while `perform()` waits.
    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    @Test("every ANCMode round trips through the intent enum")
    func enumRoundTrip() {
        for mode in ANCMode.allCases {
            #expect(ANCModeAppEnum(mode).asANCMode == mode)
        }
    }

    @Test("the intent enum's raw values are stable identifiers, not display text")
    func enumRawValues() {
        // These strings end up in users' saved Shortcuts. Changing them breaks
        // every shortcut anyone has built.
        #expect(ANCModeAppEnum(.normal).rawValue == "off")
        #expect(ANCModeAppEnum(.anc).rawValue == "noiseCancellation")
        #expect(ANCModeAppEnum(.passthrough).rawValue == "transparency")
    }

    @Test("a set intent leaves exactly one takeable request")
    func setIntentPostsRequest() async throws {
        let bridge = scratchBridge()
        var intent = SetModeIntent()
        intent.mode = .transparency
        intent.injectedBridge = bridge
        let taken = Box<BridgeRequest?>(nil)
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            taken.value = bridge.takeRequest()
            // Simulate the agent actually applying the change, so perform()'s
            // post-handling snapshot wait resolves quickly instead of running
            // out its full timeout — this test is about the request, not the
            // honest-reporting wait, which has its own tests below.
            bridge.publish(ModeSnapshot(mode: .passthrough, connected: true))
        }
        _ = try await intent.perform()
        #expect(taken.value == .setMode(.passthrough))
        #expect(bridge.takeRequest() == nil)
    }

    /// `perform()`'s declared return type is `some IntentResult &
    /// ProvidesDialog`, but `IntentResult` itself declares no `dialog`
    /// requirement — only the concrete (framework-private)
    /// `IntentResultContainer` actually stores one. There is no supported API
    /// to read it back through the opaque return type, so this reaches past
    /// it with `String(describing:)`, which walks the concrete struct's
    /// fields via reflection regardless of what the static type exposes.
    /// `IntentDialog(_:)` stores its argument as a `LocalizedStringResource`
    /// whose `key` is that exact string, and `key: "..."` shows up verbatim
    /// in the description — fragile in the sense that it leans on that
    /// implementation detail, but it is the only way to assert dialog text
    /// from a unit test at all.
    private func dialogText(_ result: some Any) -> String {
        String(describing: result)
    }

    @Test("a set intent reports success only once the snapshot confirms the change")
    func setIntentReportsSuccessAfterConfirmation() async throws {
        let bridge = scratchBridge()
        var intent = SetModeIntent()
        intent.mode = .noiseCancellation
        intent.injectedBridge = bridge
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            _ = bridge.takeRequest()
            // The device takes ~1.4 s in real life; a short delay here is
            // enough to prove the intent actually polls rather than checking
            // only once.
            try? await Task.sleep(for: .milliseconds(100))
            bridge.publish(ModeSnapshot(mode: .anc, connected: true))
        }
        let start = ContinuousClock.now
        let result = try await intent.perform()
        // String interpolation inside `IntentDialog(_:)` becomes a format
        // string plus a separate argument, not one flat literal — so this
        // checks for the template and the interpolated mode name separately.
        let text = dialogText(result)
        #expect(text.contains(#"key: "Set to %@""#))
        #expect(text.contains(#"value("Noise Cancellation")"#))
        // Resolved once confirmed, not after riding out the full budget.
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test("a set intent reports failure honestly when the buds never confirm")
    func setIntentReportsFailureWhenUnconfirmed() async throws {
        let bridge = scratchBridge()
        var intent = SetModeIntent()
        intent.mode = .transparency
        intent.injectedBridge = bridge
        intent.confirmationTimeout = .milliseconds(300)
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            _ = bridge.takeRequest()
            // Taken, but never applied — e.g. the buds are in the case. No
            // matching snapshot is ever published.
        }
        let result = try await intent.perform()
        #expect(dialogText(result).contains(#"key: "BudsCtl could not reach the earbuds.""#))
        #expect(!dialogText(result).contains("Set to"))
    }

    @Test("a set intent reports failure honestly when the buds land on a different mode")
    func setIntentReportsFailureOnWrongMode() async throws {
        let bridge = scratchBridge()
        var intent = SetModeIntent()
        intent.mode = .noiseCancellation
        intent.injectedBridge = bridge
        intent.confirmationTimeout = .milliseconds(300)
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            _ = bridge.takeRequest()
            // Connected, but settled on a mode other than the one requested —
            // e.g. a competing request from the phone won the race.
            bridge.publish(ModeSnapshot(mode: .passthrough, connected: true))
        }
        let result = try await intent.perform()
        #expect(dialogText(result).contains(#"key: "BudsCtl could not reach the earbuds.""#))
    }

    @Test("a cycle intent leaves a cycle request")
    func cycleIntentPostsRequest() async throws {
        let bridge = scratchBridge()
        bridge.publish(ModeSnapshot(mode: .normal, connected: true))
        var intent = CycleNoiseModeIntent()
        intent.injectedBridge = bridge

        // No agent simulated, and none needed: perform() must not wait for one.
        // Anything it waits for shows up in Spotlight as a running-progress UI.
        let start = ContinuousClock.now
        let result = try await intent.perform()
        #expect(start.duration(to: .now) < .milliseconds(50))

        #expect(bridge.takeRequest() == .cycleMode)
        // Reports the target it asked for, by the same `next` rule the agent uses.
        #expect(dialogText(result).contains("Noise Cancellation"))
    }

    @Test("a cycle intent reports honestly when the earbuds are not connected")
    func cycleIntentReportsDisconnected() async throws {
        let bridge = scratchBridge()
        bridge.publish(ModeSnapshot(mode: .anc, connected: false))
        var intent = CycleNoiseModeIntent()
        intent.injectedBridge = bridge
        let result = try await intent.perform()
        #expect(dialogText(result).contains("BudsCtl is not connected to your earbuds."))
        // Still posted, so it applies once the agent has a link.
        #expect(bridge.takeRequest() == .cycleMode)
    }

    @Test("a get intent reads the published snapshot and posts nothing")
    func getIntentReadsSnapshot() async throws {
        let bridge = scratchBridge()
        bridge.publish(ModeSnapshot(mode: .anc, connected: true, batteryLeft: 85, batteryRight: 90))
        var intent = GetModeIntent()
        intent.injectedBridge = bridge
        _ = try await intent.perform()
        // A getter must never provoke a device write.
        #expect(bridge.takeRequest() == nil)
    }
}
