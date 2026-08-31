import Foundation
import AppKit
import BudsKit

// The M1 spike. Deliberately not a real CLI: no argument parser dependency for
// five subcommands, and no App Group — it stores the peripheral identifier in
// this tool's own defaults domain.
//
// ponytail: shares no state with the app on purpose. If you ever want
// `budsctl-cli set anc` to drive the running agent instead of opening its own
// connection, post a BridgeRequest rather than growing this file.

@MainActor
final class Runner {
    let bridge = StateBridge(defaults: .standard)
    lazy var client = GaiaClient(bridge: bridge)
    private var readyContinuation: CheckedContinuation<Void, Error>?

    func waitForReady(timeout: Duration = .seconds(20)) async throws {
        client.onConnectionChange = { [weak self] state in
            print("[connection] \(state.label)")
            guard let self else { return }
            switch state {
            case .ready:
                self.readyContinuation?.resume()
                self.readyContinuation = nil
            case .notConfigured:
                self.readyContinuation?.resume(
                    throwing: CLIError.message("No device saved. Run `budsctl-cli discover` first.")
                )
                self.readyContinuation = nil
            case .failed(let reason):
                self.readyContinuation?.resume(throwing: CLIError.message(reason))
                self.readyContinuation = nil
            case .bluetoothOff:
                self.readyContinuation?.resume(throwing: CLIError.message("Bluetooth is off."))
                self.readyContinuation = nil
            case .waiting, .connecting:
                break   // pending connect: this is the case-lid dance we are testing away
            }
        }
        client.start()

        let result = await withTimeout(timeout) { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            do {
                try await withCheckedThrowingContinuation { continuation in
                    self.readyContinuation = continuation
                }
                return true
            } catch {
                print("error: \(error)")
                return false
            }
        }
        guard result == true else {
            throw CLIError.message("Never became ready. Are the buds out of the case and in range?")
        }
    }
}

enum CLIError: Error { case message(String) }

func usage() -> Never {
    print("""
    usage: budsctl-cli <command>

      discover           scan for earbuds and save the chosen one
      status             connect and print mode, battery, firmware
      set <mode>         normal | anc | passthrough
      watch              print every frame the device sends, until Ctrl-C
      symbols            check that the SF Symbols this app uses exist
    """)
    exit(2)
}

@main
struct CLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { usage() }

        do {
            switch command {
            case "discover": try await discover()
            case "status": try await status()
            case "set":
                guard arguments.count == 2 else { usage() }
                try await set(arguments[1])
            case "watch": try await watch()
            case "symbols": symbols()
            default: usage()
            }
        } catch CLIError.message(let text) {
            print("error: \(text)")
            exit(1)
        } catch {
            print("error: \(error)")
            exit(1)
        }
        exit(0)
    }

    @MainActor
    static func discover() async throws {
        let runner = Runner()
        var seen: [DiscoveredDevice] = []
        runner.client.onDiscoveryUpdate = { devices in
            seen = devices
            for (index, device) in devices.enumerated() {
                print("\(index). \(device.name)  \(device.id)\(device.isLikelyMatch ? "  <- likely" : "")")
            }
            print("---")
        }
        runner.client.start()
        for device in runner.client.connectedDevices() {
            print("(already connected) \(device.name)  \(device.id)")
        }
        runner.client.startScan()
        print("scanning for 8 seconds…")
        try await Task.sleep(for: .seconds(8))
        runner.client.stopScan()

        guard !seen.isEmpty else { throw CLIError.message("Nothing found.") }
        print("enter the number of your earbuds:", terminator: " ")
        guard let line = readLine(), let index = Int(line), seen.indices.contains(index) else {
            throw CLIError.message("Not a valid choice.")
        }
        runner.client.select(seen[index])
        print("saved \(seen[index].name) as \(seen[index].id)")
    }

    @MainActor
    static func status() async throws {
        let runner = Runner()
        try await runner.waitForReady()
        let firmware = try await runner.client.request(.getFirmware)
        let mode = try await runner.client.request(.getMode)
        let left = try await runner.client.request(.getBatteryLeft)
        let right = try await runner.client.request(.getBatteryRight)
        print("device:    \(runner.client.deviceName ?? "unknown")")
        print("firmware:  \(firmware.ascii ?? "?")")
        print("mode:      \(mode.mode?.label ?? "?")")
        print("battery:   L \(left.percent.map(String.init) ?? "?")%  R \(right.percent.map(String.init) ?? "?")%")
    }

    @MainActor
    static func set(_ name: String) async throws {
        let target: ANCMode
        switch name.lowercased() {
        case "normal", "off": target = .normal
        case "anc": target = .anc
        case "passthrough", "transparency": target = .passthrough
        default: throw CLIError.message("Mode must be normal, anc, or passthrough.")
        }

        let runner = Runner()
        try await runner.waitForReady()

        // Subscribe before writing — the confirmation is unsolicited.
        let stream = runner.client.frames()
        let started = ContinuousClock.now
        try await runner.client.write(.setMode, payload: [target.rawValue])
        print("wrote \(GaiaFrame.encode(.setMode, [target.rawValue]).map { String(format: "%02X", $0) }.joined(separator: " "))")

        let confirmed = await withTimeout(.seconds(5)) {
            for await frame in stream where frame.mode == target { return true }
            return false
        } ?? false

        if confirmed {
            let elapsed = ContinuousClock.now - started
            print("confirmed \(target.label) after \(elapsed)")
        } else {
            print("no confirmation in 5 s; polling the getter…")
            let actual = try await runner.client.request(.getMode)
            print("device reports \(actual.mode?.label ?? "?")")
        }
    }

    @MainActor
    static func watch() async throws {
        let runner = Runner()
        try await runner.waitForReady()
        print("watching. change the mode by tapping a bud or from your phone. Ctrl-C to stop.")
        for await frame in runner.client.frames() {
            print("[\(Date().formatted(date: .omitted, time: .standard))] \(frame.command) status=\(frame.status) payload=\(frame.payload.map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
    }

    static func symbols() {
        // Cheap guard against shipping a menu bar icon that renders as nothing.
        let names = ANCMode.allCases.map(\.symbol) + ["ear", "ear.fill", "waveform", "waveform.slash", "ear.and.waveform"]
        for name in Set(names).sorted() {
            let exists = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
            print("\(exists ? "ok  " : "MISSING") \(name)")
        }
    }
}
