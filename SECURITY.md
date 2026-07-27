# Security

## What this software has access to

HIDTouch needs two macOS privacy permissions to do its job, and it is worth
being explicit about what they mean:

- **Input Monitoring** — required to receive HID input reports. This is what
  lets the driver read your touch panel. It is also, by design, the permission
  that would let a process read keyboards and other input devices.
- **Accessibility** — required to post cursor, click and scroll events.

Devices classified as touch panels are opened with
`kIOHIDOptionsTypeSeizeDevice`. Keyboards and mice are never seized. Device
classification lives in `Sources/HIDDriverCore/HIDDeviceMonitor.swift` and is
covered by the self-test suite.

Event tracing (`HIDTOUCH_EVENT_TRACE=1`) installs a global `NSEvent` monitor,
which observes mouse events belonging to other applications. It is off by
default and only writes to `os_log` — nothing leaves the machine.

The driver makes no network connections. Its only persistent state is
`~/Library/Application Support/HIDTouch/config.json`.

## Code signing

Builds are signed locally, with a self-signed certificate or ad-hoc. There is
no notarised release, so binaries are not distributed — build from source and
read what you are running.

## Reporting a vulnerability

Open a [security advisory](https://github.com/koshi545/HIDTouch/security/advisories/new)
rather than a public issue.

This is a personal project with no service-level commitment, so please do not
expect a fixed response window.
