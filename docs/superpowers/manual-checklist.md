# BudsCtl manual checks

Run after any change to `GaiaClient`, `StateBridge`, or the extension. The unit
suite covers frame encoding and the controller's timing; these cover the things
only a real device and two real processes can show.

**No agent working on this project has ever performed hardware verification.**
Every checklist item below that involves real earbuds, Control Center,
Shortcuts, a reboot, or `/Applications` is unverified — including plan Task 7's
M1 pending-connection pass, the single highest-risk unverified item in the
project (see "Outstanding from the build" below). Agents are restricted to
`swift build`, `swift test`, `xcodegen generate`, `xcodebuild ... build`, and
`swift run budsctl-cli symbols`; nothing past that line has been exercised
against real hardware or a real GUI session by anyone. Treat every checkbox
below as open until a human actually runs it.

## Every time

- [ ] `swift test` — all green.
- [ ] `swift run budsctl-cli symbols` — no MISSING lines.
- [ ] Build, copy to /Applications, relaunch. Menu bar icon appears, no Dock icon.
- [ ] Change mode from the picker. Instant optimistic move, spinner, settles in ~1.4 s.
- [ ] Tap a bud. Menu bar follows within 2 s.
- [ ] Click the Control Center control. Mode changes, label updates.

## The three that have historically hidden bugs

- [ ] **Reboot with the buds in the case, then use Control Center.**
      Boot, do not open BudsCtl, take a bud out, click the control.
      Must change mode. Covers login item + pending connection + cold bridge.
- [ ] **Change mode on the phone and watch the Mac follow.**
      Covers the unsolicited-notification path that keeps the UI truthful.
- [ ] **Sleep the Mac for an hour, then switch mode immediately on wake.**
      Covers a stale-but-alive link. The first click after wake must work,
      not merely the second.

## After changing the bridge

- [ ] Quit BudsCtl, click a Control Center control. The agent must launch and
      apply the change — never silently no-op.
- [ ] Quit BudsCtl (the panel's "Quit BudsCtl" button — confirm with `ps` or
      Activity Monitor that the process is actually gone, not just that the
      menu bar icon vanished), then run the Shortcuts action "Get Noise Mode."
      Correct: it reports "Disconnected," never the mode the buds were last
      showing while the agent was alive. Covers the disconnected snapshot the
      agent publishes on `NSApplication.willTerminateNotification` before it
      dies — without it, Shortcuts and Control Center would keep reporting a
      live mode and a stale battery for a process that no longer exists.
- [ ] `log show --last 2m --predicate 'process == "BudsCtlControls"' | grep -i bluetooth`
      must be empty. The extension must never open a connection.

---

## Outstanding from the build — never verified against hardware

Every task from 7 through 13 built code whose correctness rests on an assumption
that only physical earbuds, a GUI session, or a reboot can confirm. None of that
verification has happened — no agent in this build was permitted to touch
`/Applications`, `open` a GUI app, or reboot the machine. This section is the
consolidated, deduplicated hand-off list, ordered by how much of the
architecture depends on the answer.

### The three that matter most

1. **The M1 pending-connection test — do this first.** With BudsCtl (or
   `budsctl-cli`) not connected and the buds in the *closed* case, run
   `swift run budsctl-cli set anc`. It should print something like "Waiting
   for earbuds" and hang. Open the case and remove a bud. The connection must
   complete on its own — via `retrievePeripherals(withIdentifiers:)` plus a
   pending `connect`, with **no** scan — and the `set anc` must go through,
   printing `confirmed anc after ~1.4s`, with no case-lid dance beyond opening
   it once. **Note the CLI's connection wait now genuinely times out after
   20 s** (fixed since the original spike), so open the case within that
   window or the command will report a timeout instead of testing the real
   path. **If the pending connection does not pick up the reconnect on its
   own, stop and report — do not patch around it.** The entire agent
   architecture (no polling, no rescanning after first run) rests on this
   working. This is the single highest-risk unverified item in the project.

2. **Cold-start launch from Control Center or Shortcuts.** With BudsCtl not
   running (`killall BudsCtl` after confirming it's the login-item build, not
   a manual `open`), click the Control Center control (or run a Shortcuts
   action). Correct: the agent launches automatically and the mode change
   goes through — never a silent no-op, never a "nothing happened." This
   rests entirely on `supportedModes: [.background, .foreground(.dynamic)]`
   on the App Intents, which the extracted `Metadata.appintents` build
   artifact confirms is present and recognized by the toolchain — but that is
   static evidence only. It has never been exercised at runtime. If it fails,
   the fallback is the same one listed below for Shortcuts visibility:
   re-declare the intents as thin wrappers directly in the launching target.

