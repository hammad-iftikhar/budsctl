# Galaxy Buds Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Samsung Galaxy Buds (FE and the modern lineup) to BudsCtl alongside the SoundPEATS Air4 Pro, behind a backend abstraction that makes a third device family one new file plus one registry line.

**Architecture:** `DeviceController` stops speaking `GaiaCommand` and speaks `EarbudsBackend` — a small protocol carrying `DeviceEvent`s, `setMode`, three refresh hooks and a `BackendPolicy` describing device quirks. Two backends implement it: `GaiaBackend` (CoreBluetooth GATT, existing) and `SamsungBackend` (IOBluetooth RFCOMM/SPP, new). All of `DeviceController`'s existing concurrency machinery is preserved verbatim.

**Tech Stack:** Swift 6 (strict concurrency `complete`), macOS 26, swift-testing (`import Testing`, `@Test`/`#expect`/`#require`), CoreBluetooth, IOBluetooth, XcodeGen (`project.yml`), Swift Package Manager (`Package.swift`).

**Spec:** `docs/superpowers/specs/2026-09-07-galaxy-buds-support-design.md`

## Global Constraints

- Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`. No warnings introduced.
- macOS deployment target `26.0`.
- **No new package dependencies.** IOBluetooth ships in the macOS SDK.
- Tests use swift-testing, not XCTest. Run with `swift test`.
- **Baseline is 78 tests in 6 suites at branch start.** Running totals as tasks land: T1 → 84/7, T2 → 105/9, T5 → 116/10, T6 → 118/10, T7 → 132/11. Later tasks add no tests. Each task's brief states its own expected total; trust the count of `@Test` functions in the brief's code over any prose number. Every task must end with the full suite green. Task 6 is the only task that may edit existing test bodies, and it must not delete or weaken an assertion.
- **`ModeSnapshot`, `BridgeRequest`, the App Group keys, the Darwin notification name, and all four App Intents are frozen.** They are cross-process contracts; an installed appex older than the agent must keep working.
- `ANCMode` keeps exactly three cases (`normal = 0`, `anc = 1`, `passthrough = 2`). Adaptive mode (`3`) is out of scope and must be dropped on receipt, never displayed.
- Case battery is out of scope. Read and discarded.
- `EarbudsBackend.id` values (`"gaia"`, `"samsung"`) are persisted inside `DeviceRef`. Never change one.
- Backend-specific files live under `Sources/BudsKit/<Vendor>/`. Shared abstraction under `Sources/BudsKit/Device/`.
- Commit after every task. Conventional-commit prefixes (`feat:`, `refactor:`, `test:`, `docs:`, `fix:`).
- **No `Co-Authored-By` trailer and no AI attribution in commit messages or PR bodies.**
- Deliberate simplifications get a `ponytail:` comment naming the ceiling and the upgrade path, matching the existing house style.
- **`App/` and `Controls/` are Xcode-only targets — they are NOT in `Package.swift`, so `swift build` and `swift test` never compile them.** This matters: Task 4 deletes `GaiaClient.select(_:)`, `forgetDevice()` and `init(bridge:)`, all three of which `App/BudsCtlApp.swift` calls. **The Xcode app target is therefore knowingly broken from Task 4 until Task 9 rewires `AppModel`.** Tasks 4-8 verify with `swift build` + `swift test` only and must NOT patch `App/` to make Xcode happy — that is Task 9's job, and a throwaway shim would only be rewritten. Do not report this as BLOCKED.

## Two deliberate deviations from the spec

Both are simplifications found while writing the plan. They are called out so a reviewer does not read them as drift.

1. **`EarbudsBackend` has no `isLikelyMatch(_:)` method.** The spec put it on the protocol. It is instead a stored `let isLikelyMatch: Bool` on `DiscoveredDevice`, set by whichever backend found the device. Same behaviour, one less protocol member, and it keeps working when devices from two backends are merged into one list.
2. **`EarbudsBackend` has three refresh hooks, not two.** The spec listed `refreshMode()` and `refreshBattery()`. A third, `refresh()`, is needed because `DeviceController.refreshAfterConnect` means "read everything", which for GAIA includes firmware — a read neither of the other two names honestly covers. Each hook has exactly one caller, and keeping them separate is load-bearing rather than tidy:

| Hook | Called from | GAIA | Samsung |
| --- | --- | --- | --- |
| `refresh()` | `refreshAfterConnect` | firmware + mode + battery | **nothing** — state is already being pushed |
| `refreshMode()` | `refreshOnWake`, settle loop | `getMode` | reopen the channel to re-trigger the push |
| `refreshBattery()` | `refreshOnWake`, battery poll | both battery getters | nothing — battery is pushed |

`refreshOnWake` uses the narrow two rather than `refresh()`, which both restores its original behaviour exactly (it never read firmware) and prevents a reconnect loop: the only method that may tear down and rebuild a link is one nothing in the connect path calls.

---

## File Structure

| Path | Responsibility | Task |
| --- | --- | --- |
| `Sources/BudsKit/Device/EarbudsBackend.swift` | **Create.** `DeviceEvent`, `DeviceRef`, `BackendPolicy`, `EarbudsBackend`, `EventHub`, `Backends` registry. | 3, 9 |
| `Sources/BudsKit/Samsung/SppFrame.swift` | **Create.** Samsung wire codec: framing, CRC16, stream reassembly. No IOBluetooth. | 2 |
| `Sources/BudsKit/Samsung/SppEvents.swift` | **Create.** `SppFrame` → `[DeviceEvent]`, including the §2.5 validation. | 7 |
| `Sources/BudsKit/Samsung/SamsungBackend.swift` | **Create.** IOBluetooth RFCOMM link + `EarbudsBackend` conformance. | 8 |
| `Sources/BudsKit/Gaia/GaiaBackend.swift` | **Create.** `EarbudsBackend` over `GaiaTransport` + `GaiaClient`. | 5 |
| `Sources/BudsKit/DeviceController.swift` | **Modify.** `transport` → `backend`; `apply(GaiaFrame)` → `apply(DeviceEvent)`; policy-driven timers; `use(_:)`. | 6 |
| `Sources/BudsKit/GaiaClient.swift` | **Modify.** Split `start()` from `adopt(_:)`; `DiscoveredDevice.id` becomes `DeviceRef`; stop reading the bridge. | 4 |
| `Sources/BudsKit/StateBridge.swift` | **Modify.** `peripheralIdentifier: UUID?` → `deviceRef: DeviceRef?`, same defaults key. | 1 |
| `App/BudsCtlApp.swift` | **Modify.** `AppModel` owns every backend, merges discovery, routes adoption. | 9 |
| `App/SettingsView.swift` | **Modify.** Group the list by backend; compare `DeviceRef`. | 9 |
| `Sources/budsctl-cli/CLI.swift` | **Modify.** `samsung <mac>` probe subcommand; `discover` prints `DeviceRef`. | 4, 10 |
| `project.yml` | **Modify.** Link `IOBluetooth.framework`. | 8 |
| `Tests/BudsKitTests/DeviceRefTests.swift` | **Create.** | 1 |
| `Tests/BudsKitTests/SppFrameTests.swift` | **Create.** Codec + reassembly. | 2 |
| `Tests/BudsKitTests/SppEventsTests.swift` | **Create.** Offsets and validation. | 7 |
| `Tests/BudsKitTests/GaiaBackendTests.swift` | **Create.** Frame → event mapping. | 5 |
| `Tests/BudsKitTests/DeviceControllerTests.swift` | **Modify.** Construct via `GaiaBackend`; policy instead of controller properties. | 6 |
| `Tests/BudsKitTests/StateBridgeTests.swift` | **Modify.** `deviceRef` instead of `peripheralIdentifier`. | 1 |
| `README.md`, `docs/superpowers/manual-checklist.md` | **Modify.** | 11 |

Files untouched: `ANCMode.swift`, `DeviceState.swift`, `Intents.swift`, `GaiaFrame.swift`, `GaiaTransport.swift`, `Identifiers.swift`, `Timeout.swift`, `Controls/Controls.swift`, `App/PanelView.swift`.

---

### Task 1: `DeviceRef` and the persistence migration

Device identity has to carry which radio owns it: CoreBluetooth gives a `UUID`, IOBluetooth gives a MAC address string. This task adds the type and migrates `StateBridge`, with nothing else depending on it yet.

**Files:**
- Create: `Sources/BudsKit/Device/EarbudsBackend.swift`
- Create: `Tests/BudsKitTests/DeviceRefTests.swift`
- Modify: `Sources/BudsKit/StateBridge.swift` (the `Saved peripheral` section at the end, and `Key.peripheralIdentifier`)
- Modify: `Tests/BudsKitTests/StateBridgeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `DeviceRef(backend: String, id: String)`, `DeviceRef(persisted: String)`, `DeviceRef.persistedForm: String`, `DeviceRef.description`. `StateBridge.deviceRef: DeviceRef?` (get), `StateBridge.saveDeviceRef(_ ref: DeviceRef?)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/BudsKitTests/DeviceRefTests.swift`:

```swift
import Testing
import Foundation
@testable import BudsKit

@Suite("DeviceRef")
struct DeviceRefTests {

    @Test("round-trips through its persisted form")
    func roundTrip() {
        let ref = DeviceRef(backend: "samsung", id: "98-80-bb-41-1a-93")
        #expect(DeviceRef(persisted: ref.persistedForm) == ref)
    }

    @Test("persisted form is backend, colon, id")
    func persistedForm() {
        let ref = DeviceRef(backend: "gaia", id: "2B4A9F10-0000-0000-0000-000000000000")
        #expect(ref.persistedForm == "gaia:2B4A9F10-0000-0000-0000-000000000000")
        #expect(ref.description == ref.persistedForm)
    }

    // The v1.2 defaults value was a bare CBPeripheral UUID string. An install
    // upgrading from it must keep its selected Air4 Pro, not silently forget it.
    @Test("a bare UUID predates DeviceRef and belongs to the gaia backend")
    func migratesLegacyValue() {
        let ref = DeviceRef(persisted: "2B4A9F10-0000-0000-0000-000000000000")
        #expect(ref.backend == "gaia")
        #expect(ref.id == "2B4A9F10-0000-0000-0000-000000000000")
    }

    // IOBluetooth's addressString uses hyphens ("98-80-bb-41-1a-93"), never
    // colons, which is what makes ":" a safe separator. Verified against
    // IOBluetoothDevice.pairedDevices() on macOS 26.
    @Test("a MAC address survives parsing, because it has no colons")
    func macAddressHasNoColons() {
        let ref = DeviceRef(persisted: "samsung:98-80-bb-41-1a-93")
        #expect(ref.backend == "samsung")
        #expect(ref.id == "98-80-bb-41-1a-93")
    }

    @Test("an empty id parses without crashing")
    func emptyID() {
        let ref = DeviceRef(persisted: "samsung:")
        #expect(ref.backend == "samsung")
        #expect(ref.id == "")
    }

    @Test("is Codable, so it can travel in defaults or JSON")
    func codable() throws {
        let ref = DeviceRef(backend: "samsung", id: "98-80-bb-41-1a-93")
        let data = try JSONEncoder().encode(ref)
        #expect(try JSONDecoder().decode(DeviceRef.self, from: data) == ref)
    }
}
```

Append to `Tests/BudsKitTests/StateBridgeTests.swift`, inside the existing `@Suite("StateBridge")` struct. Use whatever helper that file already uses to build an isolated bridge; if it builds one inline, mirror that:

```swift
    @Test("a saved device ref survives a read back")
    func deviceRefRoundTrip() {
        let suite = "budsctl.test.\(UUID().uuidString)"
        let bridge = StateBridge(defaults: UserDefaults(suiteName: suite)!)
        #expect(bridge.deviceRef == nil)

        let ref = DeviceRef(backend: "samsung", id: "98-80-bb-41-1a-93")
        bridge.saveDeviceRef(ref)
        #expect(bridge.deviceRef == ref)

        bridge.saveDeviceRef(nil)
        #expect(bridge.deviceRef == nil)
    }

    @Test("a v1.2 bare-UUID value reads back as a gaia device")
    func deviceRefMigration() {
        let suite = "budsctl.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // Exactly what v1.2's savePeripheralIdentifier wrote.
        defaults.set("2B4A9F10-0000-0000-0000-000000000000", forKey: "peripheralIdentifier")
        let bridge = StateBridge(defaults: defaults)
        #expect(bridge.deviceRef == DeviceRef(backend: "gaia",
                                              id: "2B4A9F10-0000-0000-0000-000000000000"))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter DeviceRef 2>&1 | tail -20`
Expected: compile failure — `cannot find 'DeviceRef' in scope`.

- [ ] **Step 3: Create the type**

Create `Sources/BudsKit/Device/EarbudsBackend.swift`. This file gains more members in Tasks 3 and 9; for now it holds only `DeviceRef`.

```swift
import Foundation

/// Identifies a pair of earbuds across app launches, and says which backend
/// owns it.
///
/// Two backends, two kinds of identifier: CoreBluetooth hands out a
/// `CBPeripheral.identifier` (a `UUID`), IOBluetooth hands out a Bluetooth MAC
/// address. Neither is meaningful to the other, so the backend travels with
/// the id rather than being guessed from its shape.
public struct DeviceRef: Hashable, Codable, Sendable, CustomStringConvertible {

    /// The owning backend's `EarbudsBackend.id`. Persisted — never change an
    /// existing value, or every user's saved device becomes unreachable.
    public let backend: String

    /// Backend-private. A CoreBluetooth UUID string, or a MAC address.
    public let id: String

    public init(backend: String, id: String) {
        self.backend = backend
        self.id = id
    }

    /// `"<backend>:<id>"`.
    ///
    /// A colon is safe as the separator because neither id form contains one:
    /// a `UUID` string uses hyphens, and IOBluetooth's `addressString` is
    /// hyphen-separated too (`"98-80-bb-41-1a-93"`), not colon-separated as
    /// most Bluetooth tooling writes MACs.
    public var persistedForm: String { "\(backend):\(id)" }

    public var description: String { persistedForm }

    /// Parses `persistedForm`, and migrates what came before it.
    ///
    /// A value with no separator is a bare `CBPeripheral` UUID written by
    /// v1.2, which predates this type and had only one backend to belong to.
    /// Reading it as a GAIA device is what lets an upgraded install keep its
    /// selected Air4 Pro instead of silently forgetting it.
    public init(persisted: String) {
        guard let separator = persisted.firstIndex(of: ":") else {
            self.backend = Self.legacyBackendID
            self.id = persisted
            return
        }
        self.backend = String(persisted[persisted.startIndex..<separator])
        self.id = String(persisted[persisted.index(after: separator)...])
    }

    /// The only backend that existed before `DeviceRef` did.
    ///
    /// Spelled out rather than referencing `GaiaBackend.id` so this file has no
    /// dependency on a backend implementation, and so the migration cannot
    /// break if that backend is ever renamed — the *stored* value is history
    /// and does not change with the code.
    static let legacyBackendID = "gaia"
}
```

- [ ] **Step 4: Migrate `StateBridge`**

In `Sources/BudsKit/StateBridge.swift`, replace the whole `// MARK: - Saved peripheral` section:

```swift
    // MARK: - Saved device

    /// The device the user selected, or nil if none.
    ///
    /// Stored under the original `peripheralIdentifier` key rather than a
    /// renamed one. Renaming it would forget every existing user's device for
    /// no gain — the key is private to this type, and `DeviceRef(persisted:)`
    /// already understands both the old and the new value shape.
    public var deviceRef: DeviceRef? {
        guard let raw = defaults.string(forKey: Key.peripheralIdentifier),
              !raw.isEmpty
        else { return nil }
        return DeviceRef(persisted: raw)
    }

    public func saveDeviceRef(_ ref: DeviceRef?) {
        if let ref {
            defaults.set(ref.persistedForm, forKey: Key.peripheralIdentifier)
        } else {
            defaults.removeObject(forKey: Key.peripheralIdentifier)
        }
    }
```

Leave `Key.peripheralIdentifier` spelled as it is, and add a comment above it:

```swift
        /// Holds a `DeviceRef.persistedForm`. Named for what v1.2 stored here
        /// (a bare peripheral UUID); kept so upgrades do not lose the device.
        static let peripheralIdentifier = "peripheralIdentifier"
```

