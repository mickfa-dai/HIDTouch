import AppKit
import SwiftUI
import HIDDriverCore

/// Borderless window that covers exactly one display.
///
/// Calibration only works if the crosshair the user touches is at the screen
/// coordinate the driver records. Drawing the overlay inside the main window
/// (which is not fullscreen) would make those two disagree, so the overlay gets
/// its own window sized to the target display's bounds.
final class CalibrationWindowController {
    private var window: NSWindow?

    func show(on display: DisplayInfo, model: AppViewModel) {
        close()

        // CGDisplayBounds is top-left/y-down; NSWindow frames are bottom-left/y-up.
        let frame = DisplayHelper.nsFrame(forCGRect: display.bounds)

        let window = CalibrationPanel(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let root = CalibrationOverlayView().environmentObject(model)
        window.contentView = NSHostingView(rootView: root)
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func close() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }
}

/// Borderless windows refuse key status by default, which would swallow Escape.
private final class CalibrationPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