3. **The Shortcuts actions appear at all.** Open Shortcuts.app, search for
   "Set Noise Mode," "Cycle Noise Mode," "Get Noise Mode," and "Get Earbud
   Battery" under BudsCtl. Correct: all four appear, "Set Noise Mode" offers
   an Off / Noise Cancellation / Transparency picker, and running it changes
   the buds within ~2 s while the menu bar panel agrees. **If none of the four
   actions appear within about an hour of the app having been launched at
   least once from `/Applications`** (not from DerivedData — that matters),
   the fix is plan Task 10 Step 7: duplicate the four intent structs as thin
   wrappers directly in the app and extension targets, rather than relying on
   `ExtractAppIntentsMetadata` picking them up from the dynamic `BudsKit`
   package.

### Everything else, roughly in descending order of how load-bearing it is

4. **Basic install/launch sanity.** Build, `cp -R` the app to `/Applications`,
   `open` it. Correct: an ear-glyph menu bar icon appears, no Dock icon, no
   window. Opening Settings shows nothing about shared storage at all — a
   working install is silent on this point. The orange caption "Shared
   storage unavailable — Control Center and Shortcuts cannot see this app's
   state." should appear ONLY if the App Group failed to provision, which is
   not expected to happen on this machine's signing setup (see the note near
   the bottom of this file). Quit from the panel's "Quit BudsCtl" button
   actually terminates the process — verify with `ps` or Activity Monitor,
   not just that the menu bar icon disappeared.

5. **First-run device discovery.** With a bud out of the case and no device
   previously chosen, open the panel/Settings. Correct: the SOUNDPEATS entry
   is listed with no scan (or the explicit "Scan for More…" escape hatch is
   used deliberately), and clicking it reaches `Connected` with mode, battery,
   and firmware populated within a few seconds.

6. **Optimistic UI timing.** Click a different mode segment. Correct: the
   picker moves instantly, an "Applying…" state with a pulsing menu bar glyph
   shows, and it settles ~1.4 s later with no snap-back-then-forward.

7. **M2 exit test — external changes reach the menu bar.** With the panel
   closed, change mode by tapping a bud or from the phone app. Correct: the
   menu bar glyph updates within 2 s with zero Mac interaction, and the
   panel's picker agrees the next time it's opened.

8. **Disconnect path.** Close the case with both buds inside. Correct: within
   a few seconds the panel shows "Waiting for earbuds," the picker disables,
   battery shows `—`, the last known mode is retained (not cleared), and
   reopening the case reconnects with no click required.

9. **Control Center: the control can be added.** Control Center → Edit
   Controls → search "Earbuds." Correct: "Earbuds Noise Mode" (the cycle
   control) appears and can be added. See the note below — only this one
   control exists; do not go looking for three.

10. **M3 exit test — the control actually cycles modes.** With the app
    running and buds connected, click the control three times slowly.
    Correct: off → noise cancellation → transparency → off, each landing
    within ~2 s, with the control's own label and the menu bar panel agreeing
    at every step.

11. **The control reflects externally-driven changes.** Tap a bud to change
    mode, then open Control Center without touching the control. Correct: the
    control's label already shows the new mode.

12. **The extension never touches Bluetooth at runtime.** After the extension
    has actually run at least once, `log show --last 2m --predicate 'process
    == "BudsCtlControls"' | grep -i bluetooth` must return nothing. (A static
    equivalent — grepping the extension's binary and target sources for any
    CoreBluetooth import or symbol — was already done and came back clean;
    this is the runtime confirmation of that same property.)

13. **Login-item toggle.** In the panel, tick "Launch at login." Correct: it
    takes effect on the *first* tap (no toggle-twice bug), approves in System
    Settings if prompted, and `launchctl print gui/$(id -u) | grep -i budsctl`
    (or System Settings ▸ General ▸ Login Items) shows it registered,
    matching the checkbox state.

14. **M4 exit test — full reboot.** Reboot without opening BudsCtl manually.
    Take a bud out of the case, click the Control Center control. Correct:
    the menu bar icon is already present (proving the login item registered
    and survived the reboot) and the mode changes. This overlaps with, and
    subsumes, the "Reboot with the buds in the case" item in the checklist
    above — running it once covers both.