This deletes `peripheralIdentifier: UUID?` and `savePeripheralIdentifier(_:)`, which `GaiaClient` and `CLI` still call — they will not compile until Task 4. That is expected and is why Step 5 filters the test run.

- [ ] **Step 5: Run the new tests to verify they pass**

The library target does not build yet (`GaiaClient` and `CLI` still call the removed API), so run only the type's own tests by building the test target after temporarily satisfying the callers. Do it properly instead: complete the two call-site fixes now, since they are two lines each.

In `Sources/BudsKit/GaiaClient.swift`, inside `attemptConnect()`:

```swift
        guard let ref = bridge.deviceRef, ref.backend == "gaia",
              let identifier = UUID(uuidString: ref.id)
        else {
            report(.notConfigured)
            return
        }
```

and replace both `bridge.savePeripheralIdentifier(nil)` calls with `bridge.saveDeviceRef(nil)`, and in `select(_:)` replace `bridge.savePeripheralIdentifier(device.id)` with:

```swift
        bridge.saveDeviceRef(DeviceRef(backend: "gaia", id: device.id.uuidString))
```

`DiscoveredDevice.id` is still a `UUID` at this point; Task 4 changes that.

Run: `swift test 2>&1 | tail -8`
Expected: PASS, 85 tests in 7 suites (78 baseline + 6 `DeviceRef` + 2 `StateBridge`, minus one if the existing suite already had a peripheral-identifier test that you replaced).

- [ ] **Step 6: Commit**

```bash
git add Sources/BudsKit/Device/EarbudsBackend.swift Sources/BudsKit/StateBridge.swift \
        Sources/BudsKit/GaiaClient.swift Tests/BudsKitTests/DeviceRefTests.swift \
        Tests/BudsKitTests/StateBridgeTests.swift
git commit -m "feat: add DeviceRef so a saved device carries its backend"
```

---

### Task 2: Samsung wire codec and stream reassembly

The Samsung protocol's framing, checksum and — the part that has no analogue on the BLE side — reassembly of a byte stream into frames. Pure bytes in, frames out: no IOBluetooth, no radio, fully unit-testable. This is the trickiest logic in the change, so it gets the largest test surface.

**Files:**
- Create: `Sources/BudsKit/Samsung/SppFrame.swift`
- Create: `Tests/BudsKitTests/SppFrameTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `SppMessageID` (enum, `UInt8` raw), `SppFrame(rawID: UInt8, payload: [UInt8], isFragment: Bool)`, `SppFrame.id: SppMessageID?`, `SppFrame.crc16(_ bytes: [UInt8]) -> UInt16`, `SppFrame.encode(_ id: SppMessageID, _ payload: [UInt8]) -> Data`, `SppFrame.decode(_ bytes: [UInt8]) -> SppFrame?`, `SppReassembler` with `mutating func append(_ chunk: Data) -> [SppFrame]`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/BudsKitTests/SppFrameTests.swift`:

```swift
import Testing
import Foundation
@testable import BudsKit

@Suite("SppFrame codec")
struct SppFrameCodecTests {

    /// Verbatim from GalaxyBudsClient's `Crc16.cs` worked example: the payload
    /// bytes and, as the last two, the checksum the reference documents for
    /// them. Pins our implementation against a third-party value rather than
    /// against itself.
    @Test("CRC16 matches the reference implementation's documented vector")
    func crcReferenceVector() {
        let data: [UInt8] = [0x61, 0x02, 0x00, 0x4B, 0x5F, 0x01, 0x00, 0x00,
                             0x00, 0x01, 0x05, 0x00, 0x02, 0x00, 0x13]
        // The reference writes the checksum little-endian, as bytes 0F F3.
        #expect(SppFrame.crc16(data) == 0xF30F)
    }

    @Test("CRC16 of nothing is zero, the documented initial value")
    func crcEmpty() {
        #expect(SppFrame.crc16([]) == 0)
    }

    @Test("encodes a set-mode frame exactly")
    func encodeNoiseControls() {
        // size = 1 (id) + 1 (payload) + 2 (crc) = 4
        let data = SppFrame.encode(.noiseControls, [0x01])
        let bytes = [UInt8](data)
        #expect(bytes[0] == 0xFD)                     // preamble
        #expect(bytes[1] == 0x04 && bytes[2] == 0x00) // header, little-endian
        #expect(bytes[3] == 120)                      // NOISE_CONTROLS
        #expect(bytes[4] == 0x01)                     // ANC
        let crc = SppFrame.crc16([120, 0x01])
        #expect(bytes[5] == UInt8(crc & 0xFF))
        #expect(bytes[6] == UInt8(crc >> 8))
        #expect(bytes[7] == 0xDD)                     // postamble
        #expect(bytes.count == 8)
    }

    @Test("encodes a payload-free frame")
    func encodeNoPayload() {
        let bytes = [UInt8](SppFrame.encode(.managerInfo))
        #expect(bytes[1] == 0x03 && bytes[2] == 0x00) // size = id + crc
        #expect(bytes.count == 7)
    }

    @Test("every message we send round-trips")
    func roundTrip() throws {
        let cases: [(SppMessageID, [UInt8])] = [
            (.noiseControls, [0x00]),
            (.noiseControls, [0x02]),
            (.managerInfo, [0x01, 0x02, 0x22]),
        ]
        for (id, payload) in cases {
            let frame = try #require(SppFrame.decode([UInt8](SppFrame.encode(id, payload))))
            #expect(frame.id == id)
            #expect(frame.payload == payload)
            #expect(frame.isFragment == false)
        }
    }

    @Test("decodes a frame whose id this app does not handle, keeping the raw id")
    func decodeUnknownID() throws {
        // id 0x2A is not in SppMessageID. The codec must still parse it, so the
        // reassembler can consume its bytes and the CLI probe can print it.
        var bytes: [UInt8] = [0xFD, 0x03, 0x00, 0x2A]
        let crc = SppFrame.crc16([0x2A])
        bytes += [UInt8(crc & 0xFF), UInt8(crc >> 8), 0xDD]
        let frame = try #require(SppFrame.decode(bytes))
        #expect(frame.rawID == 0x2A)
        #expect(frame.id == nil)
        #expect(frame.payload.isEmpty)
    }

    @Test("rejects a frame whose CRC does not match")
    func rejectsBadCRC() {
        var bytes = [UInt8](SppFrame.encode(.noiseControls, [0x01]))
        bytes[4] ^= 0x01     // flip a payload bit, leave the CRC alone
        #expect(SppFrame.decode(bytes) == nil)
    }

    @Test("rejects a wrong preamble or postamble")
    func rejectsBadDelimiters() {
        var badPreamble = [UInt8](SppFrame.encode(.noiseControls, [0x01]))
        badPreamble[0] = 0xFE
        #expect(SppFrame.decode(badPreamble) == nil)

        var badPostamble = [UInt8](SppFrame.encode(.noiseControls, [0x01]))
        badPostamble[badPostamble.count - 1] = 0xEE
        #expect(SppFrame.decode(badPostamble) == nil)
    }

    @Test("rejects a frame too short to hold an id and a checksum")
    func rejectsRunt() {
        #expect(SppFrame.decode([0xFD, 0x00, 0x00, 0xDD]) == nil)
        #expect(SppFrame.decode([0xFD]) == nil)
        #expect(SppFrame.decode([]) == nil)
    }

    @Test("reads the fragment bit without treating it as size")
    func decodesFragmentFlag() throws {
        var bytes = [UInt8](SppFrame.encode(.noiseControls, [0x01]))
        bytes[2] |= 0x20     // bit 13 of the little-endian header
        let frame = try #require(SppFrame.decode(bytes))
        #expect(frame.isFragment)
        #expect(frame.id == .noiseControls)
    }

    // GalaxyBudsClient sets bit 12 for Response on encode and reads it as
    // Request on decode — an asymmetry in the reference. We neither set nor
    // read it, so a frame with it set must decode identically.
    @Test("ignores the type bit entirely")
    func ignoresTypeBit() throws {
        var bytes = [UInt8](SppFrame.encode(.noiseControls, [0x02]))
        bytes[2] |= 0x10     // bit 12
        let frame = try #require(SppFrame.decode(bytes))
        #expect(frame.id == .noiseControls)
        #expect(frame.payload == [0x02])
        #expect(frame.isFragment == false)
    }
}

@Suite("SppReassembler")
struct SppReassemblerTests {

    private func frame(_ id: SppMessageID, _ payload: [UInt8] = []) -> [UInt8] {
        [UInt8](SppFrame.encode(id, payload))
    }

    @Test("a whole frame in one chunk yields one frame")
    func singleChunk() {
        var reassembler = SppReassembler()
        let frames = reassembler.append(Data(frame(.noiseControls, [0x01])))
        #expect(frames.count == 1)
        #expect(frames.first?.id == .noiseControls)
    }

    @Test("a frame split across three chunks yields one frame, once")
    func splitFrame() {
        var reassembler = SppReassembler()
        let bytes = frame(.noiseControlsUpdate, [0x02])
        #expect(reassembler.append(Data(bytes[0..<2])).isEmpty)
        #expect(reassembler.append(Data(bytes[2..<5])).isEmpty)
        let frames = reassembler.append(Data(bytes[5...]))
        #expect(frames.count == 1)
        #expect(frames.first?.payload == [0x02])
    }

    @Test("a byte-at-a-time delivery still yields exactly one frame")
    func byteAtATime() {
        var reassembler = SppReassembler()
        let bytes = frame(.noiseControlsUpdate, [0x01])
        var total: [SppFrame] = []
        for byte in bytes { total += reassembler.append(Data([byte])) }
        #expect(total.count == 1)
        #expect(total.first?.payload == [0x01])
    }

    @Test("three frames coalesced into one chunk yield three frames, in order")
    func coalescedFrames() {
        var reassembler = SppReassembler()
        let bytes = frame(.noiseControlsUpdate, [0x00])
            + frame(.noiseControlsUpdate, [0x01])
            + frame(.noiseControlsUpdate, [0x02])
        let frames = reassembler.append(Data(bytes))
        #expect(frames.count == 3)
        #expect(frames.map(\.payload) == [[0x00], [0x01], [0x02]])
    }

    @Test("leading garbage is skipped and the frame behind it is found")
    func resyncsAfterGarbage() {
        var reassembler = SppReassembler()
        let frames = reassembler.append(Data([0x00, 0x11, 0x22] + frame(.noiseControls, [0x01])))
        #expect(frames.count == 1)
        #expect(frames.first?.id == .noiseControls)
    }

    /// The important one: a corrupt frame must not desynchronise the stream and
    /// swallow everything after it.
    @Test("a bad-CRC frame is dropped and the next good frame is still decoded")
    func resyncsAfterCorruptFrame() {
        var reassembler = SppReassembler()
        var corrupt = frame(.noiseControlsUpdate, [0x01])
        corrupt[4] ^= 0xFF
        let frames = reassembler.append(Data(corrupt + frame(.noiseControlsUpdate, [0x02])))
        #expect(frames.count == 1)
        #expect(frames.first?.payload == [0x02])
    }

    @Test("a frame claiming an impossible size is dropped, not waited on forever")
    func dropsOversizedClaim() {
        var reassembler = SppReassembler()
        // size field claims 0x3FF bytes that will never arrive, then a real frame.
        let liar: [UInt8] = [0xFD, 0xFF, 0x03, 0x77]
        _ = reassembler.append(Data(liar))
        let frames = reassembler.append(Data(frame(.noiseControlsUpdate, [0x01])))
        #expect(frames.count == 1)
        #expect(frames.first?.payload == [0x01])
    }

    @Test("fragmented frames are consumed but never surfaced")
    func dropsFragments() {
        var reassembler = SppReassembler()
        var fragment = frame(.noiseControlsUpdate, [0x01])
        fragment[2] |= 0x20
        let frames = reassembler.append(Data(fragment + frame(.noiseControlsUpdate, [0x02])))
        #expect(frames.count == 1, "the fragment is dropped, the frame after it is not")
        #expect(frames.first?.payload == [0x02])
    }

    @Test("the buffer is bounded when nothing valid ever arrives")
    func boundsTheBuffer() {
        var reassembler = SppReassembler()
        for _ in 0..<16 {
            _ = reassembler.append(Data(repeating: 0xFD, count: 1024))
        }
        #expect(reassembler.bufferedByteCount <= SppReassembler.bufferLimit)
    }

    @Test("a frame still parses after the buffer was cleared for overflow")
    func recoversAfterOverflow() {
        var reassembler = SppReassembler()
        for _ in 0..<16 { _ = reassembler.append(Data(repeating: 0xFD, count: 1024)) }
        let frames = reassembler.append(Data(frame(.noiseControls, [0x00])))
        #expect(frames.count == 1)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter Spp 2>&1 | tail -20`
Expected: compile failure — `cannot find 'SppFrame' in scope`.

- [ ] **Step 3: Write the codec**

Create `Sources/BudsKit/Samsung/SppFrame.swift`:

