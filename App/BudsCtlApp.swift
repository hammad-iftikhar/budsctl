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

        // The link usually survives sleep, but the state may be stale — the
        // user could have changed mode from their phone while the Mac slept.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.controller.refreshOnWake() }
        }

        // Nothing else tells Shortcuts or Control Center that the agent is
        // gone. Without this, they keep reporting a live mode and a stale
        // battery for a process that no longer exists. Posted locally by our
        // own NSApplication, so it fires for an LSUIElement agent exactly as
        // it would for a regular app — unlike NSWorkspace's termination
        // notifications, which only observe *other* processes.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // Deliberately synchronous, not `Task { @MainActor in ... }` like
            // the wake observer above: the process can exit immediately after
            // every `willTerminateNotification` observer returns, so this
            // publish must happen before this closure returns, not on some
            // later run-loop turn that may never come. `queue: nil` is what
            // makes that true: NotificationCenter runs a nil-queue observer
            // synchronously, in-line, on the posting thread, instead of
            // enqueuing it — a non-nil queue (even `.main`) delivers
            // asynchronously and could lose the race with process exit.
            // `willTerminateNotification` is posted on the main thread, so
            // this closure runs there too; `assumeIsolated` tells the
            // compiler what is already true at runtime instead of hopping
            // through an async Task that could get skipped entirely.
            MainActor.assumeIsolated {
                guard let self else { return }
                // Mode is kept — it is still the last thing the device
                // reported. Battery is dropped, matching what
                // `connectionChanged` already does for a live disconnect.
                self.bridge.publish(ModeSnapshot(mode: self.controller.state.mode, connected: false))
            }
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
                .symbolEffect(
                    .pulse,
                    isActive: model.controller.state.isBusy
                        || model.controller.state.isResolvingMode
                )
        }
        .menuBarExtraStyle(.window)
    }
}