15. **The M5 edge-case matrix (spec §7, 12 rows).** None of these have been
    run:
    1. Buds in case / powered off — close the case. Expected: "Waiting for
       earbuds," picker disabled, battery `—`, and no scanning shows up in
       `log stream --predicate 'process == "BudsCtl"' | grep -i scan`.
    2. Buds come out of the case — open it. Expected: reconnects with no
       clicks; mode and battery repopulate.
    3. Mode changed by tapping a bud. Expected: menu bar glyph and Control
       Center label both follow within ~2 s.
    4. Mode changed from the phone app. Expected: same as row 3.
    5. Buds connected to the phone only — connect them to the phone, play
       audio, then try the picker. Expected: "In use by another device," and
       the UI reconciles to the truth rather than showing the failed target.
    6. Bluetooth turned off in Control Center. Expected: "Bluetooth is off"
       plus a working "Open Bluetooth Settings" button.
    7. Mac sleeps and wakes — sleep for a minute, change mode from the phone
       while asleep, then wake. Expected: the panel shows the mode the phone
       set, not the pre-sleep one.
    8. Buds re-paired — forget them in System Settings ▸ Bluetooth, pair
       again. Expected: the panel returns to "No earbuds selected," and
       offers the device list rather than spinning on the dead identifier.
    9. Rapid repeated clicks across all three picker segments. Expected:
       settles on the last one clicked, no oscillation, no stuck spinner.
    10. Set silently lost — **already covered** by the "no notification falls
        back to one getter read" and "a device that ignores the set is
        reported honestly, not optimistically" unit tests (both pass, part of
        the 64 green). Skip manually.
    11. Firmware update changes the protocol — **already covered** by the
        "unexpected firmware is warned about, not refused" and "known-good
        firmware raises no warning" unit tests. Skip manually verifying the
        warning logic, but do confirm the real firmware string shown in the panel
        matches `AIR4PRO-BS588R2E_20241112_v0.2.1`, or that a mismatch
        produces the warning rather than a refusal to run.
    12. Two Macs — optional, needs a second Mac. Expected: each Mac holds its
        own identifier and both may hold a link simultaneously.

16. **Global hotkey (⌥⌘N).** With another app focused, press it. Correct: the
    mode cycles off → ANC → transparency exactly like the Control Center
    control, with no focus steal (the foregrounded app keeps focus). Then
    open the panel's shortcut recorder and confirm it shows ⌥⌘N and accepts a
    rebind.

17. **CLI firmware/discovery sanity.** `swift run budsctl-cli discover` with
    the buds out of the case: a `SOUNDPEATS`-named entry appears marked
    `<- likely`, the macOS Bluetooth permission prompt appears on first run,
    and selecting it works. `swift run budsctl-cli status`: the printed
    firmware string should read `AIR4PRO-BS588R2E_20241112_v0.2.1` — if it
    differs, stop and note it before doing anything else, since the whole
    protocol was reverse-engineered against that exact firmware. If
    `discover` finds nothing and no permission prompt ever appears, check
    `otool -s __TEXT __info_plist .build/debug/budsctl-cli` for the embedded
    `NSBluetoothAlwaysUsageDescription` — a missing plist section means
    CoreBluetooth is silently denied, with no visible error.

18. **CLI passive-listener sanity (`watch`).** Run `swift run budsctl-cli
    watch`, then change mode by tapping a bud, then again from the phone
    app. Correct: a `getMode` line prints within about 2 s of each change,
    with **no write issued by the CLI itself** at any point. This is
    distinct from item 7 above (the menu bar following an external change)
    — it verifies the unsolicited-notification path at the CLI/transport
    layer directly, and specifically that a passive listener causes zero
    writes, which is the most direct observable form of the project's
    "never poll the mode" constraint.

### Two things the plan gets wrong or doesn't mention — worth knowing before you start

- **Only one Control Center control ships**, not three. macOS 26.5 has no
  `ControlWidgetBundle`, and its control-configuration builder accepts a
  single configuration — so the plan's idea of three direct-mode controls
  (one per mode) is not implementable in one extension. What exists is the
  single cycle control described in items 9–11 above. Do not go looking for
  the other two; they were never buildable, not merely unverified.
- **App Groups provision fine on the free personal team — the shared-file
  fallback was never built, and there is no `SharedFileStore` to fall back
  to.** The plan sketched a `SharedFileStore`/`KeyValueStore` abstraction in
  case `com.apple.security.application-groups` didn't survive signing under a
  free/personal Apple ID. It was never needed: Task 8 extracted the signed
  entitlements from both the app and extension binaries with
  `codesign -d --entitlements` and confirmed the App Group capability is
  present and intact in both, and `StateBridge` talks to `UserDefaults`
  directly with no store abstraction in between. If a future change to
  signing or team status ever breaks this, do not expect to "enable" a
  fallback — none exists in the code. The sketch in the Task 8 section of the
  plan is a starting point for writing one, not a switch to flip.
