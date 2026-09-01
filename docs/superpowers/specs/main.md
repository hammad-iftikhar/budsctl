# BudsCtl — macOS ANC control for SoundPEATS Air4 Pro

Technical specification. Target: macOS 26 Tahoe or later, Swift 6, Xcode 16+.

Controls the three noise modes (normal / ANC / passthrough) from the menu bar,
Control Center, Shortcuts, and a global hotkey. Protocol is fully known and
verified against a live capture — see [Protocol](#1-protocol-reference).

---

## 0. Architecture

The central constraint: **Control Center widgets run in a separate sandboxed
extension process with a short execution budget.** They cannot own a Bluetooth
connection. Neither can they wait 1.4 s for a mode change to confirm.

So the connection lives in a long-running agent, and the widget is a thin
remote that posts requests to it.

```
┌────────────────────────────────────────────────────────┐
│  BudsCtl.app  (LSUIElement agent, launch at login)     │
│                                                        │
│   MenuBarExtra UI ──┐                                  │
│                     ├── DeviceController (state owner) │
│   Global hotkey ────┘         │                        │
│                               ├── GaiaClient           │
│                               │     (CoreBluetooth,    │
│                               │      persistent conn)  │
│                               └── StateBridge          │
│                                     (App Group write)  │
└───────────────────────────────┬────────────────────────┘
                                │  App Group defaults
                                │  + Darwin notification
┌───────────────────────────────┴────────────────────────┐
│  BudsCtlControls.appex  (WidgetKit control extension)  │
│    ControlWidget × 4  →  AppIntent  →  post request    │
│    ControlValueProvider  ←  read cached state          │
└────────────────────────────────────────────────────────┘
```

**Why an agent and not a regular app:** the connection must already be warm
when the user clicks. Establishing a CoreBluetooth connection takes 1–3 s; a
mode switch on a warm connection is ~1.4 s. Cold-starting on each click would
make it feel broken.

### Targets

| Target            | Kind              | Purpose                               |
| ----------------- | ----------------- | ------------------------------------- |
| `BudsCtl`         | App (LSUIElement) | Menu bar UI, BLE connection, state    |
| `BudsCtlControls` | Widget extension  | Control Center controls               |
| `BudsKit`         | Framework         | Protocol, models, App Intents, bridge |

`BudsKit` must be a framework, not just shared files — the App Intent types
have to resolve identically in both processes or Control Center won't bind them.

---

## 1. Protocol reference

GAIA V2 over BLE. Every value below is confirmed from an iOS PacketLogger
capture of the official SoundPEATS app, not inferred.

### GATT

| Item                             | UUID                                   |
| -------------------------------- | -------------------------------------- |
| Service                          | `00001100-d102-11e1-9b23-00025b00a5a5` |
| Command endpoint (write)         | `00001101-d102-11e1-9b23-00025b00a5a5` |
| Response endpoint (notify)       | `00001102-d102-11e1-9b23-00025b00a5a5` |
| Data endpoint (unused)           | `00001103-d102-11e1-9b23-00025b00a5a5` |
| Battery (standard, ×2 instances) | `180F` / `2A19`                        |

Subscribe to `1102` **before** writing anything, or replies are lost.

### Frame format

```
request:   <vendor:2 = 00 0A> <command:2> <payload...>
reply:     <vendor:2 = 00 0A> <command|0x8000:2> <status:1> <payload...>
```

`status` is `0x00` on success. Treat other values as advisory only — this
firmware returned `0x01` on commands that were simply unsupported, and its
status reporting is not otherwise trustworthy. Confirm state by reading, never
by checking status.

### Commands

| Command  | Direction | Payload  | Notes                                                   |
| -------- | --------- | -------- | ------------------------------------------------------- |
| `0x0306` | get       | —        | Left bud battery: `00 <percent>`                        |
| `0x0307` | get       | —        | Right bud battery: `00 <percent>`                       |
| `0x0309` | get       | —        | Firmware ASCII, e.g. `AIR4PRO-BS588R2E_20241112_v0.2.1` |
| `0x0310` | get       | —        | Current mode: `00 <mode>`                               |
| `0x0311` | **set**   | `<mode>` | Bare mode byte. **No GAIA reply.**                      |

| Mode        | Byte   |
| ----------- | ------ |
| Normal      | `0x00` |
| ANC         | `0x01` |
| Passthrough | `0x02` |

Unidentified getters that answer but whose meaning is unknown: `0x030C` → `01`,
`0x030E` → `00`, `0x0312` → `00`. Likely game mode / in-ear detection / similar.
Do not ship anything depending on these without capturing the app toggling them.

**Never write to `0x01xx` or `0x02xx`.** Those groups include device reset and
power off. There is no reason for this app to touch them.

### The set/confirm cycle

This is the single most important behavioural detail for UI design:

```
t+0.00  write 00 0A 03 11 01        → ATT write response only, no GAIA ack
t+1.40  notify 00 0A 83 10 00 01    → unsolicited 0x0310, mode now applied
```

Consequences:

1. Do not await a GAIA reply after `0x0311`. There isn't one.
2. The ~1.4 s delay is the device's, not yours. Design for it (§4).
3. The device emits `0x0310` notifications **whenever the mode changes**,
   including when the user changes it by tapping a bud or from their phone.
   The UI therefore stays truthful for free — subscribe and never poll.

---

## 2. GaiaClient — CoreBluetooth layer

### Connection strategy

CoreBluetooth solves the problem that made the Python prototype painful. Python
(bleak) can only reach an advertising peripheral, forcing the case-lid dance.
CoreBluetooth does not:

```swift
// No scan. Works whether or not the peripheral is currently advertising.
let known = central.retrievePeripherals(withIdentifiers: [savedUUID])
guard let peripheral = known.first else { /* re-pair needed, see §7 */ }

// Pending connection: stays queued indefinitely and completes the moment
// the buds come into range. This IS the auto-reconnect mechanism.
central.connect(peripheral, options: nil)
```

`connect` on an unavailable peripheral does not fail — it stays pending. So the
whole reconnect strategy is: call `connect` once at launch, and call it again
immediately in `didDisconnectPeripheral`. Never scan after first run.

```swift
func centralManager(_ c: CBCentralManager,
                    didDisconnectPeripheral p: CBPeripheral,
                    error: Error?) {
    state.connection = .waiting
    c.connect(p, options: nil)   // re-arm immediately
}
```

### First-run discovery

Try in order:

1. `retrieveConnectedPeripherals(withServices: [gaiaServiceUUID])` — if the
   buds are already connected to the Mac, this returns them with no scan.
2. `scanForPeripherals(withServices: [gaiaServiceUUID])` — may miss them, since
   the service need not appear in the advertisement payload.
3. `scanForPeripherals(withServices: nil)`, present a picker filtered to names
   containing `SOUNDPEATS`, plus a "show all devices" escape hatch.

Persist `peripheral.identifier` (a `UUID`) to the App Group defaults. It is
stable per-Mac and survives reboots, but **changes if the user re-pairs**.

### Post-connect sequence

```
didConnect
  → discoverServices([gaia, batteryService])
  → discoverCharacteristics for gaia: [cmd, rsp]
  → setNotifyValue(true, for: rsp)          ← must complete first
  → didUpdateNotificationStateFor(rsp)
      → write 0x0309 (firmware, once per connection)
      → write 0x0310 (current mode)
      → write 0x0306, 0x0307 (battery)
      → state.connection = .ready
```

Gate `.ready` on the notification subscription, not on `didConnect`. Writes
sent before the subscription lands produce replies nobody hears.

Use `.withResponse` for writes to `1101` — the capture shows the official app
does, and it gives you ATT-level delivery confirmation.

### Two battery characteristics

The device exposes two separate `180F` service instances. Discovery order is
not guaranteed to mean left/right, so prefer the GAIA getters `0x0306`/`0x0307`,
which are explicitly per-side. Keep the standard characteristics only as a
fallback if a GAIA read fails.

---

## 3. State model

```swift
enum ANCMode: UInt8, CaseIterable, Sendable {
    case normal = 0x00, anc = 0x01, passthrough = 0x02
}

enum ConnectionState: Sendable {
    case bluetoothOff
    case notConfigured        // no saved identifier
    case waiting              // pending connection, buds unavailable
    case connecting
    case ready
    case failed(String)
}

@Observable @MainActor final class DeviceState {
    var connection: ConnectionState = .notConfigured
    var mode: ANCMode?              // last confirmed
    var pendingMode: ANCMode?       // optimistic, during the 1.4s window
    var batteryLeft: Int?
    var batteryRight: Int?
    var firmware: String?
    var lastError: String?

    /// What the UI should render as selected.
    var displayMode: ANCMode? { pendingMode ?? mode }
    var isBusy: Bool { pendingMode != nil }
}
```

Single writer: only `DeviceController` mutates `DeviceState`, on the main actor.

### Refresh policy

| Data     | Policy                                                                 |
| -------- | ---------------------------------------------------------------------- |
| Mode     | Never poll. Notification-driven, plus one read on connect and on wake. |
| Battery  | Every 5 min while connected, and on menu open.                         |
| Firmware | Once per connection.                                                   |

---

## 4. Set-mode flow

Handles the 1.4 s delay without feeling laggy, and without lying to the user.

```swift
func setMode(_ target: ANCMode) async {
    state.pendingMode = target          // UI updates instantly
    defer { state.pendingMode = nil }

    do {
        try await gaia.write(.setANC, payload: [target.rawValue])
    } catch {
        state.lastError = "Write failed"
        return
    }

    // Wait for the unsolicited 0x0310 notification.
    if await gaia.awaitModeChange(to: target, timeout: .seconds(3)) {
        state.mode = target
        bridge.publish(state)
        return
    }

    // No notification: poll the getter once before giving up.
    if let actual = try? await gaia.readMode() {
        state.mode = actual
        if actual != target { state.lastError = "Device did not change mode" }
    }
    bridge.publish(state)
}
```

UI rules during `isBusy`: show the target as selected with a subtle progress
affordance, keep controls enabled (a user changing their mind mid-flight should
win), and coalesce rapid clicks — cancel any in-flight wait and issue the newest
target only.

---

## 5. Control Center integration

### Which controls to ship

Three states don't map onto `ControlWidgetToggle`. With 32 available slots,
ship four controls and let the user pick in **Edit Controls**:

| Control      | Kind   | Behaviour                                  |
| ------------ | ------ | ------------------------------------------ |
| Noise Mode   | Button | Cycles normal → ANC → passthrough → normal |
| ANC          | Button | Sets ANC directly                          |
| Transparency | Button | Sets passthrough directly                  |
| Noise Off    | Button | Sets normal directly                       |

The cycle control is the default recommendation; the direct ones matter for
users who want one specific mode one tap away.

### Widget definition

```swift
struct NoiseModeControl: ControlWidget {
    static let kind = "com.yourorg.budsctl.control.cycle"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind,
                                   provider: ModeValueProvider()) { value in
            ControlWidgetButton(action: CycleModeIntent()) {
                Label(value.label, systemImage: value.symbol)
            }
        }
        .displayName("Earbuds Noise Mode")
        .description("Cycle between noise cancellation, transparency, and off.")
    }
}

struct ModeValueProvider: ControlValueProvider {
    var previewValue: ModeSnapshot { .init(mode: .anc, connected: true) }

    func currentValue() async throws -> ModeSnapshot {
        StateBridge.shared.readSnapshot()   // App Group defaults, no BLE
    }
}
```

`currentValue()` must be cheap and non-blocking. It reads cached state only.
It must never touch CoreBluetooth.

### The bridge

Widget extension → agent, via App Group defaults plus a Darwin notification:

```swift
// In the extension's intent perform()
StateBridge.shared.postRequest(.setMode(target))
// writes {"mode": N, "seq": M} to the App Group defaults, then:
CFNotificationCenterPostNotification(
    CFNotificationCenterGetDarwinNotifyCenter(),
    CFNotificationName("com.yourorg.budsctl.request" as CFString),
    nil, nil, true)
```

The agent observes that Darwin notification, reads the request, executes it, and
on completion writes the new state back and calls:

```swift
ControlCenter.shared.reloadControls(ofKind: NoiseModeControl.kind)
```

Include a monotonic `seq` in the request so a replayed or stale notification is
ignored. Darwin notifications carry no payload and are coalescing — the defaults
write is the actual channel, the notification is only a nudge.

**If the agent isn't running:** the intent should launch it. Conform the intent
to `ForegroundContinuableIntent` and request continuation, or register the app as
a login item so this is rare. Do not let the control silently no-op.

### App Intents

Define them in `BudsKit` so both processes see identical types. They become
Shortcuts actions for free, which also gets you Raycast and Alfred integration
at no extra cost.

```swift
struct SetModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Noise Mode"
    static let description = IntentDescription("Set the earbuds' noise mode.")
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Mode") var mode: ANCModeAppEnum

    func perform() async throws -> some IntentResult & ProvidesDialog {
        StateBridge.shared.postRequest(.setMode(mode.asANCMode))
        return .result(dialog: "Set to \(mode.rawValue)")
    }
}
```

Also expose `CycleModeIntent`, `GetModeIntent`, and `GetBatteryIntent`.

---

## 6. Menu bar UI

```swift
@main struct BudsCtlApp: App {
    @State private var controller = DeviceController()

    var body: some Scene {
        MenuBarExtra { PanelView(controller: controller) }
        label: { Image(systemName: controller.state.menuBarSymbol) }
            .menuBarExtraStyle(.window)
    }
}
```

`.window` style, not `.menu` — you need a segmented control and battery readout,
which a plain menu renders badly.

Panel contents, top to bottom: device name and connection state; a
three-segment mode picker showing the active mode; per-bud battery with an
icon; firmware version in small caption text; a divider; Settings and Quit.

Menu bar icon should encode mode at a glance. Verify these exist in the SF
Symbols app before using them:

| State        | Candidate symbol                         |
| ------------ | ---------------------------------------- |
| ANC          | `ear.badge.waveform` or `waveform.slash` |
| Passthrough  | `ear`                                    |
| Normal       | `ear.fill` at reduced opacity            |
| Disconnected | same, `.tertiary` foreground style       |
| Busy         | brief `.symbolEffect(.pulse)`            |

Use template rendering so it adapts to light, dark, and tinted menu bars.

---

## 7. Edge cases

Each of these needs an explicit behaviour. "Seamless" is mostly this table.

| Situation                        | Required behaviour                                                                                                                  |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Buds in case / powered off       | `.waiting`. Controls disabled with reason shown. Pending connect stays armed; no polling, no scanning.                              |
| Buds come out of case            | Pending connection completes automatically. No user action.                                                                         |
| Mode changed by tapping a bud    | Unsolicited `0x0310` notification updates UI and reloads controls.                                                                  |
| Mode changed from the phone app  | Same as above.                                                                                                                      |
| Buds connected to phone only     | GAIA writes may fail or be refused. Surface as "In use by another device", retry on next notification.                              |
| Bluetooth turned off             | `centralManagerDidUpdateState` → `.bluetoothOff`. Offer to open Settings.                                                           |
| Mac sleeps and wakes             | Observe `NSWorkspace.didWakeNotification`; re-read mode and battery. Connection usually survives; state may be stale.               |
| User re-pairs the buds           | `retrievePeripherals` returns empty → `.notConfigured`, prompt re-discovery. Detect this rather than spinning on a dead identifier. |
| Rapid repeated clicks            | Coalesce. Cancel in-flight wait, send only the newest target.                                                                       |
| Set silently lost                | 3 s timeout → poll getter once → reconcile UI to truth, show error if mismatched.                                                   |
| Firmware update changes protocol | Log the firmware string on connect. Compare against the known-good `v0.2.1` and warn rather than misbehave.                         |
| Two Macs                         | Each has its own peripheral identifier. Works independently; both may hold LE links.                                                |

---

## 8. Entitlements, Info.plist, signing

### BudsCtl (app)

Entitlements:

```
com.apple.security.app-sandbox            true
com.apple.security.device.bluetooth       true
com.apple.security.application-groups     [ <TeamID>.com.yourorg.budsctl ]
```

Info.plist:

```
LSUIElement                        true      ← menu bar only, no Dock icon
NSBluetoothAlwaysUsageDescription  "BudsCtl connects to your earbuds to
                                    change noise cancellation modes."
```

`NSBluetoothAlwaysUsageDescription` is not optional. Without it CoreBluetooth is
denied — sometimes silently, which wastes an afternoon.

### BudsCtlControls (extension)

Same sandbox and app-group entitlements. `NSExtensionPointIdentifier` =
`com.apple.widgetkit-extension`.

### Signing gotcha

App Groups require a real Team ID. Ad-hoc signing will not work — you need at
minimum a free Apple Developer account with automatic signing in Xcode. On
macOS, sandboxed app group identifiers must carry the Team ID prefix.

### Launch at login

```swift
try SMAppService.mainApp.register()      // macOS 13+
```

Expose as a Settings toggle; check `SMAppService.mainApp.status` to reflect
actual state rather than a stored preference.

### Global hotkey

Use `Carbon.RegisterEventHotKey` (still the only reliable non-sandbox-breaking
route) or a small package like `KeyboardShortcuts`. Default suggestion:
`⌥⌘N` cycles mode. Must work without focusing the app.

---

## 9. Build order

| Milestone | Deliverable                                                        | Exit test                                                                         |
| --------- | ------------------------------------------------------------------ | --------------------------------------------------------------------------------- |
| M1        | Swift CLI in `BudsKit`: connect by identifier, read mode, set mode | Sets all three modes with no case-lid dance, proving the pending-connection model |
| M2        | Menu bar app, live state, notification-driven updates              | Tapping a bud updates the menu bar within 2 s                                     |
| M3        | Control extension, App Intents, bridge                             | Control Center button works with the app already running                          |
| M4        | Agent lifecycle: login item, cold-start from control, sleep/wake   | Control Center works after a reboot with the app never manually opened            |
| M5        | Polish: hotkey, settings, errors, re-pair recovery                 | Every row in §7 behaves as specified                                              |

Do M1 as a command-line target before any UI. It isolates the one genuinely
uncertain thing — whether the pending-connection approach behaves as documented
against this specific firmware. Everything after that is ordinary app work.

---

## 10. Testing

`GaiaFrame` encode/decode is pure and should be unit tested against the real
captured bytes:

```swift
#expect(GaiaFrame.encode(.setANC, [0x01]) == Data([0x00,0x0A,0x03,0x11,0x01]))

let reply = Data([0x00,0x0A,0x83,0x10,0x00,0x01])
#expect(GaiaFrame.decode(reply)?.mode == .anc)

let batt = Data([0x00,0x0A,0x83,0x06,0x00,0x55])
#expect(GaiaFrame.decode(batt)?.percent == 85)
```

Put `GaiaClient` behind a protocol so `DeviceController` can be tested against a
fake transport that reproduces the real timing — in particular the 1.4 s delayed
notification and the no-ack-on-set behaviour. Those two quirks are where bugs
will actually live.

Manual checks worth scripting into a checklist: reboot with buds in case then use
Control Center; change mode on the phone and watch the Mac follow; sleep the Mac
for an hour and switch mode immediately on wake.

---

## Appendix: raw reference

Working commands, verified:

```
set normal        00 0A 03 11 00
set ANC           00 0A 03 11 01
set passthrough   00 0A 03 11 02
get mode          00 0A 03 10        → 00 0A 83 10 00 <mode>
left battery      00 0A 03 06        → 00 0A 83 06 00 <pct>
right battery     00 0A 03 07        → 00 0A 83 07 00 <pct>
firmware          00 0A 03 09        → 00 0A 83 09 00 <ascii>
```

Device under test: SOUNDPEATS Air4 Pro, QCC3071,
firmware `AIR4PRO-BS588R2E_20241112_v0.2.1`.

Protocol derived by reverse engineering for interoperability. GAIA has no public
specification; everything here came from observing traffic to a device you own.
