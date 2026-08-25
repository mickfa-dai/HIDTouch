# Samsung Flip Pro WM55B / LH55WMB with HIDTouch on macOS

Verified working on 2026-08-24.

## Tested environment

- Samsung Flip Pro WM55B / LH55WMB
- SyncMaster target, 1920 × 1080
- Samsung HID Multi-Touch
- Direct USB-C
- Apple Silicon MacBook Pro
- macOS 26
- HIDTouch output: Mouse Emulation (CGEvent)
- Calibration residual: approximately 0.3 px

## Verified

- Four-point calibration
- One-finger operation
- Microsoft Whiteboard drawing
- Multi-touch detection
- Two-finger pinch-to-zoom
- Menu bar reveal/autohide at top edge
- Dock reveal/autohide at bottom edge
- All 128 upstream core self-test checks

## Compatibility changes

### Multi-touch calibration

Calibration originally failed with “the four samples are collinear or identical”.
The calibration path now uses the descriptor-derived `MultiTouchParser` when
multi-touch is enabled and a layout is available, with fallback to the original
single-contact parser.

### Screen-edge hover

In CGEvent mouse-emulation mode, a one-finger touch normally remains a mouse
press/drag. A mouse-move-only edge path was added so macOS can reveal an
auto-hidden menu bar or Dock. The pointer is moved away from the edge on the next
normal touch so auto-hide works again.

## Intentionally not included

Three-finger Mission Control/Space navigation was prototyped and removed before
the final stable build because real contact-count transitions were not
deterministic enough for this setup.

## Host-side additions

Mission Control is invoked from a macOS menu-bar Shortcut using:

`open -a "Mission Control"`

The macOS on-screen keyboard is opened only when needed from the menu bar.
