import Testing
import Foundation
@testable import BudsKit

@Suite("App Intents")
struct IntentsTests {

    private func scratchBridge() -> StateBridge {
        let suite = "budsctl.test.\(UUID().uuidString)"
        return StateBridge(defaults: UserDefaults(suiteName: suite)!)
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
        _ = try await intent.perform()
        #expect(bridge.takeRequest() == .setMode(.passthrough))
        #expect(bridge.takeRequest() == nil)
    }

    @Test("a cycle intent leaves a cycle request")
    func cycleIntentPostsRequest() async throws {
        let bridge = scratchBridge()
        var intent = CycleModeIntent()
        intent.injectedBridge = bridge
        _ = try await intent.perform()
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
