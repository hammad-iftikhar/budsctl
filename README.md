# BudsCtl

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

## Protocol

GAIA V2 over BLE, reverse engineered for interoperability from traffic to a
device the author owns. See `docs/superpowers/specs/main.md` §1. Verified
against firmware `AIR4PRO-BS588R2E_20241112_v0.2.1`.