```swift
import Foundation

/// Samsung SPP message IDs, decimal to match GalaxyBudsClient's naming.
///
/// Only the six this app needs. The buds push plenty of others; those decode
/// structurally (see `SppFrame.rawID`) and are ignored, rather than being
/// enumerated here for no reason.
public enum SppMessageID: UInt8, Sendable, CaseIterable {
    /// Reply to a set. Payload: acked message id, then the value applied.
    case acknowledgement = 66
    /// Pushed on battery or wear change.
    case statusUpdated = 96
    /// Pushed when the SPP channel opens. The only source of the mode at
    /// connect time.
    case extendedStatusUpdated = 97
    /// Pushed on every mode change, from any source.
    case noiseControlsUpdate = 119
    /// Sent to change the mode. Payload: the mode byte.
    case noiseControls = 120
    /// Sent on connect to announce ourselves.
    case managerInfo = 136
}

/// One decoded Samsung SPP message.
public struct SppFrame: Equatable, Sendable {

    /// The id byte as it arrived, known or not.
    public let rawID: UInt8
    public let payload: [UInt8]
    /// Bit 13 of the header. Only firmware images and core dumps are
    /// fragmented, so callers drop these.
    public let isFragment: Bool

    /// nil for a message this app does not handle.
    public var id: SppMessageID? { SppMessageID(rawValue: rawID) }

    public init(rawID: UInt8, payload: [UInt8], isFragment: Bool = false) {
        self.rawID = rawID
        self.payload = payload
        self.isFragment = isFragment
    }

    // MARK: - Framing constants

    static let preamble: UInt8 = 0xFD
    static let postamble: UInt8 = 0xDD
    /// `size` counts the id byte plus the payload plus the two CRC bytes.
    static let sizeOverhead = 3
    /// preamble + header(2) + id + crc(2) + postamble.
    static let minimumSize = 7
    /// Bits 0-9 of the header.
    static let sizeMask: UInt16 = 0x03FF
    /// Bit 13.
    static let fragmentBit: UInt16 = 0x2000

    /// Total wire length of the frame at the front of `bytes`.
    ///
    /// Only valid once `decode` has accepted that frame — it re-reads the
    /// header rather than re-validating it, so the reassembler can consume
    /// exactly the right number of bytes without parsing twice.
    static func frameLength(_ bytes: [UInt8]) -> Int {
        4 + Int((UInt16(bytes[1]) | UInt16(bytes[2]) << 8) & sizeMask)
    }

    // MARK: - Checksum

    /// CRC16-CCITT/XMODEM: polynomial 0x1021, initial value 0x0000, MSB-first,
    /// no reflection, no final XOR. Computed over `id ‖ payload`.
    ///
    /// ponytail: bitwise, not the reference implementation's 256-entry table.
    /// Six lines beats a table for messages that are never more than a few
    /// dozen bytes; swap in a table if a profile ever says this matters.
    public static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    // MARK: - Encode

    /// `FD | size_lo size_hi | id | payload… | crc_lo crc_hi | DD`
    ///
    /// Bit 12 (type) is left clear: everything this app sends is a request.
    public static func encode(_ id: SppMessageID, _ payload: [UInt8] = []) -> Data {
        let size = UInt16(sizeOverhead + payload.count)
        let crc = crc16([id.rawValue] + payload)
        var bytes: [UInt8] = [preamble, UInt8(size & 0xFF), UInt8(size >> 8), id.rawValue]
        bytes += payload
        bytes += [UInt8(crc & 0xFF), UInt8(crc >> 8), postamble]
        return Data(bytes)
    }

    // MARK: - Decode

    /// Decodes exactly one frame from the front of `bytes`.
    ///
    /// Returns nil for anything malformed — wrong delimiters, a size that does
    /// not match the buffer, or a failed checksum. A nil means "not a frame",
    /// never "crash": this is a reverse-engineered protocol on a channel the
    /// buds share with their own chatter.
    public static func decode(_ bytes: [UInt8]) -> SppFrame? {
        guard bytes.count >= minimumSize else { return nil }
        guard bytes[0] == preamble else { return nil }

        let header = UInt16(bytes[1]) | UInt16(bytes[2]) << 8
        let size = Int(header & sizeMask)
        guard size >= sizeOverhead else { return nil }

        let total = 4 + size          // preamble + header(2) + size + postamble
        guard bytes.count >= total, bytes[total - 1] == postamble else { return nil }

        let rawID = bytes[3]
        let payloadEnd = total - 3    // before crc(2) + postamble
        let payload = Array(bytes[4..<payloadEnd])

        // Little-endian, matching what `encode` writes.
        let received = UInt16(bytes[payloadEnd]) | UInt16(bytes[payloadEnd + 1]) << 8
        guard crc16([rawID] + payload) == received else { return nil }

        return SppFrame(
            rawID: rawID,
            payload: payload,
            isFragment: header & fragmentBit != 0
        )
    }
}

/// Turns RFCOMM's byte stream into frames.
///
/// Needed because `rfcommChannelData` delivers arbitrary chunks — a frame can
/// arrive split across three callbacks, or three frames can arrive in one.
/// GATT notifications on the BLE side are discrete, so `GaiaFrame` needs
/// nothing like this.
public struct SppReassembler: Sendable {

    /// ponytail: a flat array with `removeFirst`, not a ring buffer. Frames are
    /// under a few dozen bytes and arrive a handful at a time; reach for a ring
    /// buffer only if a profile ever shows this copying.
    private var buffer: [UInt8] = []

    /// A control channel this far behind is not going to recover by buffering
    /// more, and an unbounded buffer on a byte stream is how a hung peer
    /// becomes a memory leak.
    public static let bufferLimit = 4096

    public init() {}

    /// For tests and diagnostics.
    public var bufferedByteCount: Int { buffer.count }

    /// Appends a chunk and returns every complete, valid, non-fragment frame it
    /// completed. Incomplete tails stay buffered for the next call.
    public mutating func append(_ chunk: Data) -> [SppFrame] {
        buffer.append(contentsOf: chunk)
        var frames: [SppFrame] = []

        parse: while true {
            // Discard anything before the first preamble.
            guard let start = buffer.firstIndex(of: SppFrame.preamble) else {
                buffer.removeAll()
                break parse
            }
            if start > 0 { buffer.removeFirst(start) }

            guard buffer.count >= SppFrame.minimumSize else { break parse }

            if let frame = SppFrame.decode(buffer) {
                buffer.removeFirst(SppFrame.frameLength(buffer))
                // Fragments are consumed so the stream stays aligned, but never
                // surfaced: they only ever carry firmware images and core dumps.
                if !frame.isFragment { frames.append(frame) }
                continue parse
            }

            // The front will not decode. Two possibilities, and they look
            // identical from here: a real frame that has not finished
            // arriving, or garbage whose size field is lying to us.
            //
            // Tell them apart by proof, not by a heuristic on the claimed
            // size. Resync only if a *valid* frame can be found at a later
            // preamble; otherwise keep waiting for more bytes.
            //
            // A size cap was tried first and rejected: adjacent garbage
            // trivially produces a claim just under any fixed bound (a pair of
            // stray 0xFD bytes claims 253, sliding under a 256 cap), so the
            // cap only moves the stall rather than removing it.
            //
            // ponytail: O(n²) over adversarial garbage, bounded by
            // `bufferLimit` below — 4 KB on a channel that carries a few dozen
            // bytes a minute. Index-based decoding would remove the slice copy
            // if a profile ever shows it.
            var probe = 1
            var resyncTo: Int?
            while probe < buffer.count {
                guard let next = buffer[probe...].firstIndex(of: SppFrame.preamble) else { break }
                if SppFrame.decode(Array(buffer[next...])) != nil {
                    resyncTo = next
                    break
                }
                probe = next + 1
            }
            guard let resyncTo else { break parse }
            buffer.removeFirst(resyncTo)
        }

        // Checked after parsing, never before: clearing first would throw away
        // bytes that were about to complete a frame.
        if buffer.count > Self.bufferLimit { buffer.removeAll() }
        return frames
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter Spp 2>&1 | tail -10`
Expected: PASS, **21 tests** across the two new suites (11 codec + 10 reassembler). Running total: **105 tests / 9 suites**.

Then the whole suite: `swift test 2>&1 | tail -5` — expect all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/BudsKit/Samsung/SppFrame.swift Tests/BudsKitTests/SppFrameTests.swift
git commit -m "feat: add Samsung SPP frame codec and stream reassembler"
```

---

### Task 3: The `EarbudsBackend` contract

Declarations only, plus the fan-out helper both backends need. No behaviour, so nothing to test beyond compiling — the contract is exercised by Tasks 5 and 6.

**Files:**
- Modify: `Sources/BudsKit/Device/EarbudsBackend.swift` (append; `DeviceRef` from Task 1 stays)

**Interfaces:**
- Consumes: `DeviceRef` (Task 1), `ANCMode`, `ConnectionState`, `DiscoveredDevice`.
- Produces: `DeviceEvent` (cases `.mode(ANCMode)`, `.batteryLeft(Int?)`, `.batteryRight(Int?)`, `.firmware(String)`), `BackendPolicy(settleReads: [Duration], batteryInterval: Duration?)`, `EarbudsBackend` protocol, `EventHub` with `stream() -> AsyncStream<DeviceEvent>` and `yield(_:)`.

- [ ] **Step 1: Append the contract**

Add to `Sources/BudsKit/Device/EarbudsBackend.swift`:

```swift
/// One thing a device told us.
///
/// Deliberately at the altitude of what the app needs, not of the wire. GAIA
/// has per-side battery *getters*; Samsung *pushes* one combined status
/// message. A shared command vocabulary would have to invent commands one side
/// cannot honour, so the shared vocabulary is the answers instead.
///
/// Left and right are separate cases rather than one `battery(left:right:)`
/// so nil unambiguously means "unknown", never "no news about this side".
public enum DeviceEvent: Sendable, Equatable {
    case mode(ANCMode)
    case batteryLeft(Int?)
    case batteryRight(Int?)
    case firmware(String)
}

/// Device quirks `DeviceController` cannot discover for itself.
///
/// Not speculative configuration: both fields differ between the two shipping
/// devices. The Air4 Pro serves unreliable reads for ~45 s after connect and
/// never announces its battery, so it needs both. Galaxy Buds push their full
/// state on connect and their battery on change, so it needs neither.
public struct BackendPolicy: Sendable {

    /// Offsets from the moment the connection landed at which to re-read the
    /// mode. Empty means the device pushes its state and there is nothing to
    /// settle — which is what switches off `DeviceController.settleMode`
    /// entirely, loader included.
    public var settleReads: [Duration]

    /// How often to poll the battery while connected, or nil when the device
    /// pushes battery updates itself.
    public var batteryInterval: Duration?

    public init(settleReads: [Duration] = [], batteryInterval: Duration? = nil) {
        self.settleReads = settleReads
        self.batteryInterval = batteryInterval
    }
}

/// One family of earbuds: its radio, its wire format, and its reconnect
/// strategy. `DeviceController` talks to nothing else.
///
/// Adding a device family means one conformance and one line in
/// `Backends.all`. If a new family needs `DeviceController`, `DeviceState`,
/// `ModeSnapshot` or the intents changed, this seam is in the wrong place and
/// should be moved rather than worked around.
@MainActor
public protocol EarbudsBackend: AnyObject {

    /// Stable key, stored inside every `DeviceRef`. **Never change one** — it
    /// is how a saved device finds its way back to this backend after a
    /// restart.
    static var id: String { get }

    /// Vendor name, for the Settings section header.
    static var displayName: String { get }

    var onConnectionChange: (@MainActor (ConnectionState) -> Void)? { get set }
    var onDiscoveryUpdate: (@MainActor ([DiscoveredDevice]) -> Void)? { get set }

    /// Bring the radio up and make discovery work. Must **not** connect: every
    /// backend is started so both brands show up in Settings, while only the
    /// one holding the user's saved device is adopted.
    func start()

    /// Devices already reachable, without scanning. Cheap enough to call every
    /// time Settings opens.
    func connectedDevices() -> [DiscoveredDevice]

    func startScan()
    func stopScan()

    /// Take ownership of this device and keep it connected across
    /// case-in/case-out cycles.
    func adopt(_ ref: DeviceRef)

    /// Drop the link and stop reporting connection state. Must leave nothing
    /// behind that can still mutate state — a de-selected device's
    /// notifications reaching `DeviceController` is a bug with history on the
    /// GAIA side.
    func release()

    /// A **fresh** stream per caller.
    ///
    /// `DeviceController` keeps one long-lived stream while `performSet` opens
    /// short-lived ones; a single shared stream would let one consumer steal
    /// another's event. Same contract, and the same reason, as
    /// `GaiaTransport.frames()`.
    func events() -> AsyncStream<DeviceEvent>

    func setMode(_ mode: ANCMode) async throws

    /// Read everything the device can tell us. Called once per connection and
    /// again on wake. A device that pushes its state implements this as
    /// whatever re-triggers that push.
    func refresh() async

    /// Re-read just the mode. Called only by the settle loop, so only reachable
    /// when `policy.settleReads` is non-empty.
    func refreshMode() async

    /// Re-read just the battery. Called only by the battery poll, so only
    /// reachable when `policy.batteryInterval` is non-nil.
    func refreshBattery() async

    var policy: BackendPolicy { get }
}

/// Fans one device's events out to every concurrent waiter.
///
/// Identical in shape and purpose to `FrameHub` in `GaiaClient.swift`, one
/// level up: that one fans out `GaiaFrame`, this one fans out `DeviceEvent`.
/// Both backends need it, so it lives here.
public final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<DeviceEvent>.Continuation] = [:]

    public init() {}

    public func stream() -> AsyncStream<DeviceEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    public func yield(_ event: DeviceEvent) {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets { continuation.yield(event) }
    }
}
```

- [ ] **Step 2: Verify it compiles and the suite is untouched**

Run: `swift build 2>&1 | tail -5`
Expected: no errors, no warnings.

Run: `swift test 2>&1 | tail -5`
Expected: same count as after Task 2, all passing.

- [ ] **Step 3: Commit**

```bash
git add Sources/BudsKit/Device/EarbudsBackend.swift
git commit -m "feat: add the EarbudsBackend contract, DeviceEvent and BackendPolicy"
```

---

### Task 4: Split `GaiaClient`'s radio start from its connect

`GaiaClient.start()` currently brings the radio up *and* connects to whatever the bridge has saved, reading `bridge.peripheralIdentifier` itself. With two backends, the decision of which device to adopt belongs to `AppModel`, and every backend must be startable without connecting. This task also moves `DiscoveredDevice` onto `DeviceRef`.

**Files:**
- Modify: `Sources/BudsKit/GaiaClient.swift` (`DiscoveredDevice`, `attemptConnect`, `start`, `select`, `forgetDevice`, `connectedDevices`, `record`, `centralManagerDidUpdateState`)
- Modify: `Sources/budsctl-cli/CLI.swift` (`discover`, `Runner.waitForReady`)

**Interfaces:**
- Consumes: `DeviceRef` (Task 1).
- Produces: `DiscoveredDevice(id: DeviceRef, name: String, isLikelyMatch: Bool)`. `GaiaClient.start()` (radio only), `GaiaClient.adopt(_ ref: DeviceRef)`, `GaiaClient.release()`. `GaiaClient.select(_:)` and `forgetDevice()` are **removed** — adoption and persistence move to `AppModel` in Task 9.

- [ ] **Step 1: Change `DiscoveredDevice`**

In `Sources/BudsKit/GaiaClient.swift`, replace the type:

```swift
public struct DiscoveredDevice: Identifiable, Sendable, Equatable {
    public let id: DeviceRef
    public let name: String

    /// Whether this looks like a device the finding backend can actually
    /// drive. Filters the *scan* list only — never the connected list, where
    /// the lookup has already narrowed things down and filtering further would
    /// only hide the device you are looking for.
    ///
    /// Stored rather than computed: with two backends merging into one list, a
    /// single global name test cannot answer it, and the backend that found the
    /// device already knows.
    public let isLikelyMatch: Bool

    public init(id: DeviceRef, name: String, isLikelyMatch: Bool) {
        self.id = id
        self.name = name
        self.isLikelyMatch = isLikelyMatch
    }
}
```

- [ ] **Step 2: Split start from connect**

In the same file, replace `start()` and `attemptConnect()`:

```swift
    /// Bring the radio up. Safe to call before Bluetooth is powered on — the
    /// state callback drives the rest.
    ///
    /// Does **not** connect. With more than one backend in the app, every
    /// backend is started so both brands appear in Settings, but only the one
    /// owning the user's saved device is adopted. `AppModel` decides that; this
    /// type no longer reads the bridge to decide it for itself.
    public func start() {
        centralManagerDidUpdateState(central)
    }

    /// Adopt a device and keep it connected. Idempotent for the same ref.
    public func adopt(_ ref: DeviceRef) {
        adopted = ref
        attemptConnect()
    }

    /// Drop the link and stop reporting.
    public func release() {
        adopted = nil
        releasePeripheral()
    }

    private func attemptConnect() {
        guard let adopted, let identifier = UUID(uuidString: adopted.id) else {
            report(.notConfigured)
            return
        }
        let known = central.retrievePeripherals(withIdentifiers: [identifier])
        guard let found = known.first else {
            // The identifier is dead — the user re-paired. Do not spin on it.
            // Reported as unconfigured; clearing the *saved* device is
            // AppModel's job now, since only it owns persistence.
            self.adopted = nil
            report(.notConfigured)
            return
        }
        // Selecting a different device must release the old one. Otherwise
        // device A stays connected, subscribed and delegated to us, and its
        // unsolicited 0x0310 frames keep overwriting state for a device the
        // user explicitly de-selected — while its LE link never closes.
        // `!==` so re-connecting the same peripheral does not cancel the link
        // we are about to use.
        if peripheral !== found { releasePeripheral() }
        peripheral = found
        found.delegate = self
        deviceName = found.name
        report(.connecting)
        // Stays pending indefinitely if the buds are in the case. This is the
        // auto-reconnect mechanism, not a failure.
        central.connect(found, options: nil)
    }
```

Add the stored property next to `peripheral`:

```swift
    /// The device `AppModel` told us to keep connected, or nil.
    private var adopted: DeviceRef?
```

Delete `select(_:)` and `forgetDevice()`. In `centralManagerDidUpdateState`, guard the connect on having something to adopt:

```swift
        if adopted != nil { attemptConnect() }
        // A scan asked for before the radio was ready starts now, not never.
        if wantsScan { beginScan() }
```

- [ ] **Step 3: Construct `DiscoveredDevice` with a ref**

`GaiaClient` needs the backend id to build refs. Reference `GaiaBackend.id` once Task 5 exists; for now add a file-private constant and a note:

```swift
    /// The backend id these devices belong to. Matches `GaiaBackend.id`, which
    /// is declared in the file that adapts this client to `EarbudsBackend`.
    private static let backendID = "gaia"

    private func device(_ peripheral: CBPeripheral, name: String) -> DiscoveredDevice {
        DiscoveredDevice(
            id: DeviceRef(backend: Self.backendID, id: peripheral.identifier.uuidString),
            name: name,
            isLikelyMatch: name.uppercased().contains("SOUNDPEATS")
        )
    }
