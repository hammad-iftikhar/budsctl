# BudsCtl — connection lifecycle and reconnection

Technical specification. Supplements `2026-08-31-budsctl.md`, which assumed a
persistent BLE connection was always obtainable. It is not. This document
records what the hardware actually does, what was measured, what was ruled out,
and what shipped.

Everything below was measured against a real SoundPEATS Air4 Pro
(`98:80:BB:41:1A:93`, firmware `AIR4PRO-BS588R2E_20241112_v0.2.1`) on macOS
26.5.2, on 2026-09-01. Where a claim is inference rather than measurement, it
says so.

---

## 1. The behaviour

**The earbuds advertise their BLE control service only for a window.** Once they
have settled into a plain audio connection they stop advertising entirely.

Measured while the buds were connected as an audio device and playing normally:

| Probe | Result |
|---|---|
| Unfiltered `scanForPeripherals` (8 s) | no SOUNDPEATS seen at all |
| `retrieveConnectedPeripherals(withServices: [GAIA, 180F])` | empty |
| `retrievePeripherals(withIdentifiers: [saved UUID])` | returns the peripheral |
| `central.connect(peripheral)` | stays pending indefinitely |

`retrievePeripherals` succeeding while a scan sees nothing is the crux: the
peripheral is known to CoreBluetooth's cache, so the app has something to
connect *to*, but there is no advertisement for the connection to complete
against.

This is intermittent, not permanent. In one cold-start test the app connected
unattended in about 10 seconds with no intervention. The advertising window
appears to follow any (re)connection and close some time later; its exact
duration was not characterised.

### 1.1 Bluetooth service masks

Useful for diagnosis — `system_profiler SPBluetoothDataType`:

| Mask | Decoded | Meaning |
|---|---|---|
| `0x800019` | `HFP AVRCP A2DP ACL` | audio only, BudsCtl not connected |
| `0xC00019` | `HFP AVRCP A2DP BLE ACL` | BudsCtl holds the GAIA link |
| `0x802019` | `HFP AVRCP A2DP Braille ACL` | as above; the `0x2000` bit appears intermittently and is unexplained. "Braille" is `system_profiler`'s decode, almost certainly a mislabel |
| `0x800000` | `ACL` | classic link dropped, audio profiles gone |

The `BLE` bit (`0x400000`) is the reliable indicator of whether BudsCtl holds a
connection. **BLE and A2DP coexist without trouble** — observed together for
long stretches with audio playing normally.

---

## 2. What was ruled out

Recorded so nobody spends an afternoon rediscovering these.

### 2.1 Falling back to a scan — cannot work

The obvious fix for a stalled connect is to scan. A scan cannot find a device
that is not advertising, and §1 shows an 8 s unfiltered scan finds nothing.
Measured, not assumed.

### 2.2 GAIA over classic Bluetooth — blocked by macOS

The earbuds **do** expose GAIA over classic, on a link that stays up precisely
when BLE is unavailable. From their SDP records (11 total):

| Service | UUID | Transport |
|---|---|---|
| GAIA | `0000eb04-d102-11e1-9b23-00025b00a5a5` | **L2CAP PSM `0xFEFF`** |
| (related) | `0000eb05/eb06/eb07-d102-11e1-9b23-00025b00a5a5` | — |
| Serial Port | `0x1101` | RFCOMM channel 12 |
| Hands-Free | `0x111e` / `0x1203` | RFCOMM channel 10 |

Note the shared base with the BLE GAIA service
`00001100-d102-11e1-9b23-00025b00a5a5`. This is almost certainly how the vendor
phone app controls the buds during playback.

Every attempt to open a channel failed with `kIOReturnError` (`0xE00002BC`):

- `openRFCOMMChannelSync`, channel 12 — failed
- `openL2CAPChannelSync`, PSM `0xFEFF` — failed
- both again, binary signed with `com.apple.security.device.bluetooth` and team
  `JCXZ7458UT` — still failed

So it is not a signing, entitlement, or wrong-channel problem. macOS declines to
give a third-party process a control channel to a device it is using for audio.
**Do not retry without new information.** If it ever becomes possible it is the
best answer available: no audio interruption, works while settled, and would
make the BLE path optional.

### 2.3 Reconnecting only while nothing is playing — not detectable

The safe version of automatic reconnection would run only during silence. macOS
does not expose that. Measured on the default output device
(`SOUNDPEATS Air4 Pro`), idle versus during sustained playback:

