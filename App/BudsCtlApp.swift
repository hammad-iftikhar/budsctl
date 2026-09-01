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
    /// True while the drop-advertise-reconnect dance is in flight.
    var isReconnecting = false
    /// Why the last reconnect attempt got nowhere. Not written to
    /// `DeviceState`: `DeviceController` is its sole writer, and this is the
    /// app's problem rather than the device's.
    var reconnectError: String?

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

        // The earbuds stop advertising once they settle into an audio
        // connection, so an app started after that point can never connect on
        // its own. Give the ordinary path a chance first, then step in.
        Task { [weak self] in await self?.autoReconnectIfAppropriate() }

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

    // MARK: - Reconnecting to earbuds that have stopped advertising

    private static let autoReconnectKey = "autoReconnectOnLaunch"

    /// Off by default, and deliberately so: it costs the user a few seconds of
    /// silence, and there is no way to know whether they are mid-call when it
    /// fires — every CoreAudio running flag reads `true` for a connected
    /// Bluetooth device whether or not sound is playing.
    var autoReconnectOnLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoReconnectKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoReconnectKey) }
    }

    /// Drop the classic link so the earbuds advertise again, let the pending
    /// connect catch them, then put the audio back.
    func reconnect() async {
        guard !isReconnecting, let name = client.deviceName else { return }
        isReconnecting = true
        defer { isReconnecting = false }

        reconnectError = nil
        guard ClassicLink.isConnected(named: name) else {
            // Nothing to drop, so nothing would start advertising either.
            reconnectError = "\(name) is not connected to this Mac."
            return
        }
        guard ClassicLink.disconnect(named: name) else {
            // Most likely the sandbox refusing IOBluetooth. Say so rather than
            // leaving a button that appears to do nothing at all.
            reconnectError = "macOS would not let BudsCtl disconnect the earbuds."
            return
        }

        // No connect call here: GaiaClient's pending connect has been armed
        // since launch and completes on its own the moment they advertise.
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline, !controller.state.connection.isReady {
            try? await Task.sleep(for: .milliseconds(200))
        }

        // Always restore, even on timeout: leaving the user without an audio
        // device because we failed to connect would be a far worse outcome
        // than not connecting.
        ClassicLink.restoreAudio(named: name)
        if !controller.state.connection.isReady {
            reconnectError = "The earbuds did not come back. Put them in the case and take them out."
        }
    }

    /// Runs once at launch. Reconnects silently when it is free to do so, and
    /// otherwise leaves the panel's button to the user.
    private func autoReconnectIfAppropriate() async {
        // Long enough for an ordinary connect to have landed on its own.
        try? await Task.sleep(for: .seconds(6))
        guard !controller.state.connection.isReady, let name = client.deviceName else { return }

        // If the earbuds are not what the user is listening through, dropping
        // their link costs nothing audible — safe whatever the setting says.
        let inaudible = !ClassicLink.isCurrentAudioOutput(named: name)
        guard inaudible || autoReconnectOnLaunch else { return }
        await reconnect()
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