```

In `connectedDevices()`, replace the loop body:

```swift
        var found: [DeviceRef: DiscoveredDevice] = [:]
        for peripheral in central.retrieveConnectedPeripherals(withServices: services) {
            guard let name = peripheral.name, !name.isEmpty else { continue }
            let entry = device(peripheral, name: name)
            found[entry.id] = entry
        }
        return found.values.sorted { $0.name < $1.name }
```

In `record(_:name:)`:

```swift
    private func record(_ peripheral: CBPeripheral, name: String?) {
        guard let name, !name.isEmpty else { return }
        let entry = device(peripheral, name: name)
        guard discovered[entry.id] != entry else { return }
        discovered[entry.id] = entry
        onDiscoveryUpdate?(discovered.values.sorted { $0.name < $1.name })
    }
```

and change the `discovered` declaration to `private var discovered: [DeviceRef: DiscoveredDevice] = [:]`.

In `beginScan()`, `Dictionary(uniqueKeysWithValues:)` still works unchanged.

**Remove `GaiaClient`'s `bridge` dependency entirely.** After the changes above, nothing in the file uses it: `attemptConnect` reads `adopted` instead of `bridge.deviceRef`, and `select`/`forgetDevice` — the only other users — are deleted. So delete the `bridge` stored property and the `init(bridge:)` parameter, leaving `GaiaClient()`, and update `CLI.swift`'s `lazy var client = GaiaClient(bridge: bridge)` to `GaiaClient()`.

This is settled, not conditional: Task 9 assumes `GaiaClient()` takes no arguments. Do not leave the parameter in place "just in case".

- [ ] **Step 4: Fix the CLI**

In `Sources/budsctl-cli/CLI.swift`, `Runner.waitForReady` calls `client.start()` which no longer connects. Add adoption:

```swift
    func waitForReady(timeout: Duration = .seconds(20)) async throws {
        let (states, continuation) = AsyncStream<ConnectionState>.makeStream()
        client.onConnectionChange = { state in
            print("[connection] \(state.label)")
            continuation.yield(state)
        }
        defer { continuation.finish() }
        client.start()
        guard let ref = bridge.deviceRef, ref.backend == "gaia" else {
            throw CLIError.message("No device saved. Run `budsctl-cli discover` first.")
        }
        client.adopt(ref)
        // …rest unchanged…
```

In `discover()`, `select` is gone, so save and adopt explicitly:

```swift
        runner.bridge.saveDeviceRef(seen[index].id)
        runner.client.adopt(seen[index].id)
        print("saved \(seen[index].name) as \(seen[index].id)")
```

`device.id` now prints as `"gaia:<uuid>"` via `DeviceRef.description`, which is what we want in the probe output.

- [ ] **Step 5: Build and run the suite**

Run: `swift build 2>&1 | tail -5`
Expected: no errors, no warnings.

Run: `swift test 2>&1 | tail -5`
Expected: same count as Task 3, all passing. `DeviceControllerTests` and `TransportTests` do not touch `GaiaClient`, so they are unaffected.

- [ ] **Step 6: Commit**

```bash
git add Sources/BudsKit/GaiaClient.swift Sources/budsctl-cli/CLI.swift
git commit -m "refactor: split GaiaClient radio start from device adoption"
```

---

### Task 5: `GaiaBackend`

Adapts the existing GAIA stack to `EarbudsBackend`: maps `GaiaFrame`s onto `DeviceEvent`s and forwards the connection plane to `GaiaClient`.

**Files:**
- Create: `Sources/BudsKit/Gaia/GaiaBackend.swift`
- Create: `Tests/BudsKitTests/GaiaBackendTests.swift`

**Interfaces:**
- Consumes: `EarbudsBackend`, `DeviceEvent`, `BackendPolicy`, `EventHub` (Task 3); `GaiaTransport`, `GaiaFrame`, `GaiaCommand`, `GaiaClient` (Task 4).
- Produces: `GaiaBackend(transport: any GaiaTransport, client: GaiaClient? = nil)`, conforming to `EarbudsBackend` with `static let id = "gaia"`. `var policy: BackendPolicy` is settable, so tests can shorten the settle schedule.

**Why the `client` is optional:** the data plane is a `GaiaTransport`, which `FakeTransport` already implements with the device's real awkwardness (no reply to `setMode`, a ~1.4 s unsolicited confirmation, write failures, swallowed notifications). The connection plane needs a real `GaiaClient`. Making the client optional lets Task 6's tests drive the same frame→event mapping the app uses, instead of a second copy that can drift.

- [ ] **Step 1: Write the failing tests**

Create `Tests/BudsKitTests/GaiaBackendTests.swift`:

```swift
import Testing
import Foundation
@testable import BudsKit

@MainActor
@Suite("GaiaBackend")
struct GaiaBackendTests {

    /// Collects events from a fresh stream until `count` have arrived.
    private func collect(
        _ backend: GaiaBackend,
        count: Int,
        timeout: Duration = .seconds(2),
        while body: () async -> Void
    ) async -> [DeviceEvent] {
        let stream = backend.events()
        let task = Task { () -> [DeviceEvent] in
            var events: [DeviceEvent] = []
            for await event in stream {
                events.append(event)
                if events.count == count { return events }
            }
            return events
        }
        await body()
        let raced = await withTimeout(timeout) { await task.value }
        task.cancel()
        return raced ?? []
    }

    @Test("has the persisted backend id")
    func backendID() {
        #expect(GaiaBackend.id == "gaia")
    }

    @Test("the policy carries the Air4 Pro's two quirks")
    func policy() {
        let backend = GaiaBackend(transport: FakeTransport())
        #expect(backend.policy.settleReads.isEmpty == false,
                "the device serves unreliable reads for ~45 s after connect")
        #expect(backend.policy.batteryInterval != nil,
                "the device never announces its battery")
    }

    @Test("a mode frame becomes a mode event")
    func modeEvent() async {
        let transport = FakeTransport(mode: .normal)
        let backend = GaiaBackend(transport: transport)
        backend.start()
        let events = await collect(backend, count: 1) {
            transport.emitModeChange(.passthrough)
        }
        #expect(events == [.mode(.passthrough)])
    }

    @Test("battery frames become per-side events")
    func batteryEvents() async {
        let transport = FakeTransport()
        transport.batteryLeft = 71
        transport.batteryRight = 64
        let backend = GaiaBackend(transport: transport)
        backend.start()
        let events = await collect(backend, count: 2) {
            await backend.refreshBattery()
        }
        #expect(events.contains(.batteryLeft(71)))
        #expect(events.contains(.batteryRight(64)))
    }

    @Test("a firmware frame becomes a firmware event")
    func firmwareEvent() async {
        let transport = FakeTransport()
        transport.firmware = "AIR4PRO-BS588R2E_20241112_v0.2.1"
        let backend = GaiaBackend(transport: transport)
        backend.start()
        let events = await collect(backend, count: 1) {
            _ = try? await transport.request(.getFirmware)
        }
        #expect(events == [.firmware("AIR4PRO-BS588R2E_20241112_v0.2.1")])
    }

    @Test("a battery reading above 100 becomes nil, not a bogus percentage")
    func implausibleBattery() async {
        let transport = FakeTransport()
        transport.batteryLeft = 0xFF
        let backend = GaiaBackend(transport: transport)
        backend.start()
        let events = await collect(backend, count: 1) {
            _ = try? await transport.request(.getBatteryLeft)
        }
        #expect(events == [.batteryLeft(nil)])
    }

    @Test("setMode writes the mode byte to the transport")
    func setModeWrites() async throws {
        let transport = FakeTransport(applyDelay: .milliseconds(10))
        let backend = GaiaBackend(transport: transport)
        backend.start()
        try await backend.setMode(.anc)
        let writes = transport.recordedWrites()
        #expect(writes.contains { $0.0 == .setMode && $0.1 == [ANCMode.anc.rawValue] })
    }

    @Test("refresh reads firmware, mode and both batteries")
    func refreshReadsEverything() async {
        let transport = FakeTransport()
        let backend = GaiaBackend(transport: transport)
        backend.start()
        await backend.refresh()
        let commands = transport.recordedWrites().map(\.0)
        #expect(commands.contains(.getFirmware))
        #expect(commands.contains(.getMode))
        #expect(commands.contains(.getBatteryLeft))
        #expect(commands.contains(.getBatteryRight))
        #expect(commands.contains(.setMode) == false, "refreshing must not write a mode")
    }

    @Test("a write failure propagates instead of being swallowed")
    func writeFailurePropagates() async {
        let transport = FakeTransport()
        transport.failWrites = true
        let backend = GaiaBackend(transport: transport)
        backend.start()
        await #expect(throws: (any Error).self) { try await backend.setMode(.anc) }
    }

    @Test("each caller gets its own stream, so no one steals another's event")
    func streamsAreIndependent() async {
        let transport = FakeTransport()
        let backend = GaiaBackend(transport: transport)
        backend.start()
        let first = backend.events()
        let second = backend.events()
        // Explicit return type: without it the trailing `return nil` cannot be
        // inferred against the `return event` above it.
        let a = Task { () -> DeviceEvent? in
            for await event in first { return event }
            return nil
        }
        let b = Task { () -> DeviceEvent? in
            for await event in second { return event }
            return nil
        }
        transport.emitModeChange(.anc)
        #expect(await a.value == .mode(.anc))
        #expect(await b.value == .mode(.anc))
    }

    @Test("stop ends the mapping, so a later frame produces nothing")
    func stopEndsMapping() async {
        let transport = FakeTransport()
        let backend = GaiaBackend(transport: transport)
        backend.start()
        backend.release()
        let stream = backend.events()
        transport.emitModeChange(.anc)
        let raced = await withTimeout(.milliseconds(200)) { () -> DeviceEvent? in
            for await event in stream { return event }
            return nil
        }
        #expect((raced ?? nil) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter GaiaBackend 2>&1 | tail -20`
Expected: compile failure — `cannot find 'GaiaBackend' in scope`.

- [ ] **Step 3: Write the backend**

Create `Sources/BudsKit/Gaia/GaiaBackend.swift`:

```swift
import Foundation

/// The SoundPEATS / Qualcomm GAIA family as an `EarbudsBackend`.
///
/// Two planes, deliberately separable:
///
/// - The **data plane** is a `GaiaTransport`. That is what makes this testable:
///   `FakeTransport` already reproduces the device's real awkwardness, so the
///   frame-to-event mapping the app runs is the same one the tests run.
/// - The **connection plane** is a `GaiaClient`, and it is optional. Absent
///   means "no radio attached" — a test driving a fake transport, which reports
///   connection state by calling `onConnectionChange` itself.
@MainActor
public final class GaiaBackend: EarbudsBackend {

    public static let id = "gaia"
    public static let displayName = "SoundPEATS"

    private let transport: any GaiaTransport
    private let client: GaiaClient?
    private let hub = EventHub()
    private var pump: Task<Void, Never>?

    /// Both values are the Air4 Pro's measured quirks, moved here verbatim from
    /// `DeviceController`, where they used to be hard-coded defaults.
    ///
    /// The offsets are measured from the connection, not chained end to end —
    /// see `DeviceController.settleMode` for why, and for the capture that
    /// bracketed the settle window.
    ///
    /// `var` so tests can shorten the schedule without waiting 45 s.
    public var policy = BackendPolicy(
        settleReads: [.seconds(2), .seconds(5), .seconds(10), .seconds(20), .seconds(45)],
        batteryInterval: .seconds(300)
    )

    public var onConnectionChange: (@MainActor (ConnectionState) -> Void)? {
        didSet { client?.onConnectionChange = onConnectionChange }
    }

    public var onDiscoveryUpdate: (@MainActor ([DiscoveredDevice]) -> Void)? {
        didSet { client?.onDiscoveryUpdate = onDiscoveryUpdate }
    }

    public init(transport: any GaiaTransport, client: GaiaClient? = nil) {
        self.transport = transport
        self.client = client
    }

    // MARK: - Lifecycle

    public func start() {
        client?.start()
        guard pump == nil else { return }
        let frames = transport.frames()
        // Inherits this method's MainActor isolation, so `yield` needs no hop.
        pump = Task { [weak self] in
            for await frame in frames {
                guard let self else { return }
                for event in Self.events(for: frame) { self.hub.yield(event) }
            }
        }
    }

    public func release() {
        pump?.cancel()
        pump = nil
        client?.release()
    }

    public func adopt(_ ref: DeviceRef) {
        client?.adopt(ref)
    }

    public func connectedDevices() -> [DiscoveredDevice] {
        client?.connectedDevices() ?? []
    }

    public func startScan() { client?.startScan() }
    public func stopScan() { client?.stopScan() }

    public func events() -> AsyncStream<DeviceEvent> { hub.stream() }

    // MARK: - Actions

    public func setMode(_ mode: ANCMode) async throws {
        try await transport.write(.setMode, payload: [mode.rawValue])
    }

    /// Reads everything, including firmware.
    ///
    /// Return values are ignored on purpose: replies reach state through the
    /// frame stream, so there is one code path into `DeviceState` rather than
    /// two that can disagree.
    ///
    /// ponytail: re-reads the firmware on every wake, not just on connect. One
    /// extra GATT read per wake for a version string that cannot change while
    /// the Mac sleeps; split `refresh()` in two if that ever shows up.
    public func refresh() async {
        _ = try? await transport.request(.getFirmware)
        _ = try? await transport.request(.getMode)
        await refreshBattery()
    }

    public func refreshMode() async {
        _ = try? await transport.request(.getMode)
    }

    public func refreshBattery() async {
        _ = try? await transport.request(.getBatteryLeft)
        _ = try? await transport.request(.getBatteryRight)
    }

    // MARK: - Mapping

    /// One GAIA frame's worth of device events.
    ///
    /// `setMode` is never echoed back by this device, so it maps to nothing —
    /// the confirmation arrives later as an unsolicited `getMode`.
    static func events(for frame: GaiaFrame) -> [DeviceEvent] {
        switch frame.command {
        case .getMode:
            guard let mode = frame.mode else { return [] }
            return [.mode(mode)]
        case .getBatteryLeft:
            return [.batteryLeft(frame.percent)]
        case .getBatteryRight:
            return [.batteryRight(frame.percent)]
        case .getFirmware:
            guard let firmware = frame.ascii else { return [] }
            return [.firmware(firmware)]
        case .setMode:
            return []
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter GaiaBackend 2>&1 | tail -10`
Expected: PASS, **11 tests**. Running total after this task: **116 tests / 10 suites**.

Run: `swift test 2>&1 | tail -5` — all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/BudsKit/Gaia/GaiaBackend.swift Tests/BudsKitTests/GaiaBackendTests.swift
git commit -m "feat: add GaiaBackend adapting the GAIA stack to EarbudsBackend"
```

---

### Task 6: Generalise `DeviceController`

The riskiest task. `DeviceController` holds every hard-won concurrency fix in this codebase — write ordering, superseded sets, the resolving-mode loader, publish ordering, the `!Task.isCancelled` re-checks after every await. All of it must survive, and none of it is device-specific.

**The bar: all existing `DeviceControllerTests` assertions keep passing, unedited except for how the controller is constructed and how the settle schedule is set.** Do not delete or weaken an assertion. If one cannot pass, stop and report it rather than adjusting it.

**One deliberate behaviour change**, and the only one in this task: the event loop gains a `!Task.isCancelled` guard it did not have. That is a latent bug fix, not a refactor artifact — see the comment in Step 2. Everything else must behave exactly as it does today.

**Files:**
- Modify: `Sources/BudsKit/DeviceController.swift`
- Modify: `Tests/BudsKitTests/DeviceControllerTests.swift`
- Modify: `Sources/BudsKit/Device/EarbudsBackend.swift` — one doc comment only (see Step 3)

**Interfaces:**
- Consumes: `EarbudsBackend`, `DeviceEvent`, `BackendPolicy` (Task 3); `GaiaBackend` (Task 5).
- Produces: `DeviceController(backend: any EarbudsBackend, bridge: StateBridge, onStateChanged:)`, `DeviceController.use(_ backend: any EarbudsBackend)`. The `settleReads` and `batteryInterval` properties are **removed** — they come from `backend.policy`. `setTimeout` stays.

- [ ] **Step 1: Swap the dependency**

In `Sources/BudsKit/DeviceController.swift`, replace the stored properties and init:

```swift
    /// The device family currently driving this controller. Swapped by `use`.
    private var backend: any EarbudsBackend

    /// How long to wait for the device's unsolicited confirmation.
    public var setTimeout: Duration = .seconds(3)

    public init(
        backend: any EarbudsBackend,
        bridge: StateBridge,
        onStateChanged: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.backend = backend
        self.bridge = bridge
        self.onStateChanged = onStateChanged
    }
```

Delete the `settleReads` and `batteryInterval` stored properties. Their documentation comments move to `GaiaBackend.policy` (already done in Task 5) — do not lose the `settleMode` doc comment, which stays on `settleMode`.

- [ ] **Step 2: Rewrite `start`, `stop` and `apply`**

```swift
    /// Begin consuming device events. Idempotent.
    public func start() {
        guard frameTask == nil else { return }
        let stream = backend.events()
        // Task inherits this method's MainActor isolation, so `apply` needs no
        // hop and no await.
        frameTask = Task { [weak self] in
            for await event in stream {
                // `!Task.isCancelled` is load-bearing, and it is new here.
                // `AsyncStream`'s iteration does not itself observe
                // cancellation: an element already buffered when `stop()` ran
                // resumes this loop anyway. Demonstrated — three events
                // buffered before `cancel()` all reached the body without this
                // guard, and none reached it with the guard.
                //
                // It matters most for `use(_:)`. Switching device families
                // calls `stop()` and then clears the readings; an event
                // buffered from the *previous* pair of earbuds would otherwise
                // land in `DeviceState` on a later main-actor turn, after the
                // clear, and be shown as this device's mode or battery.
                guard let self, !Task.isCancelled else { return }
                self.apply(event)
            }
        }
        // Only for devices that do not announce their battery. Galaxy Buds push
        // STATUS_UPDATED on every change, so polling them would be two writes
        // every five minutes for information already in hand.
        guard let interval = backend.policy.batteryInterval else { return }
        batteryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                // Sleep returns early when cancelled, so check before doing
                // any work: otherwise a cancelled task still issues one last
                // refreshBattery() — two GATT writes — before the while
                // re-check ends the loop.
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.state.connection.isReady else { continue }
                await self.backend.refreshBattery()
            }
        }
    }