| Property | idle | playing |
|---|---|---|
| `kAudioDevicePropertyDeviceIsRunning` | `false` | `false` |
| `kAudioDevicePropertyDeviceIsRunningSomewhere` | `true` | `true` |
| same, output scope | `true` | `true` |

Nothing changes. A connected Bluetooth audio device reads as permanently
running. Silence cannot be distinguished from playback, so automatic
reconnection cannot be made inaudible — only optional.

---

## 3. What shipped

### 3.1 An honest connection state

`central.connect` is unbounded by design; that pending connect *is* the
auto-reconnect mechanism. But nothing moved the UI off `.connecting`, so a
connect that would never complete looked identical to one about to succeed.

`GaiaClient` now starts a watchdog alongside each connect. After a 5 s grace —
comfortably longer than a real 1–3 s LE connect — a connect still pending
degrades to `.waiting` ("Waiting for earbuds"). The connect stays armed; only
the label changes. The watchdog is cancelled when the notify subscription lands
and when the peripheral is released.

### 3.2 Three routes back, cheapest first

Implemented in `App/ClassicLink.swift` and `AppModel`:

1. **Automatic and free.** If the earbuds are not the current audio output,
   dropping their link costs nothing audible. Always on, no setting.
2. **Automatic and audible.** *"Reconnect automatically when BudsCtl starts"*,
   **off by default**, stored in the app's own defaults. Costs a few seconds of
   silence, and §2.3 means we cannot know whether the user is mid-call, so it is
   opt-in.
3. **A Reconnect button** in the panel, shown only while `.waiting`, labelled
   *"interrupts audio briefly"*.

All three run the same sequence:

```
drop the classic link      → the buds start advertising
wait for .ready (≤ 12 s)   → the already-armed pending connect completes
restore the audio profiles → the user gets their output device back
```

**Restoring audio is mandatory, not politeness.** After the drop, macOS did not
bring the audio profiles back on its own — still absent after 30 s of sampling.
`ClassicLink.restoreAudio` re-opens the connection and asks the profiles to
attach. It logs `is not a hands free device but trying anyways` for buds that
present as a headset; it works regardless. The restore runs even when the
connect times out: leaving the user with no audio device would be far worse than
failing to connect.

### 3.3 Failures are visible

Whether IOBluetooth works from inside the app sandbox is **not yet verified** —
in every test so far the buds were advertising and the dance never needed to
run. Rather than ship a button that might silently do nothing, `AppModel`
surfaces the reason in the panel:

- `"<name> is not connected to this Mac."`
- `"macOS would not let BudsCtl disconnect the earbuds."` ← the sandbox refusing
- `"The earbuds did not come back. Put them in the case and take them out."`

`reconnectError` lives on `AppModel`, not `DeviceState`: `DeviceController` is
the sole writer of device state, and a failure to drive the classic radio is the
app's problem, not the device's.

---

## 4. Consequences for the original design

`2026-08-31-budsctl.md` chose a persistent warm connection because
"cold-starting on each click would make it feel broken". That still holds, and
the pending-connection model still works for the everyday path: with the app
running as a login item, taking the buds out of the case connects it unattended.
The plan's M1 milestone is met for that path.

What the original spec did not anticipate is a *cold start against settled
earbuds*, where there is nothing to connect to at all. That gap is what §3
closes.

---

## 5. Open questions

1. **Does IOBluetooth work under the app sandbox?** The entitlement
   `com.apple.security.device.bluetooth` is present and the code is written, but
   the path has never executed. First failure will say so in the panel.
2. **How long is the advertising window?** Not characterised. Knowing it would
   say whether waiting is ever a better strategy than dropping the link.
3. **What is the `0x2000` service bit?** Appears and disappears across sessions;
   no correlation established.
4. **One unexplained audio dropout.** The earbuds once vanished from the
   CoreAudio output list while BudsCtl was running; never reproduced. BLE and
   A2DP have since coexisted for long stretches, which weakens the
   radio-contention theory. `Tools/watch-audio.sh` logs the profile mask, the
   audio device's presence and whether BudsCtl is running, printing only on
   change, to catch the ordering if it recurs.

---

## 6. Diagnostics

```bash
./Tools/watch-audio.sh ~/budsctl-audio.log   # log every profile/audio change
swift run budsctl-cli status                 # prints connection transitions
system_profiler SPBluetoothDataType | grep -A6 SOUNDPEATS   # service mask
```

`budsctl-cli` keeps its own saved peripheral, separate from the app's, so it can
be run while the app is stopped without disturbing the app's state.
