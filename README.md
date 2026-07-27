# HIDTouch

[![CI](https://github.com/koshi545/HIDTouch/actions/workflows/ci.yml/badge.svg)](https://github.com/koshi545/HIDTouch/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)](#requirements)

A userspace driver and calibration studio that makes unsupported USB HID touch
panels work on macOS.

[日本語版 README](README.ja.md)

macOS has no built-in support for generic USB HID digitizers. Plug in one of the
cheap portable touch monitors and you get a display that works and a touch layer
that does nothing. HIDTouch reads the panel's raw HID reports, maps them onto a
display with a calibrated affine transform, and delivers the result to macOS as
cursor and scroll events.

No kernel extension, no DriverKit — it runs entirely in userspace on top of
`IOHIDManager` and `CGEvent`.

> Unaffiliated with, and not derived from, any commercial touch driver product.

---

## Status

Developed against a **WingCool Inc. TouchScreen (VID `0x27C6`, PID `0x0529`)**,
a Win8-compliant digitizer used in several portable touch monitors. Nothing in
the code is specific to that panel — the report layout is derived from the
device's own HID report descriptor at runtime — but that is the only hardware it
has been verified on.

| Feature | Status |
|---|---|
| Raw HID packet inspection | ✅ |
| Report format configuration (GUI) | ✅ |
| 4-point affine calibration | ✅ |
| Multi-display targeting | ✅ |
| Multi-touch parsing (up to 10 contacts) | ✅ |
| One finger → cursor move + click | ✅ |
| Two fingers → scroll | ✅ |
| Three or more fingers | tracked and visualised only |
| Pinch / rotate as native gestures | ❌ not implemented (see [Output-side limits](#output-side-limits)) |
| `IOHIDUserDevice` virtual digitizer | ❌ blocked on an Apple-issued entitlement |

---

## Requirements

- macOS 13 (Ventura) or later
- Swift 5.9+ (Xcode Command Line Tools are sufficient — Xcode itself is not required)
- A USB HID touch panel

---

## Build

```bash
swift build -c release
```

To produce the GUI as a signed `.app` bundle:

```bash
./build_app.sh          # -> dist/HIDTouch Studio.app
```

`build_app.sh` runs the self-test suite before it packages anything, and reports
the resulting designated requirement so you can tell whether your permission
grants will survive the next rebuild. See
[Permissions and code signing](#permissions-and-code-signing).

---

## Quick start

### 1. Inspect the raw packets

```bash
swift run hidtouch-daemon --inspect
```

This enumerates HID devices and hex-dumps their input reports. It neither seizes
devices nor injects events, so it is safe to leave running.

Devices are listed **per interface**. A touch panel typically publishes three
interfaces under one VID/PID — Mouse (`0x01`/`0x02`), Digitizer (`0x0D`/`0x02`)
and a vendor-defined one (`0xFF00`) — and telling them apart is the whole game.

### 2. Set it up in HIDTouch Studio

```bash
open "dist/HIDTouch Studio.app"     # or: swift run hidtouch-studio
```

1. **Dashboard** — pick your panel under *Driver Input Device*. Auto-detection
   works, but pinning the VID/PID explicitly is more reliable.
2. **HID Inspect** — touch the panel and watch the hex dump. Count which byte
   offsets carry X, Y and the tip-switch state. *Pause* freezes the stream so
   you can read it.
3. **Report Format** — enter those offsets. Changes apply immediately; if
   *Current Raw Point* on the Dashboard follows your finger, you got it right.
4. **Calibrate** — touch four crosshairs shown full-screen on the target
   display. The mean residual is reported afterwards; a few pixels is good.
5. Switch the output mode in the header to **Mouse Emulation (CGEvent)** to
   start controlling the cursor.

> The default output mode is **Debug / Log Only** on purpose. Enabling injection
> before calibrating leaves the transform at identity, which sends the cursor to
> raw sensor coordinates and can make the machine hard to recover.

### 3. Run the driver in the background

The daemon reuses the configuration Studio wrote.

```bash
swift run hidtouch-daemon
```

### 4. Verify the core logic

```bash
swift run core-selftest
```

XCTest and swift-testing ship with Xcode rather than the Command Line Tools, so
the checks are a plain executable target instead. They cover affine transform
recovery and degeneracy detection, parser boundary conditions, config forward
compatibility, and device classification against a table of real observed
devices.

---

## Permissions and code signing

Grant **Input Monitoring** and **Accessibility** in
*System Settings → Privacy & Security*. Without them, devices still enumerate
but no input reports ever arrive and you get
`IOHIDManagerOpen failed (kr=0xE00002E2)` in the log.

### Why grants keep disappearing

macOS keys these grants to the binary's **code signature**, not its path.

```console
$ codesign -d -r- "dist/HIDTouch Studio.app"
# designated => cdhash H"8810fec1a40b08cf894ad9da834923178a3dd6b0"
```

With an ad-hoc signature (identity `-`) the designated requirement is the
**CDHash**, which changes whenever a single byte of the build changes. Every
rebuild is therefore a *different application* as far as TCC is concerned, and
previously granted permissions silently stop applying.

Worse, the app stays listed and enabled in System Settings, so it looks like the
permission is granted when it is not. When that happens you must **remove the
entry and add it again** — toggling it off and on is not enough.

The Studio's Dashboard shows the live grant state alongside the current CDHash,
which is the quickest way to tell whether the signature moved out from under you.

### Making grants survive rebuilds

The designated requirement has to reference a certificate rather than a hash. If
you have a Developer ID:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build_app.sh
```

Without an Apple Developer Program membership, a **self-signed code signing
certificate** achieves the same thing. `build_app.sh` picks it up automatically
if it is named `HIDTouch Local Signing`:

```console
$ codesign -d -r- "dist/HIDTouch Studio.app"
designated => identifier "com.reo.hidtouch.Studio" and certificate root = H"<your certificate hash>"
```

Because the requirement names the certificate root, a changed CDHash no longer
matters and **grants persist across rebuilds**.

To create that certificate — note that macOS's Security framework rejects the
PKCS#12 MAC algorithm OpenSSL 3.x uses by default, which is why `-macalg sha1`
and `-legacy` are mandatory:

```bash
# 1. Key + self-signed certificate, marked for code signing
openssl req -x509 -newkey rsa:2048 -keyout k.key -out c.crt -days 3650 -nodes \
  -subj "/CN=HIDTouch Local Signing/O=HIDTouch/C=JP" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# 2. Convert to a PKCS#12 macOS can actually read
openssl pkcs12 -export -out c.p12 -inkey k.key -in c.crt \
  -name "HIDTouch Local Signing" \
  -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -legacy \
  -passout pass:hidtouch

# 3. Import into the login keychain
security import c.p12 -k ~/Library/Keychains/login.keychain-db -P hidtouch \
  -T /usr/bin/codesign -T /usr/bin/security

# 4. Destroy the plaintext key — it now lives in the keychain
rm -f k.key c.p12 c.crt
```

> `security find-identity -v -p codesigning` will *not* list this certificate,
> because no trust settings were added. `codesign` uses it regardless, so adding
> trust (which needs an admin password) is unnecessary.

The **first** build after importing will stop with a keychain dialog —
*"codesign wants to sign using key "HIDTouch Local Signing" in your keychain"* —
and hang until it is answered. Click **Always Allow**, not Allow, or every
subsequent build stops in the same place. `security import -T` populates the
item's trusted-application list but not its ACL partition list, which is what
macOS actually consults.

The non-interactive equivalent, if a dialog is not an option (headless, CI):

```bash
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -l "HIDTouch Local Signing" ~/Library/Keychains/login.keychain-db
```

It prompts for the keychain password; passing it as `-k <password>` instead
works but puts the password in your shell history.

To go back to ad-hoc, delete `HIDTouch Local Signing` in Keychain Access or run
`SIGN_IDENTITY=- ./build_app.sh`.

Changing the bundle identifier also invalidates existing grants, since the
identifier is part of the designated requirement.

---

## Architecture

```text
HIDTouch/
├── Package.swift
├── build_app.sh                     # bundle + sign the GUI
└── Sources/
    ├── CHIDUserDevice/              # C shim bridging IOHIDUserDevice to Swift
    │   ├── VirtualHIDHelper.c
    │   └── include/VirtualHIDHelper.h
    ├── HIDDriverCore/               # shared driver core
    │   ├── HIDDeviceMonitor.swift   # IOHIDManager capture + device classification
    │   ├── HIDReportDescriptor.swift# report descriptor walker, multi-touch layout
    │   ├── HIDParser.swift          # single-contact report parser
    │   ├── MultiTouchParser.swift   # multi-contact report decoding
    │   ├── GestureRecognizer.swift  # contact count -> pointer / scroll
    │   ├── CalibrationEngine.swift  # least-squares affine matrix
    │   ├── JitterFilter.swift       # EMA smoothing + deadband
    │   ├── TouchPipeline.swift      # parse -> calibrate -> filter -> inject
    │   ├── CGEventInjector.swift    # CGEvent cursor and scroll output
    │   ├── VirtualHIDDevice.swift   # IOHIDUserDevice output (entitlement-gated)
    │   ├── DisplayHelper.swift      # display enumeration, coordinate spaces
    │   ├── Permissions.swift        # TCC state and signature introspection
    │   ├── Log.swift                # os_log wrapper
    │   └── ConfigManager.swift      # JSON config persistence
    ├── TouchDaemon/                 # headless CLI driver
    ├── TouchStudio/                 # SwiftUI configuration GUI
    │   ├── TouchStudioApp.swift     # entry point + AppViewModel
    │   ├── CalibrationWindow.swift  # full-display calibration overlay
    │   └── ContentView.swift        # dashboard, inspector, settings, canvas
    └── CoreSelfTest/                # core logic checks
```

Configuration is persisted to
`~/Library/Application Support/HIDTouch/config.json`.

---

## Technical notes

These are the non-obvious things that cost real debugging time. They are
documented here because none of them are well covered elsewhere.

### Run loop mode is not optional

HID sources **must** be scheduled in `CFRunLoopMode.commonModes`. Registering
them only in `defaultMode` makes the application deadlock against itself:

1. A touch arrives; the driver posts a `mouseDown` via `CGEvent`.
2. A control **in its own UI** receives it, and AppKit enters a tracking loop in
   `NSEventTrackingRunLoopMode`.
3. Sources registered only in `defaultMode` are not serviced in that mode, so
   HID reports stop arriving.
4. The report saying the finger lifted is never read, so no `mouseUp` is posted.
5. AppKit waits forever for a `mouseUp` that cannot come.

The symptom is oddly specific: **only this app's own UI stops responding to
touch**, while other applications and the physical mouse work fine. Other apps
have their own run loops, and real mouse events arrive through the window server
rather than through this process.

For the same reason, the timers that defer a release use
`RunLoop.main.add(timer, forMode: .common)`. `DispatchQueue.main.asyncAfter` is
not guaranteed to fire during tracking.

### What a synthetic click requires

Three conditions have to hold before `CGEvent` produces a click AppKit accepts:

- **Set `kCGMouseEventClickState` to 1.** Without it `NSEvent.clickCount` is 0
  and controls simply ignore the press.
- **Do not put `mouseDown` and `mouseUp` in the same event cycle.** The release
  gets dropped and the button stays stuck down. `minimumPressDuration`
  guarantees a 40 ms floor.
- **Post both at the same coordinates.** Otherwise it reads as a drag.

Panels also emit a single empty frame mid-touch fairly often, so a lift is only
honoured after `liftDebounce` (30 ms by default). Without that, clicks break
apart and drags get chopped in two.

### Waking up a Win8 digitizer

A Win8-compliant panel stays in single-contact mouse-emulation mode until the
host writes `0x02` to Device Mode (`0x52`) inside the Device Configuration
feature report (Digitizer usage `0x0E`). macOS never sends this, which is why
the digitizer interface appears silent.

Writing it once at enumeration is not enough, and **the readback cannot be
trusted**. The panel this was developed against accepts the write, reports
Device Mode `0x02` when read back, and then reverts to `0x00` a second or two
later as it finishes its own initialisation — so the register claims multi-touch
while the hardware keeps emitting mouse-emulation packets. A driver that reads
`0x02`, writes `0x02` and declares success leaves multi-touch dead with nothing
in the logs to say so. Writing the value the register already holds may also be
a no-op inside the firmware, so the target mode is always approached through an
explicit `0x00`.

The only trustworthy evidence is whether the digitizer actually speaks, so that
is what HIDTouch keys on:

- it re-arms on a timer until the digitizer produces a report (five tries, 2.5 s
  apart), which covers the reversion window without having to guess one correct
  delay;
- a touch arriving on the panel's **mouse** collection while its digitizer has
  never reported is proof the panel is in mouse-emulation mode, and triggers an
  immediate re-arm with its own attempt budget.

That second rule is also what restores multi-touch after sleep/wake or a USB
re-enumeration power-cycles the panel — the recovery follows what the hardware
is doing, so it needs no power notifications and no guesses about which events
reset a panel.

Both buffer conventions (`[reportID, mode, id]` and `[mode, id]`) are tried,
because which one a panel expects is not consistent.

Contact block layout differs between panels — some carry pressure, width and
height — so `HIDReportDescriptor` parses the report descriptor to derive contact
count, per-field bit offsets and logical ranges rather than hardcoding them. The
derived layout is shown in the Dashboard's *Multi-Touch* section.

### Output-side limits

**macOS exposes no public API for injecting multi-touch.**

`IOHIDUserDeviceCreate` requires the restricted entitlement
`com.apple.developer.hid.virtual.device`, which Apple grants per developer team
and which must be embedded in a provisioning profile. Ad-hoc and self-signed
builds cannot obtain it. Selecting Virtual Multi-Touch when the device cannot be
created falls back to mouse emulation and shows a warning on the Dashboard.

Native pinch and rotate gestures are technically reachable through undocumented
`CGEvent` gesture fields, but those carry no compatibility guarantee across
macOS releases and are deliberately not used here.

### Tracing events

Posted events can be reconciled against what actually got delivered. This is off
by default, since it logs on every click and the receiving side observes other
applications' events too.

```bash
HIDTOUCH_EVENT_TRACE=1 "dist/HIDTouch Studio.app/Contents/MacOS/TouchStudio"

# in another terminal (full path required — zsh has a `log` builtin)
/usr/bin/log show --last 2m --info \
  --predicate 'subsystem == "com.reo.hidtouch"' --style compact | grep EVT
```

A healthy trace pairs each `posted DOWN` with a `posted UP` and a `local UP`. If
`posted` appears without `local`, delivery is failing; if `local` appears but
nothing responds, the receiver is interpreting it differently than expected.

### Device seizing

Devices classified as touch panels are opened with
`kIOHIDOptionsTypeSeizeDevice`, so macOS's own driver cannot move the cursor
from the same reports. Keyboards and mice are never seized. This can be disabled
in the Report Format tab.

Note that devices are opened **individually** rather than through
`IOHIDManagerOpen`. A manager-level open is all-or-nothing — one device held
exclusively by another process (Karabiner-Elements, for instance) makes it fail
with `kIOReturnExclusiveAccess` — and it also holds a non-exclusive claim that
defeats per-device seizing.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Devices enumerate but no reports arrive | Input Monitoring not granted, or granted to a stale signature |
| Permission looks granted but nothing works | CDHash changed on rebuild — remove the entry and re-add it |
| Cursor jumps to a corner or off-screen | Not calibrated yet; the transform is still identity |
| Cursor moves on the wrong display | Wrong target display selected on the Dashboard |
| The panel's digitizer interface is silent | Win8 device mode was not accepted — check the Multi-Touch section |
| Only this app's UI ignores touch | HID sources not in `commonModes` (see above) |

---

## License

MIT. See [LICENSE](LICENSE).