```

`stop()` keeps its body verbatim, including the long comment about why `writeOrder?.cancel()` is not what prevents a late write.

`apply` becomes:

```swift
    private func apply(_ event: DeviceEvent) {
        switch event {
        case .mode(let mode):
            state.mode = mode
            if state.pendingMode == mode { state.pendingMode = nil }
            publish()

        case .batteryLeft(let percent):
            state.batteryLeft = percent
            publish()

        case .batteryRight(let percent):
            state.batteryRight = percent
            publish()

        case .firmware(let firmware):
            state.firmware = firmware
            if !firmware.contains(BudsCtl.knownGoodFirmware) {
                state.lastError = "Untested firmware (\(firmware)). Modes may not respond."
            }
            // Publishes like the other three cases. It used to rely on
            // `refreshAfterConnect` publishing straight after; that tail
            // publish is gone, so without this the firmware string and its
            // warning would never reach the UI or the bridge.
            publish()
        }
    }
```

Keep the existing comment noting that only the GAIA family reports firmware, added here:

```swift
        // Only the GAIA family emits this. Left as a plain check rather than a
        // per-backend "known good firmware" policy field: one device reports a
        // version, so a policy field would be configuration for a value that
        // never varies.
```

- [ ] **Step 3: Rewrite the action and refresh paths**

`performSet`: replace the transport write and the reconciling read. Everything else — the `previousWrite` chain, the failure branch's two error messages, the `!Task.isCancelled` re-checks, the "only the newest target may clear the optimistic state" rule — stays byte for byte.

```swift
        let stream = backend.events()

        let previousWrite = writeOrder
        let thisWrite = Task { [backend] in
            _ = await previousWrite?.value
            do {
                try await backend.setMode(target)
                return true
            } catch {
                return false
            }
        }
        writeOrder = thisWrite
```

and the confirmation wait:

```swift
        let confirmed = await withTimeout(setTimeout) {
            for await event in stream where event == .mode(target) { return true }
            return false
        } ?? false
```

and the reconciling read, which had a request/reply shape the protocol no longer has:

```swift
        // The set may have been silently lost. Read the truth once, then stop.
        // Reconcile and clear the optimistic state in the same turn: anything
        // that sees `isBusy` go false must already be looking at the settled mode.
        let reconciled = await readMode(timeout: setTimeout)
        // Re-checked after the await, not only before it: a superseded set that
        // resumes here must not write `state.mode` from its own read, nor flash
        // "did not change mode" over a newer set that already succeeded.
        guard !Task.isCancelled else { return }
        if state.pendingMode == target { state.pendingMode = nil }
        if let actual = reconciled {
            state.mode = actual
            state.lastError = actual == target ? nil : "The earbuds did not change mode"
        } else {
            state.lastError = "No response from the earbuds"
        }
        publish()
```

Add the helper. It replaces `GaiaTransport.request(.getMode)` and keeps that method's key discipline: subscribe *before* triggering, or a reply that arrives faster than we can subscribe is lost.

```swift
    /// Ask the device for its mode and wait for the answer.
    ///
    /// The stream is opened before the read is triggered. Opening it after
    /// would drop an answer that arrives faster than we can subscribe — the
    /// same class of bug as writing before the notify subscription lands.
    private func readMode(timeout: Duration) async -> ANCMode? {
        let stream = backend.events()
        await backend.refreshMode()
        let raced: ANCMode?? = await withTimeout(timeout) { () -> ANCMode? in
            for await event in stream {
                if case .mode(let mode) = event { return mode }
            }
            return nil
        }
        return raced ?? nil
    }
```

`refreshAfterConnect`, `refreshOnWake` and `refreshBattery`:

```swift
    /// Run once per connection, after the notify subscription has landed.
    public func refreshAfterConnect() async {
        await backend.refresh()
        // Nothing at the tail on purpose. `connectionChanged` already set and
        // published `.ready` before calling this, and it is the sole writer of
        // `state.connection`. Re-asserting `.ready` here after up to ~12 s of
        // awaits would resurrect a connection the user has since lost: the app
        // dispatches every connection event as its own unstructured Task, so a
        // `connectionChanged(.waiting)` can complete correctly while this task
        // is suspended inside a request. Each reply publishes via `apply`.
    }

    public func refreshBattery() async {
        await backend.refreshBattery()
    }

    /// After wake, the link usually survives but the state may be stale.
    ///
    /// Deliberately `refreshMode()` + `refreshBattery()` rather than
    /// `refresh()`, which restores this method's original behaviour exactly
    /// (it read the mode and both batteries, never the firmware) — and, more
    /// importantly, breaks a reconnect loop.
    ///
    /// `refresh()` is the *connect* hook. On a device that pushes its state
    /// when a link comes up, prompting it means tearing the link down and
    /// rebuilding it, which re-fires `connectionChanged(.ready)` and calls
    /// `refreshAfterConnect` again — forever. Keeping the wake path on the
    /// narrower hooks means the only method that may reopen a link is one
    /// nothing in the connect path calls.
    public func refreshOnWake() async {
        guard state.connection.isReady else { return }
        await backend.refreshMode()
        await backend.refreshBattery()
    }
