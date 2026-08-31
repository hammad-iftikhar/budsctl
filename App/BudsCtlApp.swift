import SwiftUI
import Observation
import BudsKit
import WidgetKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // ⌥⌘N. The user can rebind it in the panel; this is only the initial value.
    static let cycleMode = Self("cycleMode", default: .init(.n, modifiers: [.option, .command]))
}

@MainActor
@Observable
final class AppModel {
    let bridge: StateBridge
    let client: GaiaClient
    let controller: DeviceController

    var devices: [DiscoveredDevice] = []
    var isScanning = false

    init() {
        let bridge = StateBridge.shared
        let client = GaiaClient(bridge: bridge)
        self.bridge = bridge
        self.client = client
        self.controller = DeviceController(
            transport: client,
            bridge: bridge,
            onStateChanged: {
                // Keep Control Center's cached value honest. macOS hosts exactly
                // one control per extension, so there is only the cycle control
                // to reload — see Task 11.
                ControlCenter.shared.reloadControls(ofKind: ControlKind.cycle)
            }
        )

        client.onConnectionChange = { [weak self] state in
            guard let self else { return }
            Task { await self.controller.connectionChanged(state) }
        }
        client.onDiscoveryUpdate = { [weak self] devices in
            self?.devices = devices
        }

        controller.start()
        client.start()

        // Control Center and Shortcuts post requests here. Darwin
        // notifications coalesce, so always drain rather than assuming one
        // notification means one request.
        bridge.observeRequests { [weak self] in
            Task { @MainActor in self?.drainRequests() }
        }
        // A request may have been posted while the agent was still launching.
        drainRequests()

        // onKeyUp, not onKeyDown: a held key must not queue three mode changes.
        KeyboardShortcuts.onKeyUp(for: .cycleMode) { [weak self] in
            self?.controller.cycleMode()
        }
    }

    func drainRequests() {
        while let request = bridge.takeRequest() {
            controller.handle(request)
        }
    }

    /// Cheap: a retrieve, not a scan. Safe to call every time settings opens.
    func refreshDevices() {
        devices = client.connectedDevices()
    }

    func startScan() {
        isScanning = true
        client.startScan()
    }

    func stopScan() {
        isScanning = false
        client.stopScan()
    }

    func select(_ device: DiscoveredDevice) {
        isScanning = false
        client.select(device)
    }

    func forget() {
        client.forgetDevice()
    }
}

@main
struct BudsCtlApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            // Template rendering, so it adapts to light, dark and tinted bars.
            Image(systemName: model.controller.state.menuBarSymbol)
                .foregroundStyle(model.controller.state.connection.isReady ? .primary : .tertiary)
                .symbolEffect(.pulse, isActive: model.controller.state.isBusy)
        }
        .menuBarExtraStyle(.window)
    }
}
