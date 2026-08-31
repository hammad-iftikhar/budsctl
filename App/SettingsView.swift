import SwiftUI
import ServiceManagement
import BudsKit

struct SettingsView: View {
    let model: AppModel
    @State private var showAll = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var registrationError: String?
    // Guards a programmatic assignment to `launchAtLogin` (resyncing from
    // SMAppService, or correcting after a failed register/unregister) so it
    // does not re-trigger `onChange` and fire a second, unrequested
    // register()/unregister() call. Set immediately before every such
    // assignment; cleared by the observer itself, since onChange runs on the
    // next view update, not synchronously after the write.
    @State private var isSyncingToggle = false

    private var selected: UUID? { model.bridge.peripheralIdentifier }

    /// The connected list is shown in full — the service-UUID lookup already
    /// narrows it to a handful of LE audio peripherals, so filtering it further
    /// would only hide the device you are looking for.
    ///
    /// Scan results are different: an unfiltered scan returns every BLE beacon
    /// in the room, so those get the name filter and the escape hatch.
    private var visible: [DiscoveredDevice] {
        guard model.isScanning, !showAll else { return model.devices }
        return model.devices.filter { $0.isLikelyMatch || $0.id == selected }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EARBUDS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            if visible.isEmpty {
                Text(model.isScanning
                     ? "Looking…"
                     : "Nothing found. Take a bud out of the case, then scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(visible) { device in
                Button {
                    model.select(device)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: device.id == selected
                              ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(device.id == selected ? Color.accentColor : .secondary)
                        Text(device.name).lineLimit(1)
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            if model.isScanning {
                Toggle("Show every device found", isOn: $showAll)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            HStack(spacing: 8) {
                if model.isScanning {
                    Button("Stop") { model.stopScan() }
                    ProgressView().controlSize(.small)
                } else {
                    // Connected devices appear without any scan. Scanning is
                    // only for buds not currently linked to this Mac.
                    Button("Scan for More…") { model.startScan() }
                }
                Spacer()
                if selected != nil {
                    Button("Forget") { model.forget() }
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            Divider()

            Text("GENERAL")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.callout)
                .onChange(of: launchAtLogin) { _, wanted in
                    // A programmatic correction, not a user action: swallow it.
                    if isSyncingToggle { isSyncingToggle = false; return }
                    apply(wanted)
                }

            if let registrationError {
                Text(registrationError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: model.controller.state.connection) {
            model.refreshDevices()
            isSyncingToggle = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func apply(_ wanted: Bool) {
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            registrationError = nil
        } catch {
            registrationError = error.localizedDescription
            isSyncingToggle = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        // `requiresApproval` means macOS is waiting on the user in
        // System Settings > General > Login Items. Say so rather than
        // silently showing the toggle in the wrong position.
        if wanted, SMAppService.mainApp.status == .requiresApproval {
            registrationError = "Approve BudsCtl in System Settings ▸ General ▸ Login Items."
        }
    }
}
