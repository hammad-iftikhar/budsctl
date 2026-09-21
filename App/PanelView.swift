import SwiftUI
import BudsKit

struct PanelView: View {
    let model: AppModel
    @State private var showSettings = false

    private var state: DeviceState { model.controller.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            // The controls are always in the layout, even with nothing chosen
            // and nothing connected — the prompt covers them rather than
            // replacing them. Swapping a one-line prompt for this block
            // changed the panel's height by 59pt on every connect, and macOS
            // 26+ animates the MenuBarExtra resize, so waking an idle link by
            // changing mode stretched the panel open while it read the mode
            // back. Height now depends only on whether Settings is expanded.
            VStack(alignment: .leading, spacing: 12) {
                modePicker
                batteryRow
            }
            .opacity(state.connection == .notConfigured ? 0 : 1)
            .accessibilityHidden(state.connection == .notConfigured)
            .overlay(alignment: .topLeading) {
                if state.connection == .notConfigured {
                    Text("Choose your earbuds in Settings, below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        // 327, not 280, and the number is derived rather than taste: the
        // segmented mode picker is an AppKit control reporting a 298.5pt
        // intrinsic width ("Transparency" is the widest segment and all three
        // size to the widest). On every state update the control snaps to that
        // intrinsic width regardless of what SwiftUI laid out, so any panel
        // that gives it less made the whole row jump outside the panel and
        // back — 23pt each side at 280, still 14pt when sized automatically.
        // 327 = 298.5 + the 14pt padding on each side, so the width it is
        // given already equals the width it snaps to and nothing moves.
        // Shortening that label is what buys a narrower panel back.
        .frame(width: 327)
        .task(id: state.connection) {
            // Cheap, and it is what fills in the header's device name — the
            // name now comes from the discovery list, not from a radio.
            model.refreshDevices()
            // Battery is also refreshed on menu open, per the spec's policy.
            if state.connection.isReady { await model.controller.refreshBattery() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.deviceName ?? "Earbuds")
                .font(.headline)
            HStack(spacing: 5) {
                Circle()
                    .fill(state.connection.isReady ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(state.connection.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // `.failed(_)`'s label is a sentence, not a status word:
                    // the RFCOMM open-exhaustion message tells the user how to
                    // recover, and in a 280-wide panel it would otherwise be
                    // truncated to a single line ending in an ellipsis, which
                    // hides the instruction that is the whole point of it.
                    .fixedSize(horizontal: false, vertical: true)
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
            // Stays enabled while *busy* on purpose: a user changing their
            // mind mid-flight should win. Disabled when there is no link, and
            // while the mode is still being read — until that first read lands
            // the segment showing as selected is a guess, so letting it be
            // clicked would invite setting the mode you are already in.
            .disabled(!state.connection.isReady || state.isResolvingMode)

            // Always laid out, only faded. Inserting this row grew the picker
            // block from 24pt to 47pt, and macOS 26+ animates the resulting
            // MenuBarExtra window resize — so every mode change stretched the
            // panel open and snapped it shut again. Reserving the row's height
            // costs 23pt of blank space and makes the panel's height constant.
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text(state.isBusy ? "Applying…" : "Reading mode…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(state.isBusy || state.isResolvingMode ? 1 : 0)
            .accessibilityHidden(!(state.isBusy || state.isResolvingMode))
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

    /// e.g. "v1.0 (1)". Read from the bundle, never from a constant in code:
    /// a hardcoded string is one more thing to forget on a release, and it can
    /// disagree with what actually shipped. `project.yml` is the only place a
    /// version is written.
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup("Settings", isExpanded: $showSettings) {
                SettingsView(model: model)
                    .padding(.top, 6)
            }
            .font(.callout)

            HStack {
                Button("Quit BudsCtl") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                Spacer()
                Text(appVersion)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .font(.callout)
        }
        .onAppear {
            // With no earbuds chosen, settings is the only useful thing here.
            if state.connection == .notConfigured { showSettings = true }
        }
    }
}