```

In `settleMode`, keep the entire doc comment and loop, changing only the read and the schedule source:

```swift
        let start = ContinuousClock.now
        for offset in backend.policy.settleReads {
```

and

```swift
            // The answer reaches `state` through `apply`, like every other read.
            await backend.refreshMode()
```

In `connectionChanged`, add a guard so a pushing device never starts a settle sequence:

```swift
        guard state.connection.isReady else { return }
        await refreshAfterConnect()
        // Started after the refresh, and only if the link is still up: the
        // refresh takes up to ~12 s of awaits, and the buds can be back in
        // the case by the time it returns.
        guard state.connection.isReady else { return }
        // A device that pushes its state on connect has nothing to settle, and
        // must not be left showing the loader waiting for a re-read that will
        // never be scheduled.
        guard !backend.policy.settleReads.isEmpty else {
            clearResolving()
            return
        }
        settleTask = Task { [weak self] in await self?.settleMode() }
```

`clearResolving()` is already private in this file and already publishes only on a real change; reuse it rather than assigning the flag here.

**One doc-comment fix in `Sources/BudsKit/Device/EarbudsBackend.swift`.** Task 3 shipped `refreshMode()` documented as "Called only by the settle loop, so only reachable when `policy.settleReads` is non-empty." That is no longer true — `refreshOnWake` calls it too, and for the Samsung backend that is its *only* caller. Replace that comment with:

```swift
    /// Re-read just the mode.
    ///
    /// Called from `DeviceController.refreshOnWake()`, and from the settle loop
    /// when `policy.settleReads` is non-empty. This — never `refresh()` — is
    /// where a backend may tear a link down and rebuild it, because nothing in
    /// the connect path calls it.
    func refreshMode() async
```

Change nothing else in that file.

- [ ] **Step 4: Add `use`**

```swift
    /// Switch to a different device family.
    ///
    /// Only called when the user selects a device on the other radio; a
    /// selection within the same family goes straight to `adopt`, which already
    /// releases the previous peripheral.
    ///
    /// Clears the readings rather than keeping them: unlike a reconnect, where
    /// the last mode the device reported is still the best information we have,
    /// a mode read from a *different* pair of earbuds is not information about
    /// this one.
    public func use(_ backend: any EarbudsBackend) {
        stop()
        self.backend = backend
        state.mode = nil
        state.pendingMode = nil
        state.batteryLeft = nil
        state.batteryRight = nil
        state.firmware = nil
        state.lastError = nil
        start()
    }
```

- [ ] **Step 5: Migrate the tests**

In `Tests/BudsKitTests/DeviceControllerTests.swift`, change only the helper and the policy assignments. Replace `makeController`:

```swift
    private func makeController(
        mode: ANCMode = .normal,
        applyDelay: Duration = .milliseconds(30)
    ) -> (DeviceController, FakeTransport, GaiaBackend, StateBridge) {
        let transport = FakeTransport(mode: mode, applyDelay: applyDelay)
        let backend = GaiaBackend(transport: transport)
        // Required, and easy to miss: `DeviceController.start()` subscribes to
        // `backend.events()`, but the pump that feeds that hub from
        // `transport.frames()` is started only by `GaiaBackend.start()`.
        // Without this every event-driven test in the suite fails.
        //
        // Deliberately not called from `DeviceController.start()`:
        // `EarbudsBackend.start()` is the app-level radio-and-discovery hook,
        // and a controller that brings radios up would contradict the design
        // (`AppModel` starts every backend; only one is adopted).
        backend.start()
        // Off by default so no test waits out the real 2 s first re-read; the
        // tests that exercise settling set their own schedule.
        backend.policy = BackendPolicy()
        let suite = "budsctl.test.\(UUID().uuidString)"
        let bridge = StateBridge(defaults: UserDefaults(suiteName: suite)!)
        let controller = DeviceController(backend: backend, bridge: bridge)
        controller.setTimeout = .milliseconds(300)
        controller.state.connection = .ready
        controller.state.mode = mode
        controller.start()
        return (controller, transport, backend, bridge)
    }
```

Update every destructuring site to the four-tuple (`let (controller, transport, _, _) = …`, and so on).

Replace every `controller.settleReads = [...]` with `backend.policy.settleReads = [...]`, taking `backend` from the tuple. **There are exactly 7, at lines 331, 347, 363, 376, 392, 410 and 422** — verified with `grep -n settleReads Tests/BudsKitTests/DeviceControllerTests.swift`. Re-run that grep after your edits and expect zero `controller.settleReads` hits.

**No test sets `batteryInterval`** — verified, `grep -n batteryInterval Tests/` returns nothing. So the ordering caveat below does not bite any existing test, but keep it in mind if you add one: `backend.policy.batteryInterval` is read once inside `start()`, so it must be set *before* `controller.start()` to have any effect. `settleReads` is read in `connectionChanged`, which runs after construction, so setting it after `makeController` returns works fine.

**Only `DeviceControllerTests.swift` constructs a `DeviceController`** — verified with `grep -ln "DeviceController(" Tests/BudsKitTests/*.swift`. `TransportTests`, `IntentsTests`, `StateModelTests`, `StateBridgeTests` and `GaiaFrameTests` need no changes from this task.

The test at line ~252 constructs a controller inline; update it the same way:

```swift
        let transport = FakeTransport(mode: .anc, applyDelay: .milliseconds(30))
        let backend = GaiaBackend(transport: transport)
        backend.policy = BackendPolicy()
        // …
        let controller = DeviceController(
            backend: backend,
            bridge: bridge,
            onStateChanged: { … }
        )
```

Add two tests for the new behaviour at the end of the suite:

```swift
    @Test("a pushing device shows no loader, because there is nothing to settle")
    func pushingDeviceClearsResolving() async throws {
        let (controller, _, backend, _) = makeController()
        backend.policy.settleReads = []
        await controller.connectionChanged(.ready)
        try await until("loader cleared") { controller.state.isResolvingMode == false }
        controller.stop()
    }

    @Test("switching device family clears readings from the previous device")
    func useClearsPreviousDevice() async throws {
        let (controller, _, _, _) = makeController(mode: .anc)
        controller.state.batteryLeft = 80
        controller.state.firmware = "old"

        let other = GaiaBackend(transport: FakeTransport(mode: .normal))
        other.policy = BackendPolicy()
        controller.use(other)

        #expect(controller.state.mode == nil, "a mode from other earbuds is not news about these")
        #expect(controller.state.batteryLeft == nil)
        #expect(controller.state.firmware == nil)
        controller.stop()
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test 2>&1 | tail -8`
Expected: PASS, **118 tests / 10 suites** — two more than after Task 5, in the existing `DeviceController set-mode flow` suite.

If a pre-existing assertion fails, **stop and report which one** rather than editing it — a failure here means the refactor changed behaviour, which is the one thing this task must not do.

- [ ] **Step 7: Commit**

```bash
git add Sources/BudsKit/DeviceController.swift Tests/BudsKitTests/DeviceControllerTests.swift
git commit -m "refactor: drive DeviceController from EarbudsBackend instead of GaiaTransport"
```

---

### Task 7: Samsung message interpretation

Maps decoded `SppFrame`s onto `DeviceEvent`s. This is where spec §2.4's offsets and §2.5's validation live. Pure logic, no radio.

**Files:**
- Create: `Sources/BudsKit/Samsung/SppEvents.swift`
- Create: `Tests/BudsKitTests/SppEventsTests.swift`

**Interfaces:**
- Consumes: `SppFrame`, `SppMessageID` (Task 2); `DeviceEvent` (Task 3).
- Produces: `SppFrame.events: [DeviceEvent]`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/BudsKitTests/SppEventsTests.swift`:

```swift
import Testing
import Foundation
@testable import BudsKit

@Suite("SppFrame device events")
struct SppEventsTests {

    private func frame(_ id: SppMessageID, _ payload: [UInt8]) -> SppFrame {
        SppFrame(rawID: id.rawValue, payload: payload)
    }

    /// A plausible EXTENDED_STATUS_UPDATED for Buds FE: revision, ear type,
    /// battery L/R, coupled, main connection, placement, case battery, then the
    /// fields up to the noise control mode at index 12.
    private func extendedStatus(
        batteryLeft: UInt8 = 82,
        batteryRight: UInt8 = 79,
        mode: UInt8 = 1
    ) -> SppFrame {
        frame(.extendedStatusUpdated, [
            0x05,           //  0 revision
            0x00,           //  1 ear type
            batteryLeft,    //  2
            batteryRight,   //  3
            0x01,           //  4 coupled
            0x01,           //  5 main connection
            0x11,           //  6 placement L/R nibbles
            0x64,           //  7 case battery — read and discarded
            0x00,           //  8 adjust sound sync
            0x02,           //  9 equaliser mode
            0x80,           // 10 touch lock bitfield
            0x30,           // 11 touch options L/R nibbles
            mode,           // 12 noise control mode
            0x00,           // 13 voice wake-up
        ])
    }

    // MARK: - Mode

    @Test("a noise control update carries the mode")
    func noiseControlsUpdate() {
        #expect(frame(.noiseControlsUpdate, [0x00]).events == [.mode(.normal)])
        #expect(frame(.noiseControlsUpdate, [0x01]).events == [.mode(.anc)])
        #expect(frame(.noiseControlsUpdate, [0x02]).events == [.mode(.passthrough)])
    }

    /// Adaptive is out of scope. Dropping it leaves the last known mode
    /// standing, which beats displaying a mode the app cannot represent.
    @Test("adaptive mode is dropped, not guessed at")
    func dropsAdaptive() {
        #expect(frame(.noiseControlsUpdate, [0x03]).events.isEmpty)
        #expect(frame(.noiseControlsUpdate, [0xFF]).events.isEmpty)
    }

    @Test("an empty noise control update yields nothing")
    func emptyNoiseControlsUpdate() {
        #expect(frame(.noiseControlsUpdate, []).events.isEmpty)
    }

    @Test("an ack for a mode set carries the mode that was applied")
    func acknowledgesNoiseControls() {
        let ack = frame(.acknowledgement, [SppMessageID.noiseControls.rawValue, 0x02])
        #expect(ack.events == [.mode(.passthrough)])
    }

    @Test("an ack for some other message is ignored")
    func ignoresUnrelatedAck() {
        let ack = frame(.acknowledgement, [SppMessageID.managerInfo.rawValue, 0x02])
        #expect(ack.events.isEmpty)
    }

    @Test("a truncated ack is ignored rather than read past its end")
    func ignoresTruncatedAck() {
        #expect(frame(.acknowledgement, [SppMessageID.noiseControls.rawValue]).events.isEmpty)
        #expect(frame(.acknowledgement, []).events.isEmpty)
    }

    // MARK: - Battery

    @Test("a status update carries both battery levels")
    func statusUpdate() {
        let status = frame(.statusUpdated, [0x05, 82, 79, 0x01, 0x01, 0x11, 0x64, 0x00])
        #expect(status.events == [.batteryLeft(82), .batteryRight(79)])
    }

    @Test("an out-of-range battery reads as unknown, not as a bogus percentage")
    func implausibleBattery() {
        let status = frame(.statusUpdated, [0x05, 0xFF, 79, 0x01, 0x01, 0x11, 0x64, 0x00])
        #expect(status.events == [.batteryLeft(nil), .batteryRight(79)])
    }

    @Test("a truncated status update yields nothing")
    func truncatedStatusUpdate() {
        #expect(frame(.statusUpdated, [0x05, 82]).events.isEmpty)
    }

    // MARK: - Extended status

    @Test("extended status carries both batteries and the mode")
    func extendedStatusFull() {
        let events = extendedStatus(batteryLeft: 82, batteryRight: 79, mode: 1).events
        #expect(events.contains(.batteryLeft(82)))
        #expect(events.contains(.batteryRight(79)))
        #expect(events.contains(.mode(.anc)))
        #expect(events.count == 3, "case battery is deliberately discarded")
    }

    /// Spec §2.5. Byte 12 is the one offset not confirmed against a capture, so
    /// an out-of-range value must leave the mode unknown — the UI then honestly
    /// reads "Reading mode…" instead of presenting a misparse as a selection.
    @Test("an out-of-range mode byte yields battery but no mode")
    func rejectsImplausibleMode() {
        let events = extendedStatus(mode: 0x30).events
        #expect(events.contains(.batteryLeft(82)))
        #expect(events.contains(.mode(.anc)) == false)
        #expect(events.contains { if case .mode = $0 { true } else { false } } == false)
    }

    /// The whole-message plausibility gate: if the batteries are impossible,
    /// the offsets are probably wrong, so byte 12 is not to be trusted either.
    @Test("an implausible extended status is rejected outright")
    func rejectsImplausibleExtendedStatus() {
        #expect(extendedStatus(batteryLeft: 200).events.isEmpty)
        #expect(extendedStatus(batteryRight: 101).events.isEmpty)
    }

    @Test("an extended status too short to reach byte 12 is rejected")
    func rejectsShortExtendedStatus() {
        #expect(frame(.extendedStatusUpdated, [0x05, 0x00, 82, 79]).events.isEmpty)
    }

    // MARK: - Everything else

    @Test("messages this app does not handle yield nothing")
    func ignoresOtherMessages() {
        #expect(SppFrame(rawID: 0x2A, payload: [0x01, 0x02]).events.isEmpty)
        #expect(frame(.managerInfo, [0x01]).events.isEmpty)
        #expect(frame(.noiseControls, [0x01]).events.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SppEvents 2>&1 | tail -20`
Expected: compile failure — `value of type 'SppFrame' has no member 'events'`.

- [ ] **Step 3: Write the mapping**

Create `Sources/BudsKit/Samsung/SppEvents.swift`:

```swift
import Foundation

public extension SppFrame {

    /// The device events this frame carries. Empty for anything this app does
    /// not handle, which is most of what the buds send.
    ///
    /// Offsets are from spec §2.4. Every one of them except the noise control
    /// mode is assigned unconditionally for all models from Buds+ onward; see
    /// `noiseControlMode` for the exception and what guards it.
    var events: [DeviceEvent] {
        switch id {
        case .noiseControlsUpdate:
            guard let mode = payload.first.flatMap(ANCMode.init(rawValue:)) else { return [] }
            return [.mode(mode)]

        case .acknowledgement:
            // [0] is the message being acked, [1] the value it was set to.
            guard payload.count >= 2,
                  payload[0] == SppMessageID.noiseControls.rawValue,
                  let mode = ANCMode(rawValue: payload[1])
            else { return [] }
            return [.mode(mode)]

        case .statusUpdated:
            // [0] revision, [1] battery L, [2] battery R, [3] coupled,
            // [4] main connection, [5] placement, [6] case battery,
            // [7] charging bitfield.
            guard payload.count > 2 else { return [] }
            return Self.battery(left: payload[1], right: payload[2])

        case .extendedStatusUpdated:
            // Pushed when the channel opens, and the only source of the mode at
            // connect time.
            //
            // The plausibility gate is deliberate: if the batteries are
            // impossible then the offsets are wrong, and byte 12 is not to be
            // trusted either. Cheaper and more honest than showing a misparse.
            guard payload.count > 12,
                  payload[2] <= 100,
                  payload[3] <= 100
            else { return [] }
            var events = Self.battery(left: payload[2], right: payload[3])
            if let mode = ANCMode(rawValue: payload[12]) { events.append(.mode(mode)) }
            return events

        // Sent, never interpreted on receipt.
        case .noiseControls, .managerInfo, .none:
            return []
        }
    }

    /// Both sides, with out-of-range values reported as unknown.
    ///
    /// A reading above 100 means the bud is not reporting — usually because it
    /// is in the case. Showing nothing is more honest than showing a number,
    /// and matches `GaiaFrame.percent` on the BLE side.
    private static func battery(left: UInt8, right: UInt8) -> [DeviceEvent] {
        [
            .batteryLeft(left <= 100 ? Int(left) : nil),
            .batteryRight(right <= 100 ? Int(right) : nil),
        ]
    }
}

/// Why the mode is read from byte 12 of `EXTENDED_STATUS_UPDATED` despite being
/// the least certain thing in this file.
///
/// It is the only offset here inferred from a model-branching parser rather
/// than a stable layout: it sits after byte 10, whose *interpretation* forks on
/// the device's touch-lock generation. The fork changes how that byte is read,
/// not where later fields sit — but that is a reading of GalaxyBudsClient's
/// source, not a capture from hardware.
///
/// It also cannot be avoided. `NOISE_CONTROLS_UPDATE` fires only on a *change*,
/// so without byte 12 the app would sit on "Reading mode…" until the user
/// changed mode by some other means.
///
/// So it is guarded three ways: the value must be one of the three modes this
/// app models, the message's batteries must be plausible, and
/// `budsctl-cli samsung <mac>` exists to confirm it against real hardware. A
/// failed guard leaves `isResolvingMode` true and the UI reading
/// "Reading mode…" — the behaviour `DeviceController.settleMode` argues for at
/// length: never present an untrusted read as a confident selection.
///
/// ponytail: validated, not verified. If a capture ever contradicts byte 12,
/// fix the offset here — nothing else in the app depends on it.
private enum ExtendedStatusNotes {}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SppEvents 2>&1 | tail -10`
Expected: PASS, **14 tests**. Running total after this task: **132 tests / 11 suites** (this task adds one suite, not two).

Run: `swift test 2>&1 | tail -5` — all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/BudsKit/Samsung/SppEvents.swift Tests/BudsKitTests/SppEventsTests.swift
git commit -m "feat: map Samsung SPP messages onto DeviceEvents"
```

---

### Task 8: `SamsungBackend` over IOBluetooth RFCOMM

The radio. Not unit-testable without Galaxy Buds, which is exactly why Tasks 2 and 7 pulled every decision that *could* be tested out of it. This task's deliverable is a clean build plus the CLI probe in Task 10 as its real test.

**Files:**
- Create: `Sources/BudsKit/Samsung/SamsungBackend.swift`
- Modify: `project.yml` (link `IOBluetooth.framework`)

**Interfaces:**
- Consumes: `EarbudsBackend`, `DeviceEvent`, `BackendPolicy`, `EventHub`, `DeviceRef` (Tasks 1, 3); `SppFrame`, `SppReassembler`, `SppMessageID` (Task 2); `SppFrame.events` (Task 7); `DiscoveredDevice` (Task 4).
- Produces: `SamsungBackend()` conforming to `EarbudsBackend`, `static let id = "samsung"`. `SamsungBackend.frames() -> AsyncStream<SppFrame>` for the CLI probe (raw frames, before event mapping).

**Verified API surface.** Every IOBluetooth call below was compiled against the macOS 26 SDK with `-swift-version 6` before this plan was written, including the isolation-sensitive parts:

- `IOBluetoothDevice.pairedDevices()`, `.addressString`, `.name`, `.isConnected()`, `.openConnection()`, `.performSDPQuery(_:)`, `.getServiceRecord(for:)`, `.openRFCOMMChannelAsync(_:withChannelID:delegate:)`
- `IOBluetoothDevice(addressString:)` — **failable**, so `guard let`
- `IOBluetoothSDPUUID(bytes:length:)` — **non-optional**, so no `guard let`
- `IOBluetoothSDPServiceRecord.getRFCOMMChannelID(_:)`
- `IOBluetoothDevice.register(forConnectNotifications:selector:)` with an `@objc` method taking `(IOBluetoothUserNotification, IOBluetoothDevice)`
- `IOBluetoothRFCOMMChannel.isOpen()`, `.getMTU()`, `.setDelegate(_:)`, `.close()`, `.writeAsync(_:length:refcon:)`
- **`extension SamsungBackend: @MainActor IOBluetoothRFCOMMChannelDelegate` compiles.** The protocol is exposed to Swift and the `@MainActor` conformance is accepted, so the fallback to an informal selector-only delegate described in Step 3 should not be needed.
- `@objc(sdpQueryComplete:status:)` on an extension method compiles.

- [ ] **Step 1: Link the framework**

In `project.yml`, add to the `BudsCtl` target's `dependencies` list, next to `- sdk: AppIntents.framework`:

```yaml
      # Galaxy Buds speak Bluetooth Classic RFCOMM, which CoreBluetooth cannot
      # reach. Ships in the SDK, so Package.swift needs no change — only the
      # app target has to link it.
      - sdk: IOBluetooth.framework
```

- [ ] **Step 2: Write the backend**

Create `Sources/BudsKit/Samsung/SamsungBackend.swift`:

```swift
import Foundation
import IOBluetooth

/// Samsung Galaxy Buds over Bluetooth Classic RFCOMM.
///
/// Two things make this structurally different from `GaiaClient`, and both are
/// worth knowing before changing anything here:
///
/// 1. **There is no queued connect.** `GaiaClient`'s entire auto-reconnect
///    design rests on CoreBluetooth's promise that `connect` on an unavailable
///    peripheral stays pending and completes when the peripheral appears.
///    IOBluetooth has no equivalent, so reconnect is driven by
///    `register(forConnectNotifications:)` plus a bounded retry.
/// 2. **RFCOMM is a byte stream.** GATT notifications arrive as discrete
///    values; `rfcommChannelData` arrives as arbitrary chunks. `SppReassembler`
///    owns that problem.
@MainActor
public final class SamsungBackend: NSObject, EarbudsBackend {

    public static let id = "samsung"
    public static let displayName = "Samsung"

    /// Both empty: the buds push `EXTENDED_STATUS_UPDATED` when the channel
    /// opens and `STATUS_UPDATED` on every battery or wear change. Nothing to
    /// settle, nothing to poll.
    public let policy = BackendPolicy()

    public var onConnectionChange: (@MainActor (ConnectionState) -> Void)?
    public var onDiscoveryUpdate: (@MainActor ([DiscoveredDevice]) -> Void)?

    private let hub = EventHub()
    private let frameHub = SppFrameHub()

    private var adopted: DeviceRef?
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var reassembler = SppReassembler()

    private var sdpQueryContinuation: CheckedContinuation<Bool, Never>?
    private var connectNotification: IOBluetoothUserNotification?
    private var openAttempt = 0
    private var retryTask: Task<Void, Never>?

    /// One writer awaiting its `rfcommChannelWriteComplete`.
    ///
    /// Keyed by `refcon` rather than by FIFO position, for the same reason
    /// `GaiaClient.PendingWrite` carries an id: a write that times out can then
    /// remove *itself* without desynchronising everyone behind it.
    private var pendingWrites: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var lastWriteID: UInt64 = 0

    /// Bounds every write in time. IOBluetooth is supposed to always call
    /// `rfcommChannelWriteComplete`, but a stale continuation would take the
    /// next write's completion and deadlock every write from then on, and a
    /// `CheckedContinuation` held in a dictionary produces no runtime warning.
    private static let writeTimeout: Duration = .seconds(5)

    /// Retry offsets for an RFCOMM open that fails while the baseband link is
    /// up — usually buds still settling after leaving the case. Bounded, so a
    /// device that genuinely refuses SPP does not spin forever; the next
    /// connect notification is the real recovery path.
    private static let openRetries: [Duration] = [.seconds(1), .seconds(3), .seconds(7)]

    /// Tried in order at connect time. Buds2 and later, Buds FE included,
    /// publish the first; Buds Pro, Buds Live and Buds+ publish the second.
    ///
    /// Index 0 doubles as the discovery test in `connectedDevices()` — it is
    /// Samsung-specific. Index 1 must never be used for discovery: it is the
    /// generic serial-port UUID that many devices publish, the Air4 Pro
    /// included.
    static let serviceUUIDs: [[UInt8]] = [
        // 2e73a4ad-332d-41fc-90e2-16bef06523f2
        [0x2e, 0x73, 0xa4, 0xad, 0x33, 0x2d, 0x41, 0xfc,
         0x90, 0xe2, 0x16, 0xbe, 0xf0, 0x65, 0x23, 0xf2],
        // 00001101-0000-1000-8000-00805f9b34fb  (standard SPP)
        [0x00, 0x00, 0x11, 0x01, 0x00, 0x00, 0x10, 0x00,
         0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb],
    ]

    public override init() {
        super.init()
    }

    // MARK: - Lifecycle

    /// No radio to bring up: IOBluetooth has no central-manager state machine,
    /// and `pairedDevices()` works as soon as the process starts. Discovery is
    /// already available, so this only arms reconnect.
    public func start() {
        armConnectNotification()
    }

    public func adopt(_ ref: DeviceRef) {
        guard adopted != ref else { return }
        release()
        adopted = ref
        armConnectNotification()
        Task { await openLink() }
    }

    public func release() {
        retryTask?.cancel()
        retryTask = nil
        adopted = nil
        openAttempt = 0
        closeChannel()
        device = nil
    }

    private func closeChannel() {
        guard let channel else { return }
        channel.setDelegate(nil)
        channel.close()
        self.channel = nil
        reassembler = SppReassembler()
        // Not optional. A leaked continuation would take the next write's
        // completion and deadlock every write after it — the same hazard
        // `GaiaClient.releasePeripheral` documents.
        failPendingWrites(SamsungError.notConnected)
    }

    private func report(_ state: ConnectionState) {
        onConnectionChange?(state)
    }

    // MARK: - Discovery

    /// Paired classic devices that plausibly are Galaxy Buds, with no inquiry.
    ///
    /// Returns instantly and works with the buds in your ears, which is what
    /// makes it usable as the default list in Settings.
    ///
    /// **The filter is not optional.** `pairedDevices()` is not service-filtered
    /// the way CoreBluetooth's `retrieveConnectedPeripherals(withServices:)` is —
    /// it returns *everything* ever paired with this Mac. Measured on the
    /// development machine it returned nine devices: a soundbar, a PS5
    /// controller, two keyboards, a mouse, a phone and another Mac. Listing
    /// those under a "Samsung" header would be nonsense.
    ///
    /// Two tests, OR'd, because each covers the other's blind spot:
    ///
    /// - **Publishes `SppNew`.** Samsung-specific, so no false positives. But a
    ///   freshly-paired device may have no cached SDP records until something
    ///   runs a query against it, and this method deliberately does not.
    /// - **Name contains `BUDS`.** Samsung names the entire lineup "Buds …"
    ///   ("Buds FE", "Buds2 Pro", "Galaxy Buds+ (1234)"), so this catches the
    ///   models that publish only the generic `SppStandard` — Buds Pro, Buds
    ///   Live, Buds+. It misses a renamed device, which is what the UUID test
    ///   is for.
    ///
    /// `SppStandard` is deliberately **not** a discovery test: it is the generic
    /// serial-port UUID, and the SoundPEATS Air4 Pro publishes it (verified —
    /// on RFCOMM channel 12). Filtering on it would offer the user their
    /// SoundPEATS buds under the Samsung backend, where every frame this
    /// backend sent would go unanswered. It stays a *connect-time* fallback in
    /// `serviceRecord(on:)`, reached only after the user explicitly picked the
    /// device.
    public func connectedDevices() -> [DiscoveredDevice] {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let samsungSpp = IOBluetoothSDPUUID(bytes: Self.serviceUUIDs[0], length: 16)
        return paired.compactMap { device -> DiscoveredDevice? in
            guard let address = device.addressString, !address.isEmpty else { return nil }
            let name = device.name ?? address
            let named = name.uppercased().contains("BUDS")
            let publishes = device.getServiceRecord(for: samsungSpp) != nil
            guard named || publishes else { return nil }
            return DiscoveredDevice(
                id: DeviceRef(backend: Self.id, id: address),
                name: name,
                // Named *and* publishing is as sure as this gets without
                // connecting; either alone still belongs in the list.
                isLikelyMatch: named || publishes
            )
        }
        .sorted { $0.name < $1.name }
    }

    /// No-ops on purpose.
    ///
    /// `IOBluetoothDeviceInquiry` could find *unpaired* devices, but Galaxy Buds
    /// have to be paired in System Settings before SPP is reachable at all —
    /// which is already how this app tells users to get started. An inquiry
    /// would add a scan that cannot lead anywhere new.
    public func startScan() { onDiscoveryUpdate?(connectedDevices()) }
    public func stopScan() {}

    // MARK: - Connecting

    private func armConnectNotification() {
        guard connectNotification == nil else { return }
        // Fires when any paired device forms a baseband connection. The
        // replacement for CoreBluetooth's queued connect, which IOBluetooth
        // does not offer.
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
    }

    @objc private func deviceConnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        guard let adopted, device.addressString == adopted.id else { return }
        openAttempt = 0
        Task { await openLink() }
    }

    private func openLink() async {
        guard let adopted else { return }
        guard channel == nil else { return }

        guard let device = IOBluetoothDevice(addressString: adopted.id) else {
            report(.failed("These earbuds are not paired with this Mac."))
            return
        }
        self.device = device
        report(.connecting)

        // The RFCOMM open API does not do this for us, and the SDP query needs
        // it too.
        if !device.isConnected() {
            let status = device.openConnection()
            guard status == kIOReturnSuccess else {
                // Timeout here means the buds are in the case. Not a failure —
                // wait for the connect notification.
                report(.waiting)
                return
            }
        }

        // Unfiltered on purpose: an SDP query with UUIDs specified silently
        // fails on macOS Ventura and later.
        guard await performSDPQuery(device) else {
            report(.failed("Could not read the earbuds' service list."))
            return
        }

        guard let (record, channelID) = serviceRecord(on: device) else {
            report(.failed("These earbuds do not expose the Samsung SPP service."))
            return
        }
        _ = record

        var opened: IOBluetoothRFCOMMChannel?
        let status = device.openRFCOMMChannelAsync(
            &opened,
            withChannelID: channelID,
            delegate: self
        )
        // Readiness is reported from `rfcommChannelOpenComplete`, never from
        // this return value: the reference implementation documents it coming
        // back as an error even when the channel opens fine.
        guard let opened else {
            _ = status
            scheduleOpenRetry()
            return
        }
        channel = opened
    }

    private func performSDPQuery(_ device: IOBluetoothDevice) async -> Bool {
        await withCheckedContinuation { continuation in
            sdpQueryContinuation = continuation
            guard device.performSDPQuery(self) == kIOReturnSuccess else {
                // Do not fail hard: the records may already be cached from a
                // previous query, so let the lookup below decide.
                resumeSDPQuery(true)
                return
            }
            // Bounded, so a query that never completes cannot strand the link.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.resumeSDPQuery(false)
            }
        }
    }

    /// Resumes exactly once, whichever of the callback or the timeout arrives
    /// first.
    private func resumeSDPQuery(_ success: Bool) {
        guard let continuation = sdpQueryContinuation else { return }
        sdpQueryContinuation = nil
        continuation.resume(returning: success)
    }

    private func serviceRecord(
        on device: IOBluetoothDevice
    ) -> (IOBluetoothSDPServiceRecord, BluetoothRFCOMMChannelID)? {
        for bytes in Self.serviceUUIDs {
            // IOBluetoothSDPUUID(bytes:length:) is non-optional; only the
            // record lookup can fail.
            let uuid = IOBluetoothSDPUUID(bytes: bytes, length: 16)
            guard let record = device.getServiceRecord(for: uuid) else { continue }
            var channelID: BluetoothRFCOMMChannelID = 0
            guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { continue }
            return (record, channelID)
        }
        return nil
    }

    private func scheduleOpenRetry() {
        guard openAttempt < Self.openRetries.count else {
            // Give up and wait for the next connect notification rather than
            // spinning on a device that will not serve SPP.
            report(.waiting)
            return
        }
        let delay = Self.openRetries[openAttempt]
        openAttempt += 1
        report(.waiting)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.openLink()
        }
    }

    // MARK: - Events

    public func events() -> AsyncStream<DeviceEvent> { hub.stream() }

    /// Raw frames, before event mapping. For `budsctl-cli samsung`, which
    /// exists to print everything the buds send — including the messages this
    /// app ignores.
    public func frames() -> AsyncStream<SppFrame> { frameHub.stream() }

    // MARK: - Actions

    public func setMode(_ mode: ANCMode) async throws {
        try await send(.noiseControls, [mode.rawValue])
    }

    /// Deliberately does nothing.
    ///
    /// This is the *connect* hook, and on connect there is nothing to ask for:
    /// the buds push `EXTENDED_STATUS_UPDATED` — mode and both batteries — the
    /// moment the channel opens. It is already on its way before this is
    /// called.
    ///
    /// **Do not make this reopen the channel.** Reopening re-fires
    /// `rfcommChannelOpenComplete` → `report(.ready)` →
    /// `DeviceController.connectionChanged(.ready)` → `refreshAfterConnect()` →
    /// here, which is an infinite reconnect loop. The channel reopen lives in
    /// `refreshMode()`, which nothing in the connect path calls.
    public func refresh() async {}

    /// Reopens the channel — the wake path's lever, and the only one there is.
    ///
    /// No message requests `EXTENDED_STATUS_UPDATED`; the buds send it when the
    /// channel opens, so reopening is the only way to ask "what is your state
    /// now?". Cheaper than it sounds: SPP is a control channel and A2DP audio
    /// runs independently, so the user hears nothing.
    ///
    /// Reached only from `DeviceController.refreshOnWake()` — `policy.settleReads`
    /// is empty, so the settle loop never runs for this backend. That single
    /// caller is what keeps it out of the connect path, and out of the loop
    /// described on `refresh()` above.
    ///
    /// ponytail: the blunt instrument. If a firmware ever answers message 97 as
    /// a request, send that instead and keep the channel up.
    public func refreshMode() async {
        guard adopted != nil else { return }
        closeChannel()
        openAttempt = 0
        await openLink()
    }

    /// Never called: `policy.batteryInterval` is nil, because the buds push
    /// `STATUS_UPDATED` on every battery change.
    public func refreshBattery() async {}

    private func send(_ id: SppMessageID, _ payload: [UInt8] = []) async throws {
        let data = SppFrame.encode(id, payload)
        try await withCheckedThrowingContinuation { continuation in
            submitWrite(data, continuation)
        }
    }

    /// Recording the continuation and calling `writeAsync` happen in one
    /// main-actor step, so a completion cannot arrive before its `refcon` is in
    /// the table.
    private func submitWrite(
        _ data: Data,
        _ continuation: CheckedContinuation<Void, Error>
    ) {
        guard let channel, channel.isOpen() else {
            continuation.resume(throwing: SamsungError.notConnected)
            return
        }
        lastWriteID += 1
        let id = lastWriteID
        pendingWrites[id] = continuation

        // Chunked to the channel MTU. Every message this app sends is under a
        // dozen bytes, so the loop never runs twice — kept because dropping it
        // would silently truncate if a longer message is ever added.
        var bytes = [UInt8](data)
        let mtu = Int(channel.getMTU())
        var status = kIOReturnSuccess
        while !bytes.isEmpty, status == kIOReturnSuccess {
            let count = min(bytes.count, mtu)
            var chunk = Array(bytes.prefix(count))
            status = chunk.withUnsafeMutableBufferPointer { buffer in
                channel.writeAsync(
                    buffer.baseAddress,
                    length: UInt16(count),
                    refcon: UnsafeMutableRawPointer(bitPattern: UInt(id))
                )
            }
            bytes.removeFirst(count)
        }

        guard status == kIOReturnSuccess else {
            completeWrite(id, error: SamsungError.writeFailed)
            return
        }

        // Not a retry and not a poll: it only ever resumes a continuation that
        // is still waiting, so nothing is re-sent to the device.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.writeTimeout)
            self?.completeWrite(id, error: SamsungError.writeFailed)
        }
    }

    /// Resumes `id` only if it is still pending. Whoever gets here first —
    /// completion, timeout, or teardown — removes the entry before resuming,
    /// which is what makes a double resume impossible.
    private func completeWrite(_ id: UInt64, error: Error?) {
        guard let continuation = pendingWrites.removeValue(forKey: id) else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    /// Drains everything, resuming each entry exactly once. Cleared before any
    /// resume so a re-entrant call cannot see the same entry twice.
    private func failPendingWrites(_ error: Error) {
        let waiting = pendingWrites
        pendingWrites.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
}

public enum SamsungError: Error, Equatable {
    case notConnected
    case writeFailed
}

extension SamsungBackend: @MainActor IOBluetoothRFCOMMChannelDelegate {

    public func rfcommChannelOpenComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        status error: IOReturn
    ) {
        guard rfcommChannel === channel else { return }
        guard error == kIOReturnSuccess, rfcommChannel.isOpen() else {
            channel = nil
            scheduleOpenRetry()
            return
        }
        openAttempt = 0
        report(.ready)
        // Announce ourselves, the way the reference implementation does on
        // connect. The buds push EXTENDED_STATUS_UPDATED without being asked,
        // so nothing here requests state.
        Task { try? await send(.managerInfo, [0x01, 0x02, 0x22]) }
    }

    public func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        guard rfcommChannel === channel else { return }
        guard let dataPointer, dataLength > 0 else { return }
        let chunk = Data(bytes: dataPointer, count: dataLength)
        for frame in reassembler.append(chunk) {
            frameHub.yield(frame)
            for event in frame.events { hub.yield(event) }
        }
    }

    public func rfcommChannelWriteComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        refcon: UnsafeMutableRawPointer!,
        status error: IOReturn
    ) {
        guard rfcommChannel === channel else { return }
        let id = UInt64(UInt(bitPattern: refcon))
        completeWrite(id, error: error == kIOReturnSuccess ? nil : SamsungError.writeFailed)
    }

    public func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        guard rfcommChannel === channel else { return }
        closeChannel()
        // Wait for the next connect notification rather than spinning. The buds
        // are usually back in the case.
        report(.waiting)
    }
}

extension SamsungBackend {
    /// SDP query completion. Declared `@objc` because `performSDPQuery(_:)`
    /// takes an untyped target and calls this by selector.
    @objc(sdpQueryComplete:status:)
    func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        resumeSDPQuery(status == kIOReturnSuccess)
    }
}

/// Fans raw frames out to every concurrent waiter, for the CLI probe.
///
/// Same shape as `FrameHub` and `EventHub`; kept separate because it carries
/// `SppFrame`, which only this backend and the probe know about.
final class SppFrameHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<SppFrame>.Continuation] = [:]

    func stream() -> AsyncStream<SppFrame> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    func yield(_ frame: SppFrame) {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets { continuation.yield(frame) }
    }
}
```

- [ ] **Step 3: Build and fix concurrency diagnostics**

Run: `swift build 2>&1 | tail -30`
Expected: no errors, no warnings.

IOBluetooth is an old ObjC framework, so expect friction here. Fix diagnostics without weakening isolation:

- Delegate methods must be reachable from ObjC. If Swift 6 rejects `@MainActor` on a delegate conformance, mark the individual methods `@objc` and keep the `extension SamsungBackend: @MainActor IOBluetoothRFCOMMChannelDelegate` form used above, which is the same pattern `GaiaClient` uses for `CBPeripheralDelegate`.
- If `IOBluetoothRFCOMMChannelDelegate` is not exposed as a Swift protocol in this SDK, drop the conformance clause and keep the methods as `@objc` members with their exact selectors (`rfcommChannelData:data:length:`, `rfcommChannelOpenComplete:status:`, `rfcommChannelWriteComplete:refcon:status:`, `rfcommChannelClosed:`) — IOBluetooth dispatches by selector, so an informal delegate works. Verify with `nm`-free reasoning: the reference implementation's `Bluetooth.mm` uses exactly these selectors.
- `IOBluetoothDevice.register(forConnectNotifications:selector:)` may need the target passed as `self` with `#selector` on an `@objc` method whose signature is `(IOBluetoothUserNotification, IOBluetoothDevice)`. That is what `deviceConnected` above is.

Do **not** silence a diagnostic with `nonisolated(unsafe)` or `@unchecked Sendable` on `SamsungBackend` itself. If isolation genuinely cannot be expressed, stop and report it.

- [ ] **Step 4: Confirm `project.yml` parses — do NOT expect the app to build**

Run: `xcodegen generate 2>&1 | tail -5`
Expected: generation succeeds, proving the `IOBluetooth.framework` dependency you added is well-formed.

**Do not run `xcodebuild` and do not expect the app target to compile.** It cannot: `App/BudsCtlApp.swift` still calls `GaiaClient.select(_:)`, `forgetDevice()` and `init(bridge:)`, which Task 4 deleted. That breakage is expected and is Task 9's to repair — see the Global Constraints. **Do not patch `App/` to work around it.**

Your build gate for this task is `swift build` (Step 3), which does compile `BudsKit` including `SamsungBackend`. If `xcodegen` is not installed, skip this step and say so in your report; Task 9 regenerates the project anyway.

- [ ] **Step 5: Run the suite**

Run: `swift test 2>&1 | tail -5`
Expected: unchanged from Task 7, all passing. Nothing tests this file yet.

- [ ] **Step 6: Commit**

```bash
git add Sources/BudsKit/Samsung/SamsungBackend.swift project.yml
git commit -m "feat: add SamsungBackend over IOBluetooth RFCOMM"
```

---

### Task 9: Wire the app up

`AppModel` starts every backend so both brands appear in Settings, adopts the one owning the saved device, and routes selection. Settings groups the merged list by vendor.

**Files:**
- Modify: `Sources/BudsKit/Device/EarbudsBackend.swift` (append `Backends`)
- Modify: `App/BudsCtlApp.swift` (`AppModel`)
- Modify: `App/SettingsView.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–8.
- **Contract Task 6 established:** `DeviceController` starts nothing on its backend. `AppModel` must call `backend.start()` on every backend before handing one to `DeviceController`, and `controller.use(_:)` assumes the backend it receives is already started (it calls its own `start()`, not the backend's). The `init` loop below does this for all backends, which is why `use(_:)` is safe.
- Produces: `Backends.all() -> [any EarbudsBackend]`. `AppModel.devices: [DiscoveredDevice]`, `AppModel.select(_ device: DiscoveredDevice)`, `AppModel.forget()`, `AppModel.refreshDevices()`, `AppModel.startScan()`, `AppModel.stopScan()`, `AppModel.selectedRef: DeviceRef?`.

- [ ] **Step 1: Add the registry**

Append to `Sources/BudsKit/Device/EarbudsBackend.swift`:

```swift
/// Every device family this app can drive.
public enum Backends {

    /// **The one list.** Adding a device family is one line here.
    ///
    /// All of them are started so both brands show up in Settings; only the one
    /// owning the user's saved device is adopted.
    @MainActor
    public static func all() -> [any EarbudsBackend] {
        // GaiaBackend needs the client twice over: as its data plane (a
        // GaiaTransport) and as its connection plane. Same object, two roles.
        let client = GaiaClient()
        return [
            GaiaBackend(transport: client, client: client),
            SamsungBackend(),
        ]
    }
}
```

No `bridge` parameter: Task 4 removed `GaiaClient`'s dependency on it, and nothing else here needs one. `StateBridge` is still what `DeviceController` publishes through — it is just no longer a backend's business.

- [ ] **Step 2: Rewrite `AppModel`'s wiring**

In `App/BudsCtlApp.swift`, replace the `AppModel` stored properties and `init` up to the `controller.start()` line:

```swift
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
        // …the rest of init is unchanged: bridge.observeRequests, drainRequests,
        // KeyboardShortcuts.onKeyUp, the wake observer, the terminate observer…
    }

    /// The backend the controller is currently driven by.
    private var activeBackend: any EarbudsBackend {
        backends.first { type(of: $0).id == (bridge.deviceRef?.backend ?? "") } ?? backends[0]
    }

    private func mergeDiscovered() {
        devices = discovered.values.flatMap { $0 }.sorted { $0.name < $1.name }
    }
```

Replace the device-management methods at the end of `AppModel`:

```swift
    /// Cheap: a paired-device list and a retrieve, not a scan. Safe to call
    /// every time Settings opens.
    func refreshDevices() {
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

        // Release whatever held a link before, so a de-selected device's
        // notifications can no longer reach the controller. `DeviceController.use`
        // deliberately does *not* do this — the caller owns it, because only the
        // caller knows which other backends exist.
        for backend in backends where type(of: backend).id != device.id.backend {
            backend.release()
        }

        // Computed BEFORE the save, and the order is load-bearing:
        // `activeBackend` derives from `bridge.deviceRef`, so saving first would
        // make this comparison always false and the controller would never be
        // switched to the new family.
        let switchingFamily = type(of: activeBackend).id != device.id.backend
        bridge.saveDeviceRef(device.id)
        if switchingFamily { controller.use(target) }
        // `adopt` reports `.connecting`, which is what repaints the UI after a
        // switch — `release()` above reports nothing, by design.
        target.adopt(device.id)
    }

    func forget() {
        for backend in backends { backend.release() }
        bridge.saveDeviceRef(nil)
        Task { await controller.connectionChanged(.notConfigured) }
    }
```

- [ ] **Step 3: Group the Settings list by vendor**

In `App/SettingsView.swift`, replace `selected`, `visible` and the device rows.

```swift
    private var selected: DeviceRef? { model.selectedRef }

    /// Grouped by backend so a merged list of two radios still reads as two
    /// kinds of earbuds.
    private var groups: [(vendor: String, devices: [DiscoveredDevice])] {
        Dictionary(grouping: visible) { $0.id.backend }
            .map { (vendor: Self.vendorName($0.key), devices: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.vendor < $1.vendor }
    }

    private static func vendorName(_ backendID: String) -> String {
        switch backendID {
        case GaiaBackend.id: GaiaBackend.displayName
        case SamsungBackend.id: SamsungBackend.displayName
        default: backendID
        }
    }
```

`visible` keeps its existing logic and comment verbatim — the connected list is shown in full, scan results get the name filter.

Replace the `ForEach(visible)` block with a grouped one. Only render a header when there is more than one group, so a user with one brand sees the list they see today:

```swift
            ForEach(groups, id: \.vendor) { group in
                if groups.count > 1 {
                    Text(group.vendor)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                ForEach(group.devices) { device in
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
            }
```

The "Nothing found" copy mentions taking a bud out of the case, which is still right for both radios. Leave it.

- [ ] **Step 4: Build both targets**

Run: `swift build 2>&1 | tail -10`
Expected: no errors, no warnings.

Run: `xcodegen generate && xcodebuild -project BudsCtl.xcodeproj -scheme BudsCtl -configuration Debug build 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Run the suite**

Run: `swift test 2>&1 | tail -5`
Expected: unchanged, all passing.

- [ ] **Step 6: Run the app and check the two things that cannot be unit-tested**

Reinstall and launch. **`pkill BudsCtl` alone is not enough — the control extension keeps running stale code, so kill the appex too:**

```bash
pkill -f BudsCtlControls; pkill BudsCtl
open ~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/BudsCtl.app 2>/dev/null \
  || xcodebuild -project BudsCtl.xcodeproj -scheme BudsCtl -configuration Debug build
```

Then confirm:
1. Settings lists the Air4 Pro under a **SoundPEATS** header and your paired Galaxy Buds under a **Samsung** header.
2. The previously-selected Air4 Pro is still selected — the Task 1 migration working end to end.
3. Selecting and using the Air4 Pro still changes modes, exactly as before.

**This is the sandbox gate.** If the Samsung group is empty while `budsctl-cli` (unsandboxed, Task 10) does list the buds, `com.apple.security.device.bluetooth` is not covering IOBluetooth. Report it; the fallback is removing `com.apple.security.app-sandbox` from `App/BudsCtl.entitlements`, which is acceptable for DMG distribution but is the user's call, not yours.

- [ ] **Step 7: Commit**

```bash
git add Sources/BudsKit/Device/EarbudsBackend.swift App/BudsCtlApp.swift App/SettingsView.swift
git commit -m "feat: run both backends, merge discovery and route device selection"
```

---

### Task 10: CLI probe

`budsctl-cli samsung <mac>` prints every frame the buds send. This is how spec §2.5 gets settled against real hardware, and — being unsandboxed — how a protocol bug is told apart from a sandbox denial.

**Files:**
- Modify: `Sources/budsctl-cli/CLI.swift`

**Interfaces:**
- Consumes: `SamsungBackend`, `SamsungBackend.frames()`, `SppFrame`, `SppMessageID`, `SppFrame.events`, `DeviceRef`.
- Produces: nothing consumed elsewhere.

- [ ] **Step 1: Add the subcommand**

In `Sources/budsctl-cli/CLI.swift`, extend `usage()`:

```swift
      samsung [mac]      list paired Galaxy Buds, or connect and dump frames
```

Add to the `switch command` block:

```swift
            case "samsung": try await samsung(arguments.count > 1 ? arguments[1] : nil)
```

Add the implementation:

```swift
    /// Dumps everything a pair of Galaxy Buds sends.
    ///
    /// The reason this exists: byte 12 of EXTENDED_STATUS_UPDATED is the one
    /// offset in the protocol that was inferred from GalaxyBudsClient's
    /// model-branching parser rather than read off a capture. Connect, watch
    /// the connect-time frame, then change mode with a touch gesture and check
    /// that the NOISE_CONTROLS_UPDATE agrees with what byte 12 said.
    @MainActor
    static func samsung(_ mac: String?) async throws {
        let backend = SamsungBackend()
        backend.start()

        guard let mac else {
            let devices = backend.connectedDevices()
            guard !devices.isEmpty else { throw CLIError.message("No paired devices.") }
            for device in devices {
                print("\(device.name)  \(device.id.id)\(device.isLikelyMatch ? "  <- likely" : "")")
            }
            print("\nrun: budsctl-cli samsung <mac>")
            return
        }

        backend.onConnectionChange = { print("[connection] \($0.label)") }
        let frames = backend.frames()
        backend.adopt(DeviceRef(backend: SamsungBackend.id, id: mac))

        print("watching. change the mode by tapping a bud or from your phone. Ctrl-C to stop.")
        for await frame in frames {
            let name = frame.id.map(String.init(describing:)) ?? "unknown(\(frame.rawID))"
            let hex = frame.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
            let time = Date().formatted(date: .omitted, time: .standard)
            print("[\(time)] \(name) payload=\(hex)")

            // The interpretation this app would act on, so a wrong offset shows
            // up as a disagreement rather than as silence.
            let events = frame.events
            if !events.isEmpty { print("           -> \(events)") }
            if frame.id == .extendedStatusUpdated, frame.payload.count > 12 {
                print("           byte[12] = \(frame.payload[12]) "
                      + "(mode: \(ANCMode(rawValue: frame.payload[12])?.label ?? "out of range"))")
            }
        }
    }
```

- [ ] **Step 2: Build and check the listing path**

Run: `swift build 2>&1 | tail -5`
Expected: no errors.

Run: `swift run budsctl-cli samsung`
Expected: your paired devices, with any Galaxy Buds marked `<- likely`. The Air4 Pro appears here too — it is a paired classic device, it just does not speak SPP.

- [ ] **Step 3: Probe the hardware**

With Galaxy Buds FE paired and out of the case:

Run: `swift run budsctl-cli samsung <mac-from-step-2>`

Expected within a few seconds:
1. `[connection] Connected`.
2. An `extendedStatusUpdated` frame, with `byte[12]` printed and a plausible mode.
3. Battery events with sensible percentages.

Then take a bud and change mode with a touch-and-hold. Expect a `noiseControlsUpdate` frame.

**The check that matters:** does `byte[12]` from step 2 match the mode you were actually in? And does the `noiseControlsUpdate` after a gesture report the mode you landed on? If either disagrees, byte 12 is the wrong offset — record the full payload hex, and fix the index in `SppEvents.swift` plus its test's fixture. Everything else in the change is independent of it.

If no hardware is available, note it and stop here; `swift run budsctl-cli samsung` listing paired devices is the deliverable.

- [ ] **Step 4: Commit**

```bash
git add Sources/budsctl-cli/CLI.swift
git commit -m "feat: add budsctl-cli samsung probe for verifying the SPP protocol"
```

---

### Task 11: Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/manual-checklist.md`

**Interfaces:** none.

- [ ] **Step 1: Update the README**

The README currently says "Noise-cancellation control for SoundPEATS earbuds" and carries a "Tested with SoundPEATS Air4 Pro only" blockquote. Make three changes:

1. The tagline and the intro drop "SoundPEATS" for "your earbuds".
2. Replace the tested-with blockquote with a supported-devices table that keeps the same honesty — say what was verified and what merely shares a protocol:

```markdown
## Supported earbuds

| | Verified | Should work | How |
| --- | --- | --- | --- |
| **SoundPEATS** | Air4 Pro | other SoundPEATS models | Qualcomm GAIA V2 over Bluetooth LE |
| **Samsung Galaxy Buds** | Buds FE | Buds Pro, Buds2, Buds2 Pro, Buds3, Buds3 Pro, Buds3 FE, Buds Core, Buds4, Buds4 Pro | Samsung SPP over Bluetooth Classic RFCOMM |

> **Verified means one device each — the two I own.** Everything in the
> "should work" column shares a protocol with a verified device and is expected
> to work, but nothing else has been tested. If you try one, please
> [open an issue](../../issues) either way.
>
> **Not supported:** the original Galaxy Buds (2019) use different framing, and
> Buds+ and Buds Live use an older ambient-sound model rather than the
> three-way noise control this app is built around.
```

3. In "How it works (in plain terms)", note the second protocol. Keep the existing GAIA paragraph and add:

```markdown
Galaxy Buds work differently enough to be worth a sentence. They speak a Samsung
protocol over Bluetooth **Classic** RFCOMM rather than Bluetooth LE, so they go
through IOBluetooth instead of CoreBluetooth — and unlike the SoundPEATS buds,
they volunteer their full state the moment the connection opens and announce
every mode change, including ones you make by touch or from your phone. So there
is no "Reading mode…" guesswork for them: the protocol reverse-engineered by
[GalaxyBudsClient](https://github.com/timschneeb/GalaxyBudsClient) does the work,
and this app just listens.
```

- [ ] **Step 2: Update the manual checklist**

Append to `docs/superpowers/manual-checklist.md`, matching its existing formatting:

```markdown
## Galaxy Buds

Ten checks, in the order they are cheapest to run. Check 1 gates the rest.

1. **Sandbox.** The signed, sandboxed app lists paired Galaxy Buds in Settings.
   If `budsctl-cli samsung` lists them but the app does not,
   `com.apple.security.device.bluetooth` is not covering IOBluetooth — the
   fallback is dropping `com.apple.security.app-sandbox`, which is acceptable
   for DMG distribution.
2. Both brands appear in Settings, grouped by vendor, with the saved one
   selected.
3. Selecting the Galaxy Buds while the Air4 Pro is connected releases the BLE
   link — check the Air4 Pro stops responding to mode changes.
4. Selecting the Air4 Pro again releases the RFCOMM channel.
5. Mode set from the menu bar lands on the buds. Mode set by a touch gesture or
   the phone's Wearable app reaches the menu bar.
6. Battery for both sides appears within seconds of connecting, with no polling
   — Galaxy Buds push it.
7. Buds into the case shows "Waiting for earbuds"; out of the case reconnects
   with no user action. This is the `register(forConnectNotifications:)` path,
   which has no queued-connect safety net behind it.
8. Sleep and wake with the buds in your ears: the mode is still correct
   afterwards. This is `refresh()` reopening the channel.
9. The Control Center tile and all four Shortcuts intents work against Galaxy
   Buds, with no behaviour change from the SoundPEATS case.
10. An install upgraded from v1.2 keeps its selected Air4 Pro.
```

- [ ] **Step 3: Commit**

```bash
git add README.md docs/superpowers/manual-checklist.md
git commit -m "docs: document Galaxy Buds support and its manual checks"
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: §0–§1.2 → Task 3; §1.3–§1.4 → Task 6; §1.5 → Task 1; §2.1–§2.2 → Task 2; §2.3–§2.5 → Task 7; §3.1–§3.6 → Task 8; §4.1 → Tasks 2, 5, 7; §4.2 → Task 10; §4.3 → Tasks 9, 11; §5 enforced by the Global Constraints; §6 → Tasks 8, 11; §7 → Task 9's `Backends.all`.

**Two deviations,** both stated at the top of this plan rather than left to a reviewer to spot: `isLikelyMatch` moved from the protocol to `DiscoveredDevice`, and `refresh()` added as a third refresh hook.

**Compile-checked before writing.** Two things the plan asserts were verified rather than assumed: the whole IOBluetooth surface in Task 8 (including the `@MainActor` delegate conformance, which was the one thing I expected to argue back and did not), and two Swift patterns the test code leans on — switching an `Optional<SppMessageID>` against bare case patterns, and `if case` used as an expression inside a `contains` closure. That found one real error, now fixed: `IOBluetoothSDPUUID(bytes:length:)` is non-optional.

**Two risks remain, and neither is retirable from here.** Task 9 Step 6 is the App Sandbox gate — the entitlement is already present and is the documented one, but IOBluetooth under sandbox has only been confirmed *un*sandboxed; the escape hatch is one line and is the user's call, not the executor's. Task 10 Step 3 needs Galaxy Buds FE in hand to settle byte 12.

**Verification honesty.** Tasks 1–7 are fully unit-tested, no hardware. Tasks 8–9 are build-and-run. Task 10 Step 3 is the only step needing hardware, and it is the step that settles the one unverified protocol claim — so if hardware is unavailable, that claim stays open and the plan says so rather than pretending otherwise.

