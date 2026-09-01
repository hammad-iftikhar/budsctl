# BudsCtl

![BudsCtl menu bar panel](docs/screenshots/panel.png)

macOS menu bar control for SoundPEATS Air4 Pro noise modes — normal, ANC, and
transparency — from the menu bar, Control Center, Shortcuts, and a global
hotkey (⌥⌘N).

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project BudsCtl.xcodeproj -scheme BudsCtl -configuration Debug \
  -derivedDataPath .build/xcode build
cp -R .build/xcode/Build/Products/Debug/BudsCtl.app /Applications/
open /Applications/BudsCtl.app
```

`project.yml` is the source of truth; `BudsCtl.xcodeproj` is a build artifact
and is not committed. Same for `App/Info.plist` and `Controls/Info.plist`.

## Test

```bash
swift test                       # frame codec, state, bridge, controller — 59 tests
swift run budsctl-cli status     # against real hardware
```

`docs/superpowers/manual-checklist.md` covers what tests cannot.

## Layout

- `Sources/BudsKit` — protocol, state, BLE client, controller, bridge, intents.
  Everything interesting lives here and most of it is tested without hardware.
- `Sources/budsctl-cli` — diagnostic tool; also how the BLE layer was proven.
- `App` — the LSUIElement agent. Owns the one Bluetooth connection.
- `Controls` — Control Center extension. Reads cached state, posts requests,
  never touches CoreBluetooth. Ships one control (cycle mode) — macOS 26.5
  has no `ControlWidgetBundle`, and its control-configuration builder takes a
  single configuration, so per-mode direct controls are not implementable in
  one extension.

## Connecting

The earbuds advertise their BLE control service only for a window after they
leave the case. Once they have settled into a plain audio connection they stop
advertising entirely — verified by an unfiltered LE scan that sees nothing while
they are happily playing music.

So:

- **App already running, buds taken out of the case** — connects on its own.
  This is the normal path, and it is why the app is a login item.
- **App started while the buds are already out and settled** — it cannot
  connect, and shows "Waiting for earbuds". Put them in the case and take them
  out again.

A pending `connect` is left armed the whole time, so the moment the buds
advertise again it completes with no interaction. Falling back to a scan would
not help: a scan cannot find a device that is not advertising.

When it is stuck, the panel offers **Reconnect**, which drops the classic link
so the buds advertise again and then puts the audio back. Settings has an
opt-in to do that automatically at launch; it is off by default because it costs
a few seconds of silence. When the earbuds are not the current audio output it
happens automatically anyway, since nothing audible is lost.

`docs/superpowers/specs/2026-09-01-connection-lifecycle.md` has the measurements
behind all of this, including why GAIA over classic Bluetooth is not used.

## Protocol

GAIA V2 over BLE, reverse engineered for interoperability from traffic to a
device the author owns. See `docs/superpowers/specs/2026-08-31-budsctl.md` §1. Verified
against firmware `AIR4PRO-BS588R2E_20241112_v0.2.1`.
