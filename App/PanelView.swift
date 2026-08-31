import SwiftUI
import BudsKit

struct PanelView: View {
    let model: AppModel
    @State private var showSettings = false

    private var state: DeviceState { model.controller.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if state.connection == .notConfigured {
                Text("Choose your earbuds in Settings, below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                modePicker
                batteryRow
            }

            if state.connection == .bluetoothOff {
                Button("Open Bluetooth Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Bluetooth") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.callout)
            }

            if let error = state.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 280)
        .task(id: state.connection) {
            // Battery is also refreshed on menu open, per the spec's policy.
            if state.connection.isReady { await model.controller.refreshBattery() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.client.deviceName ?? "SoundPEATS Earbuds")
                .font(.headline)
            HStack(spacing: 5) {
                Circle()
                    .fill(state.connection.isReady ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(state.connection.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: Binding(
                get: { state.displayMode ?? .normal },
                set: { model.controller.setMode($0) }
            )) {
                ForEach(ANCMode.allCases, id: \.self) { mode in
                    Text(mode.shortLabel).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Stays enabled while busy on purpose: a user changing their mind
            // mid-flight should win. Disabled only when there is no link.
            .disabled(!state.connection.isReady)

            if state.isBusy {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("Applying…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var batteryRow: some View {
        HStack(spacing: 16) {
            batteryLabel("L", state.batteryLeft)
            batteryLabel("R", state.batteryRight)
            Spacer()
        }
        .font(.caption)
    }

    private func batteryLabel(_ side: String, _ percent: Int?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol(for: percent))
                .foregroundStyle(percent.map { $0 <= 20 } == true ? .orange : .secondary)
            Text(percent.map { "\(side) \($0)%" } ?? "\(side) —")
                .monospacedDigit()
        }
    }

    private func symbol(for percent: Int?) -> String {
        guard let percent else { return "battery.0percent" }
        return switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let firmware = state.firmware {
                Text(firmware)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            DisclosureGroup("Settings", isExpanded: $showSettings) {
                SettingsView(model: model)
                    .padding(.top, 6)
            }
            .font(.callout)

            Button("Quit BudsCtl") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.callout)
        }
        .onAppear {
            // With no earbuds chosen, settings is the only useful thing here.
            if state.connection == .notConfigured { showSettings = true }
        }
    }
}
