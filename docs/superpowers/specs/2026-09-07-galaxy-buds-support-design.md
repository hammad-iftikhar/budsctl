# Galaxy Buds support — multi-backend earbuds architecture

Technical specification. Target: macOS 26 Tahoe or later, Swift 6, Xcode 16+.

Adds Samsung Galaxy Buds (Buds FE and the rest of the modern lineup) alongside
the existing SoundPEATS Air4 Pro, and restructures `BudsKit` so a third device
family costs one new file plus one line in a registry.

Protocol reverse-engineered from
[GalaxyBudsClient](https://github.com/timschneeb/GalaxyBudsClient) — see
[§2 Wire protocol](#2-wire-protocol). Verification status is stated per claim;
one offset is explicitly marked unverified.

---

## 0. Why this needs an architecture change

The two devices differ at every layer:

| | SoundPEATS Air4 Pro | Galaxy Buds FE |
| --- | --- | --- |
| Radio | Bluetooth LE, GATT | Bluetooth Classic, RFCOMM/SPP |
| Framework | CoreBluetooth | IOBluetooth |
| Device identity | `CBPeripheral.identifier` (`UUID`) | MAC address (`String`) |
| Framing | `000A <cmd:2> <payload>` | `FD <hdr:2> <id> <payload> <crc:2> DD` |
| Integrity | none | CRC16-CCITT |
| Battery | two separate getters, per side | one pushed status message, both sides |
| Initial state | unreliable for ~45 s after connect | pushed unsolicited on connect |
| Change notification | unsolicited `0x0310`, sometimes absent | reliable `NOISE_CONTROLS_UPDATE` |
| Reconnect | `CBCentralManager.connect` stays queued | no queued-connect; needs a notification |

Only one thing is the same, and it is a gift: the mode byte values.

```
Off = 0   ANC = 1   Ambient/Transparency = 2
```

These are already `ANCMode.normal/.anc/.passthrough` raw values, so no mapping
table is needed anywhere.

### Where to put the seam

`DeviceController` currently speaks `GaiaCommand` directly. That is the wrong
altitude to abstract at. GAIA exposes per-side battery *getters*
(`getBatteryLeft`, `getBatteryRight`); Samsung *pushes* one combined status
message. A shared command enum would have to invent commands that one side
cannot honour, and every backend would carry a pile of unsupported cases.

The seam goes one level up: **what the app needs from a pair of earbuds**, which
is a small, closed set — observe mode and battery, set mode, ask for a refresh.
Everything below that (framing, radio, checksums, reconnect strategy) is the
backend's private business.

---

## 1. Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  BudsCtl.app                                                 │
│                                                              │
│   AppModel                                                   │
│     ├── backends: [any EarbudsBackend]   (all started, for   │
│     │     ├── GaiaBackend                 discovery)         │
│     │     └── SamsungBackend                                 │
│     │                                                        │
│     └── DeviceController  ──  use(backend)                   │
│           │                   (swapped when the user picks   │
│           │                    a device on the other radio)  │
│           ├── DeviceState     (unchanged, sole writer)       │
│           └── StateBridge     (unchanged protocol, new key)  │
└──────────────────────────────────────────────────────────────┘
```

All backends run their discovery concurrently so the Settings list shows both
brands at once. **Exactly one backend is adopted** — holds a link and feeds
`DeviceController` — at a time. Simultaneous multi-device was considered and
rejected: it would require per-device `DeviceState`, a snapshot-per-device
bridge format, a device picker in the menu bar panel, and reworked intents,
roughly tripling the scope for a case nobody asked for.

### 1.1 The backend contract

```swift
/// One update from a device. Maps 1:1 onto DeviceController.apply, so the
/// controller's existing state machine is untouched.
public enum DeviceEvent: Sendable, Equatable {
    case mode(ANCMode)
    case batteryLeft(Int?)
    case batteryRight(Int?)
    case firmware(String)
}

/// Identifies a device across app launches, and says which backend owns it.
public struct DeviceRef: Hashable, Codable, Sendable {
    /// `EarbudsBackend.id`. Persisted — never change an existing value.
    public let backend: String
    /// Backend-private. CoreBluetooth UUID string, or a Bluetooth MAC address.
    public let id: String
}

/// Device quirks the controller cannot discover for itself.
public struct BackendPolicy: Sendable {
    /// Offsets from connect at which to re-read the mode. Empty means the
    /// device pushes its state and nothing needs re-reading.
    public var settleReads: [Duration] = []
    /// Battery refresh interval, or nil when the device pushes battery.
    public var batteryInterval: Duration? = nil
}

@MainActor
public protocol EarbudsBackend: AnyObject {
    /// Stable key, stored inside every DeviceRef. Never change one.
    static var id: String { get }
    /// Human name for the Settings section header.
    static var displayName: String { get }

    /// Whether this looks like a device this backend can drive, for the
    /// filtered scan list. Name-based; advisory only.
    func isLikelyMatch(_ device: DiscoveredDevice) -> Bool

    var onConnectionChange: (@MainActor (ConnectionState) -> Void)? { get set }
    var onDiscoveryUpdate: (@MainActor ([DiscoveredDevice]) -> Void)? { get set }

    /// Bring the radio up and make discovery available. Does not connect.
    func start()
    func connectedDevices() -> [DiscoveredDevice]
    func startScan()
    func stopScan()

    /// Take ownership of this device and keep it connected.
    func adopt(_ ref: DeviceRef)
    /// Drop the link and stop reporting connection state.
    func release()

    /// A *fresh* stream per caller — concurrent waiters must not steal each
    /// other's events. Same contract as `GaiaTransport.frames()` today.
    func events() -> AsyncStream<DeviceEvent>

    func setMode(_ mode: ANCMode) async throws
    func refreshMode() async
    func refreshBattery() async

    var policy: BackendPolicy { get }
}
```

`BackendPolicy` is not speculative configuration. Both fields differ between the
two shipping devices:

| | `settleReads` | `batteryInterval` |
| --- | --- | --- |
| `GaiaBackend` | `[2, 5, 10, 20, 45] s` | `300 s` |
| `SamsungBackend` | `[]` | `nil` |

`settleReads: []` is what deletes the whole 45-second re-read dance for Galaxy
Buds — they push `EXTENDED_STATUS_UPDATED` on connect, so there is nothing to
settle. `batteryInterval: nil` stops two pointless writes every five minutes.

### 1.2 What each backend supplies

```swift
public enum Backends {
    /// The one list. A new device family is one line here.
    @MainActor
    public static func all(bridge: StateBridge) -> [any EarbudsBackend] {
        [GaiaBackend(bridge: bridge), SamsungBackend()]
    }

    /// Backward compatibility: a stored bare UUID predates DeviceRef.
    public static let legacyBackendID = GaiaBackend.id
}
```

### 1.3 Changes to existing types

| File | Change |
| --- | --- |
| `ANCMode.swift` | none |
| `DeviceState.swift` | none |
| `Intents.swift` | none |
| `Controls/Controls.swift` | none |
| `DeviceController.swift` | `transport: GaiaTransport` → `backend: any EarbudsBackend`; `apply(_ frame:)` → `apply(_ event:)`; `use(_:)` added; `settleReads`/`batteryInterval` read from `backend.policy` |
| `GaiaClient.swift` | `start()` split into `start()` (radio up) and `adopt(_:)` (connect); stops reading `bridge.peripheralIdentifier` itself |
| `StateBridge.swift` | `peripheralIdentifier: UUID?` → `deviceRef: DeviceRef?` |
| `SettingsView.swift` | device list grouped by backend; `selected` compares `DeviceRef` |
| `BudsCtlApp.swift` | `AppModel` owns all backends, merges discovery, routes `adopt` |

`ModeSnapshot`, the App Group protocol, the Darwin notification, the four App
Intents and the Control Center widget are all untouched. That matters: the
snapshot is a cross-process `Codable` contract, and an installed appex older
than the agent must keep working.

### 1.4 DeviceController generalisation

`apply` becomes a switch on `DeviceEvent` instead of `GaiaFrame`, one case per
case, same bodies:

```swift
private func apply(_ event: DeviceEvent) {
    switch event {
    case .mode(let mode):
        state.mode = mode
        if state.pendingMode == mode { state.pendingMode = nil }
        publish()
    case .batteryLeft(let percent):  state.batteryLeft = percent;  publish()
    case .batteryRight(let percent): state.batteryRight = percent; publish()
    case .firmware(let version):     /* unchanged, incl. knownGoodFirmware */ publish()
    }
}
```

`performSet` waits on `events()` for `.mode(target)` where it waited on
`frames()` for `frame.mode == target`. `refreshAfterConnect` calls
`backend.refreshMode()` / `refreshBattery()` instead of issuing GAIA getters.
Everything that made this file hard — `writeOrder`, superseded-set handling,
`isResolvingMode`, publish-before-write, the `!Task.isCancelled` re-checks after
every await — is preserved verbatim. Those are bug fixes with commit history
behind them and none of them are device-specific.

The firmware `knownGoodFirmware` warning stays GAIA-only in effect: Samsung
never emits `.firmware`, so the check never fires. Left as is rather than
generalised into the policy — one device reports firmware, so a per-backend
"known good firmware" field would be config for a value that never varies.

`use(_ backend:)`:

```swift
public func use(_ backend: any EarbudsBackend) {
    stop()                    // cancels every task, clears isResolvingMode
    self.backend = backend
    state.mode = nil          // a mode from the previous device is not news
    state.batteryLeft = nil
    state.batteryRight = nil
    state.firmware = nil
    start()
}
```

Called only from `AppModel` when the user selects a device whose `DeviceRef`
names a different backend. Same-backend selection goes straight to
`backend.adopt(ref)`, which already handles releasing the old peripheral.

### 1.5 Persistence and migration

`DeviceRef` is stored as one string, `"<backend>:<id>"`, under the existing
`peripheralIdentifier` key:

```
gaia:2B4A9F10-0000-0000-0000-000000000000
samsung:98-80-bb-41-1a-93
```

Reading a value with no `:` treats the whole string as a `gaia` id, so an
install from v1.2 keeps its selected Air4 Pro across the update. Written back in
the new form on the next selection.

The key name is kept rather than renamed. Renaming it would silently forget
every existing user's device, and the value is private to `StateBridge` anyway.

---

## 2. Wire protocol

### 2.1 Framing

Uniform across Buds+, Buds Live, Buds Pro, Buds2, Buds2 Pro, Buds FE, Buds3,
Buds3 Pro, Buds3 FE, Buds Core, Buds4 and Buds4 Pro. Only the 2019 original
Galaxy Buds use different framing, and they are out of scope
([§5](#5-scope)).

```
FD  size_lo size_hi  msg_id  payload…  crc_lo crc_hi  DD
│   └── little-endian UInt16 ──┘                      └── postamble
└── preamble
```

| Field | Value |
| --- | --- |
| Preamble | `0xFD` |
| Header | little-endian `UInt16`. Bits 0–9 = size. Bit 12 = type. Bit 13 = fragment. |
| `size` | `1 (msg_id) + payload.count + 2 (crc)` |
| Checksum | CRC16-CCITT/XMODEM over `msg_id ‖ payload`, little-endian |
| Postamble | `0xDD` |

**Bit 12 (type) is ignored in both directions.** GalaxyBudsClient sets it for
`Response` when encoding and reads it as `Request` when decoding — an asymmetry
in the reference implementation. It does not matter here: we only ever send
requests (bit 12 clear), and on receive we dispatch on `msg_id` alone. Modelling
a field we neither set nor read would be pure ceremony.

**Bit 13 (fragment) frames are dropped.** Fragmentation only carries firmware
OTA images and core dumps, neither of which this app does.

### 2.2 Checksum

CRC16-CCITT/XMODEM: polynomial `0x1021`, initial value `0x0000`, MSB-first, no
input or output reflection, no final XOR.

```swift
static func crc16(_ bytes: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0
    for byte in bytes {
        crc ^= UInt16(byte) << 8
        for _ in 0..<8 {
            crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
    }
    return crc
}
```

The reference implementation uses a 256-entry lookup table and validates by
appending the two received CRC bytes *swapped* and checking the result is zero.
Both are avoided: this loop is six lines and needs no table, and comparing the
computed CRC against the little-endian value read off the wire is the same check
stated plainly.

### 2.3 Messages used

Message IDs are decimal, as in the reference implementation.

| Dir | ID | Name | Payload |
| --- | --- | --- | --- |
| → | 136 | `MANAGER_INFO` | `[0x01, 0x02, 0x22]` — announce ourselves on connect |
| → | 120 | `NOISE_CONTROLS` | `[mode]` |
| ← | 66 | `ACKNOWLEDGEMENT` | `[0]` = acked id, `[1]` = value |
| ← | 119 | `NOISE_CONTROLS_UPDATE` | `[0]` = mode |
| ← | 97 | `EXTENDED_STATUS_UPDATED` | pushed on connect; see below |
| ← | 96 | `STATUS_UPDATED` | pushed on battery or wear change |

`MANAGER_INFO`'s three bytes are a constant `1`, a client type
(`1` = Samsung phone, `2` = other), and an Android SDK level. We send
`2` and `34`. The reference implementation sends this on connect and its stated
purpose is to unlock phone-side features; it is harmless and cheap, so it is
sent for parity rather than because a need was demonstrated.

Nothing requests state. The buds volunteer `EXTENDED_STATUS_UPDATED` when the
SPP channel opens, and `NOISE_CONTROLS_UPDATE` on every mode change from any
source — a touch gesture, the phone's Wearable app, or us.

### 2.4 Payload offsets

`STATUS_UPDATED` (96), for Buds+ and later:

| Index | Field | Used |
| --- | --- | --- |
| 0 | revision | no |
| 1 | battery L, 0–100 | **yes** |
| 2 | battery R, 0–100 | **yes** |
| 3 | coupled | no |
| 4 | main connection | no |
| 5 | placement L/R, nibbles | no |
| 6 | case battery | no ([§5](#5-scope)) |
| 7 | charging bitfield | no |

`EXTENDED_STATUS_UPDATED` (97), for Buds Live and later:

| Index | Field | Used |
| --- | --- | --- |
| 0 | revision | no |
| 1 | ear type | no |
| 2 | battery L, 0–100 | **yes** |
| 3 | battery R, 0–100 | **yes** |
| 4 | coupled | no |
| 5 | main connection | no |
| 6 | placement L/R, nibbles | no |
| 7 | case battery | no ([§5](#5-scope)) |
| 8 | adjust sound sync | no |
| 9 | equaliser mode | no |
| 10 | touch lock — *interpretation* varies by model | no |
| 11 | touch options L/R, nibbles | no |
| 12 | **noise control mode** | **yes, unverified** |
| 13… | voice wake-up, colours, … | no |

### 2.5 The one unverified claim

**Byte 12 of `EXTENDED_STATUS_UPDATED` is the only offset in this spec that was
inferred from a model-branching parser rather than read off a stable layout.**

Every other offset used here is assigned unconditionally for all models from
Buds+ onward. Byte 12 sits immediately after byte 10, whose *interpretation*
forks on `Features.AdvancedTouchLock` — the fork changes how the byte is read,
not where later fields sit, but that is a reading of the reference source, not
a capture.

It also cannot be avoided. It is the only source of the mode at connect time;
`NOISE_CONTROLS_UPDATE` fires only on a *change*, so without byte 12 the app
would show "Reading mode…" until the user changed mode by some other means.

Mitigations:

1. **Validate the value.** Accept only `0`, `1` or `2`. A wrong offset would
   most often land on a touch-option nibble pair, a colour word or a boolean —
   values that usually fall outside that range. A failed check leaves
   `isResolvingMode` true and the UI honestly reading "Reading mode…", which is
   the behaviour the existing `settleMode` documentation argues for at length:
   never present an untrusted read as a confident selection.
2. **Require a plausible payload.** Ignore the message unless
   `payload.count > 12` and `payload[2] <= 100` and `payload[3] <= 100`.
3. **Confirm against hardware** with the CLI probe ([§4](#4-verification)).

This risk is stated rather than engineered around because the alternative —
showing a confidently wrong mode — is the specific failure mode this codebase
already has scar tissue for.

---

## 3. `SamsungBackend`

### 3.1 Discovery

`IOBluetoothDevice.pairedDevices()` returns every paired classic device with its
name, MAC address and connection state, synchronously and instantly. Verified
working on macOS 26 under Swift 6.

That is the whole discovery story: `connectedDevices()` returns the paired list
(annotated with `isConnected`), and `startScan()` / `stopScan()` are no-ops.
`IOBluetoothDeviceInquiry` could find unpaired devices, but pairing has to happen
in System Settings regardless — which is already how the app tells users to get
started — so an inquiry would only add a scan that cannot lead anywhere new.

`isLikelyMatch` is a name check for `"BUDS"`, mirroring `"SOUNDPEATS"` on the
GAIA side. Advisory only: it filters the scan list, never the connected list.

### 3.2 Connecting

Mirroring the reference implementation's macOS backend, which documents each
workaround:

1. `device.openConnection()` — the RFCOMM open API does not do this itself.
   `kIOReturnTimeout` here means the buds are in the case.
2. `device.performSDPQuery(self)` — **with no UUID filter**. A filtered SDP
   query silently fails on macOS Ventura and later.
3. Await `sdpQueryComplete(_:status:)`, bounded by a timeout.
4. `device.getServiceRecord(for:)` with `2e73a4ad-332d-41fc-90e2-16bef06523f2`
   (Buds2 and later, including Buds FE), falling back to
   `00001101-0000-1000-8000-00805F9B34FB` (Buds Pro, Buds Live, Buds+).
5. `record.getRFCOMMChannelID(_:)`.
6. `device.openRFCOMMChannelAsync(_:withChannelID:delegate:)`.
7. Report `.ready` from `rfcommChannelOpenComplete`, not from step 6's return
   value — the reference notes it returns `kIOReturnError` even on success.
   This matches the existing rule on the GAIA side: readiness is gated on the
   notification subscription landing, never on `didConnect`.

Failures map onto the existing `ConnectionState` cases: not paired →
`.notConfigured`, buds in the case → `.waiting`, no SPP service record →
`.failed("These earbuds do not expose the Samsung SPP service.")`.

### 3.3 Reconnecting

**This is the largest behavioural difference from the BLE path.** The GAIA
backend's entire auto-reconnect design rests on one CoreBluetooth fact:
`connect` on an unavailable peripheral stays queued and completes when the
peripheral appears. IOBluetooth has no equivalent.

Replacement: `IOBluetoothDevice.register(forConnectNotifications:selector:)`
fires when any paired device forms a baseband connection. On a notification for
the adopted MAC, run §3.2 from step 2 (the baseband link already exists). On
`rfcommChannelClosed`, report `.waiting` and wait for the next notification
rather than spinning.

An RFCOMM open can fail while the baseband link is up — most often because the
buds are still settling after leaving the case. Bounded retry: three attempts at
1 s, 3 s, 7 s, then stop and wait for the next connect notification. Not
open-ended, so a device that genuinely refuses SPP does not spin forever.

### 3.4 Reading

`rfcommChannelData(_:data:length:)` delivers arbitrary chunks, unlike GATT's
discrete notifications. So `SppFrame` owns a reassembly buffer:

- Append the chunk.
- Scan for `0xFD`. Discard anything before the first one.
- If fewer than 6 bytes are buffered, wait for more.
- Read `size`; if the full frame has not arrived, wait for more.
- Validate CRC and the `0xDD` postamble. On failure, drop one byte and rescan
  from the next `0xFD` — a corrupt frame must not desynchronise the stream.
- Emit the frame, remove its bytes, repeat.
- Cap the buffer at 4 KB; on overflow, clear it. A control channel that has
  fallen this far behind is not going to recover by buffering more, and an
  unbounded buffer on a byte stream is how a hung peer becomes a memory leak.

This is the one piece of genuinely tricky logic in the change, it has no
IOBluetooth dependency, and it gets the unit tests ([§4](#4-verification)).

### 3.5 Writing

`writeAsync(_:length:refcon:)` with the `rfcommChannelWriteComplete` delegate
callback, over a `refcon`-keyed FIFO of pending continuations — the same
structure as `GaiaClient.pendingWrites`, including its bounded write timeout and
its guarantee that every entry is resumed exactly once, by exactly one of
completion, timeout or channel teardown.

`writeSync` would be less code but blocks until the buffer reaches the hardware,
and this runs on the main actor. Chunking to `getMTU()` is kept from the
reference implementation even though every message this app sends is under
twelve bytes — the loop is three lines and dropping it would silently truncate
if a longer message is ever added.

### 3.6 Refreshing

`refreshBattery()` is a no-op: the buds push `STATUS_UPDATED` on every change.

`refreshMode()` closes and reopens the RFCOMM channel. No message requests
`EXTENDED_STATUS_UPDATED`; the buds send it when the channel opens, so reopening
is the only lever. It is cheaper than it sounds — SPP is a control channel and
A2DP audio runs independently, so the user hears nothing.

Called from `refreshOnWake()`, where it matters: if the link survives sleep,
no push arrives, and the mode could have been changed from the phone while the
Mac slept. `settleReads` is empty, so it is never called on a fresh connect,
where the push already happened.

---

## 4. Verification

### 4.1 Unit tests — `Tests/BudsKitTests/SppFrameTests.swift`

No hardware, no IOBluetooth. `SppFrame` is pure bytes in, frames out.

| Test | Asserts |
| --- | --- |
| `encodeKnownFrame` | `NOISE_CONTROLS` with `[0x01]` produces the exact expected bytes, CRC included |
| `roundTrip` | every message we send decodes back to the same id and payload |
| `crc16MatchesReferenceVector` | the documented reference payload from the protocol notes yields its documented checksum |
| `rejectsBadCrc` | one flipped payload bit is rejected, not decoded |
| `rejectsBadPreambleAndPostamble` | wrong `0xFD` / `0xDD` rejected |
| `reassemblesSplitFrame` | one frame delivered as three chunks decodes once |
| `reassemblesCoalescedFrames` | three frames in one chunk decode as three |
| `resyncsAfterGarbage` | leading junk, then a valid frame — the frame is found |
| `resyncsAfterCorruptFrame` | a bad-CRC frame followed by a good one: the good one is still decoded |
| `dropsFragmentedFrames` | bit 13 set is skipped without desynchronising |
| `boundsTheBuffer` | 8 KB of `0xFD` with no valid frame does not grow without limit |
| `rejectsImplausibleStatus` | `EXTENDED_STATUS_UPDATED` with battery > 100 or mode 3 yields no mode event |

The CRC reference vector comes from the protocol notes' worked example:
`61 02 00 4B 5F 01 00 00 00 01 05 00 02 00 13` with checksum bytes `0F F3`. It
pins the algorithm against a third-party value rather than against our own
implementation.

That vector has already been run against the [§2.2](#22-checksum) loop:
it yields `0xF30F`, whose little-endian wire bytes are `0F F3` — the documented
value. The reference's own zero-check (append the two CRC bytes swapped, CRC the
lot, expect zero) also yields zero on the same data, so the two formulations
agree and either may be used. The checksum algorithm is therefore settled and is
not among the risks in [§2.5](#25-the-one-unverified-claim).

### 4.2 CLI probe — `budsctl-cli samsung <mac>`

Opens the RFCOMM channel and prints every decoded frame as id, name and hex
payload, plus a decoded interpretation for the four messages we handle. This is
how [§2.5](#25-the-one-unverified-claim) gets settled: connect Buds FE, change
mode from the earbud's touch gesture, and check that byte 12 of the connect-time
`EXTENDED_STATUS_UPDATED` agrees with the `NOISE_CONTROLS_UPDATE` that follows.

The CLI target is unsandboxed, which also makes it the cheapest way to separate
a protocol bug from a sandbox denial ([§4.3](#43-manual-checks)).

### 4.3 Manual checks

Added to `docs/superpowers/manual-checklist.md`:

1. **Sandbox** — the signed, sandboxed app enumerates paired devices and opens
   an RFCOMM channel. `com.apple.security.device.bluetooth` is already in
   `App/BudsCtl.entitlements` and is the documented key for this, but it has
   only been confirmed unsandboxed. If it is denied, the fallback is removing
   `com.apple.security.app-sandbox` — acceptable here, since distribution is a
   DMG and the app is not notarized.
2. Both brands appear in Settings, grouped, with the saved one selected.
3. Selecting Galaxy Buds while the Air4 Pro is connected releases the BLE link.
4. Selecting the Air4 Pro again releases the RFCOMM channel.
5. Mode set from the menu bar lands on the buds; mode set by touch gesture or
   the phone's Wearable app reaches the menu bar.
6. Battery for both sides appears within seconds of connecting.
7. Buds into the case → `.waiting`; out of the case → reconnect without user
   action.
8. Sleep and wake with the buds on: mode is still correct.
9. Control Center tile and all four Shortcuts intents work against Galaxy Buds
   with no change to their behaviour.
10. An install upgraded from v1.2 keeps its selected Air4 Pro.

---

## 5. Scope

**In:** Galaxy Buds Pro, Buds2, Buds2 Pro, Buds FE, Buds3, Buds3 Pro, Buds3 FE,
Buds Core, Buds4, Buds4 Pro. Uniform framing, uniform three-mode noise control.
Only Buds FE will be verified against hardware; the rest share the protocol and
are expected to work, and will be described that way — the same honesty the
README already applies to non-Air4-Pro SoundPEATS models.

**Deliberately out:**

- **Original Galaxy Buds (2019).** Different preamble (`0xFE`/`0xEE`) and a
  different header layout. One device family, one codec.
- **Galaxy Buds+ and Buds Live.** Share the framing but not the feature model:
  ambient sound is an on/off toggle plus a separate ANC flag, not a three-way
  mode. Supporting them means a second mode model in `ANCMode`, for devices
  nobody has asked for. They will be rejected with a clear message rather than
  half-working.
- **Adaptive noise mode (`mode = 3`).** Buds FE has no Adaptive, so the value
  cannot arrive from the target hardware. On a Buds2 Pro or Buds3 Pro left in
  Adaptive by the phone, the mode byte fails the `0…2` validation and the app
  keeps its last known mode instead of displaying something wrong. Adding it
  would mean a fourth `ANCMode` case, a per-device `supportedModes` list to keep
  the SoundPEATS picker three wide, a new `ANCModeAppEnum` case in a Shortcuts
  enum whose raw values are baked into users' saved shortcuts, and a wider
  segmented picker. Not worth it for a mode the target device does not have.
- **Case battery.** Arrives free at byte 7 of both status messages and is
  discarded. Adding it means a new field on `ModeSnapshot`, which is a
  cross-process `Codable` contract with a documented decode-compatibility
  caveat. Not paid for by one more number in the panel.
- **Everything else Galaxy Buds can do** — equaliser, touch options, Find My
  Earbuds, firmware updates, fit test, spatial audio. This app controls noise
  modes and reports battery. That is its whole thesis, and GalaxyBudsClient
  already exists for the rest.

Each exclusion is a value judgement, not a technical limit. Any of them is a
small follow-up on top of this architecture, which is the point of the
architecture.

---

## 6. Build changes

| File | Change |
| --- | --- |
| `project.yml` | `IOBluetooth.framework` as an `sdk` dependency of the `BudsCtl` target |
| `Package.swift` | none — IOBluetooth is in the macOS SDK and needs only `import IOBluetooth` |
| `App/BudsCtl.entitlements` | none — `com.apple.security.device.bluetooth` already present |
| `App/Info.plist` (via `project.yml`) | none — `NSBluetoothAlwaysUsageDescription` already present |
| `README.md` | supported-device table, and the same "verified on one device" honesty for Galaxy Buds |

`SWIFT_STRICT_CONCURRENCY: complete` stays on. IOBluetooth delegate callbacks
arrive on the main run loop, so `SamsungBackend` is `@MainActor` throughout,
exactly as `GaiaClient` is for CoreBluetooth's `queue: .main`.

---

## 7. Adding the next device family

The measure of whether this was worth doing:

1. Write `Sources/BudsKit/<Vendor>/<Vendor>Backend.swift` conforming to
   `EarbudsBackend`, plus whatever codec it needs.
2. Add one line to `Backends.all`.
3. Give it a `BackendPolicy` — empty `settleReads` and nil `batteryInterval` if
   the device pushes state, values if it does not.
4. Write frame tests. No hardware required.

`DeviceController`, `DeviceState`, `ModeSnapshot`, `StateBridge`, the four App
Intents, the Control Center widget, the menu bar panel and the hotkey are not
touched. If a fourth device requires touching any of them, the seam is in the
wrong place and should be moved rather than worked around.
