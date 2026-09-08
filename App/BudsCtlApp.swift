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
    let controller: DeviceController

    private let backends: [any EarbudsBackend]
    /// Discovery results per backend, merged for the UI. Kept per backend so a
    /// quiet backend cannot blank out a noisy one's results.
    private var discovered: [String: [DiscoveredDevice]] = [:]

    var devices: [DiscoveredDevice] = []
    var isScanning = false

    /// The device the user selected, whichever backend owns it.
    var selectedRef: DeviceRef? { bridge.deviceRef }

    init() {
        let bridge = StateBridge.shared
        let backends = Backends.all()
        self.bridge = bridge
        self.backends = backends

        // Adopt the saved device's backend, or the first one as a placeholder
        // so the controller always has something to talk to.
        let saved = bridge.deviceRef
        let active = backends.first { type(of: $0).id == saved?.backend } ?? backends[0]

        self.controller = DeviceController(
            backend: active,
            bridge: bridge,
            onStateChanged: {
                // Keep Control Center's cached value honest. macOS hosts exactly
                // one control per extension, so there is only the cycle control
                // to reload — see Task 11.
                ControlCenter.shared.reloadControls(ofKind: ControlKind.cycle)
            }
        )

        for backend in backends {
            let backendID = type(of: backend).id
            // Only the adopted backend may move the connection state. A
            // backend nobody selected reporting `.notConfigured` would
            // otherwise overwrite the live one's `.ready`.
            backend.onConnectionChange = { [weak self] state in
                guard let self, type(of: self.activeBackend).id == backendID else { return }
                Task { await self.controller.connectionChanged(state) }
            }
            backend.onDiscoveryUpdate = { [weak self] devices in
                self?.discovered[backendID] = devices
                self?.mergeDiscovered()
            }
            backend.start()
        }

        if let saved {
            active.adopt(saved)
        } else {
            // Nothing saved: say so rather than leaving the panel blank.
            Task { await controller.connectionChanged(.notConfigured) }
        }

        controller.start()

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

    /// Vendor label for a backend id, looked up rather than hardcoded — this is
    /// what keeps "a new device family is one file plus one line in
    /// `Backends.all()`" true of the UI as well as the model.
    func vendorName(_ backendID: String) -> String {
        guard let backend = backends.first(where: { type(of: $0).id == backendID })
        else { return backendID }
        return type(of: backend).displayName
    }

    /// The backend the controller is currently driven by.
    private var activeBackend: any EarbudsBackend {
        backends.first { type(of: $0).id == (bridge.deviceRef?.backend ?? "") } ?? backends[0]
    }

    /// Tie-broken on the ref, not just the name: Swift's sort is not stable, so
    /// two identically-named devices — a plausible pair of the same model —
    /// would otherwise swap rows every time discovery updates.
    private func mergeDiscovered() {
        devices = discovered.values.flatMap { $0 }.sorted {
            ($0.name, $0.id.persistedForm) < ($1.name, $1.id.persistedForm)
        }
    }

    /// Name of the selected device, for the panel header.
    ///
    /// Read out of the merged discovery list rather than asked of a backend:
    /// `GaiaClient.deviceName` was one radio's property and there are two
    /// radios now.
    ///
    /// ponytail: nil until a discovery pass has seen the device, so the header
    /// falls back to a generic label for the first moment after launch. The
    /// upgrade path is storing the name next to the `DeviceRef` in
    /// `StateBridge`, which is a persisted-format change and not worth one
    /// label.
    var deviceName: String? {
        guard let selectedRef else { return nil }
        return devices.first { $0.id == selectedRef }?.name
    }

    func drainRequests() {
        while let request = bridge.takeRequest() {
            controller.handle(request)
        }
    }

    /// Cheap: a paired-device list and a retrieve, not a scan. Safe to call
    /// every time Settings opens.
    func refreshDevices() {
        // A scan's results must not be replaced by the narrower connected-device
        // list while the scan is still running: this overwrites `discovered`
        // wholesale, so mid-scan it would drop every device found by scanning
        // and leave the user watching a list that keeps emptying itself. Two
        // call sites reach here on every connection transition — Settings and
        // the panel — so this is not hypothetical.
        guard !isScanning else { return }
        for backend in backends {
            discovered[type(of: backend).id] = backend.connectedDevices()
        }
        mergeDiscovered()
    }

    func startScan() {
        isScanning = true
        for backend in backends { backend.startScan() }
    }

    func stopScan() {
        isScanning = false
        for backend in backends { backend.stopScan() }
    }

    func select(_ device: DiscoveredDevice) {
        isScanning = false
        for backend in backends { backend.stopScan() }

        guard let target = backends.first(where: { type(of: $0).id == device.id.backend })
        else { return }

        // Re-start the backend we are about to hand the controller. A previous
        // `select` or a `forget` may have called `disconnect()` on it, and for
        // `GaiaBackend` that tears down the frame pump feeding its event hub —
        // which nothing else rebuilds, so switching away from a family and back
        // would leave it connected but silent. Both `start()` implementations
        // are idempotent, so calling it every time is cheaper than tracking
        // which backends are currently down. This is also what keeps Task 6's
        // contract true: `controller.use(_:)` calls its own `start()`, never
        // the backend's, so the backend must already be started when it
        // arrives.
        target.start()

        // Computed BEFORE the save, and the order is load-bearing:
        // `activeBackend` derives from `bridge.deviceRef`, so saving first would
        // make this comparison always false and the controller would never be
        // switched to the new family.
        let switchingFamily = type(of: activeBackend).id != device.id.backend
        bridge.saveDeviceRef(device.id)

        // Release whatever held a link before, so a de-selected device's
        // notifications can no longer reach the controller. `DeviceController.use`
        // deliberately does *not* do this — the caller owns it, because only the
        // caller knows which other backends exist.
        //
        // **This loop is an invariant `SamsungBackend` depends on, not just
        // tidiness.** Its `openLink()` re-drives itself when it notices a
        // different device was adopted while it was suspended over an SDP
        // query. That re-drive is safe against the user switching to the *other
        // backend* only because `disconnect()` nils that backend's `adopted`,
        // which makes the re-drive condition false. Skip this loop and a
        // de-selected Samsung backend would keep trying to reconnect the wrong
        // earbuds underneath the one the user actually picked.
        //
        // Placed *after* the save and *before* `use`/`adopt`, and both halves
        // of that matter. After the save, because the `onConnectionChange`
        // guard tests `activeBackend` — a backend torn down before the save
        // still passes it, and anything it reported would land through an
        // unstructured `Task` after `use()`/`adopt()` had already run. Before
        // `use`/`adopt`, because the new backend must not be adopted while the
        // old one still holds its link. Latent today — neither `disconnect()`
        // reports a state — so this closes the hole rather than fixing a bug.
        for backend in backends where type(of: backend).id != device.id.backend {
            backend.disconnect()
        }

        if switchingFamily { controller.use(target) }
        // `adopt` reports `.connecting`, which is what repaints the UI after a
        // switch — `disconnect()` above reports nothing, by design.
        target.adopt(device.id)
    }

    func forget() {
        for backend in backends { backend.disconnect() }

        // Restores the invariant that `controller`'s backend is always the one
        // `activeBackend` names. Without it, forgetting a Samsung device leaves
        // the controller streaming `SamsungBackend.events()` while
        // `activeBackend` has already fallen back to `backends[0]` — so the next
        // selection of a GAIA device computes `switchingFamily == false`, skips
        // `use(_:)`, and leaves the controller wired to a dead backend behind a
        // green panel.
        //
        // ponytail: the sturdier shape is a stored `activeBackendID`, updated
        // wherever `use(_:)` is called and read by both `switchingFamily` and
        // the `onConnectionChange` guard, instead of re-deriving the active
        // backend from `bridge.deviceRef` on every access. That removes the
        // class of bug rather than this instance of it, but it is a wider
        // change than this restores.
        //
        // Started before it is handed over, so contract 1 holds literally and
        // not merely by coincidence: the disconnect loop above cancelled this
        // backend's frame pump, and `use(_:)` calls the *controller's*
        // `start()`, never the backend's. Nothing observes the difference today
        // — nothing is adopted after a forget — but an invariant that depends on
        // no one looking is one refactor from being false.
        backends[0].start()
        controller.use(backends[0])

        bridge.saveDeviceRef(nil)
        Task { await controller.connectionChanged(.notConfigured) }
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
