import AppKit
import SwiftUI
import ServiceManagement
import HIDDriverCore

/// Runs the app as a menu bar agent.
///
/// The driver does its work whether or not a window is open, so a Dock icon and
/// a permanent window are pure overhead — `LSUIElement` in Info.plist removes
/// both. What is left is a status item and a window opened on demand.
///
/// The window is created by hand rather than through a SwiftUI `WindowGroup`,
/// because a `WindowGroup` opens a window at launch. For an app registered to
/// start at login that is exactly wrong: logging in would deal you a window you
/// did not ask for, every time.
final class MenuBarController: NSObject, NSWindowDelegate {
    private let appModel: AppViewModel
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var stateObservation: NSKeyValueObservation?

    init(appModel: AppViewModel) {
        self.appModel = appModel
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.icon(active: false)
        item.button?.image?.isTemplate = true
        item.menu = buildMenu()
        statusItem = item
        refreshIcon()
    }

    /// Show the configuration window, creating it the first time.
    ///
    /// An agent app is not in the Dock, so nothing else will bring it forward:
    /// without the explicit activation the window opens behind whatever the user
    /// was looking at and reads as "the menu item did nothing".
    @objc func openStudio() {
        if window == nil {
            let hosting = NSHostingView(rootView:
                ContentView()
                    .environmentObject(appModel)
                    .frame(minWidth: 900, minHeight: 640)
            )

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "HIDTouch Studio"
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            window.setFrameAutosaveName("HIDTouchStudioWindow")
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Keep the window object around after a close so its size and position
    /// survive being reopened. Closing must not stop the driver.
    func windowShouldClose(_ sender: NSWindow) -> Bool { true }

    @objc private func toggleOpenAtLogin(_ sender: NSMenuItem) {
        do {
            try LoginItem.set(!LoginItem.isEnabled)
        } catch {
            Log.driverError("[Login] could not change the login item: \(error.localizedDescription)")
            presentLoginItemFailure(error)
        }
        statusItem?.menu = buildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "HIDTouch Studio…", action: #selector(openStudio), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit HIDTouch", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    /// One line saying whether touch is actually working, which is the only
    /// thing worth knowing without opening the window.
    private func statusLine() -> String {
        guard appModel.inputMonitoring == .granted else {
            return "Input Monitoring not granted"
        }
        guard !appModel.connectedDevices.filter(\.isTouchDevice).isEmpty else {
            return "No touch panel connected"
        }
        if !appModel.unseizedTouchDevices.isEmpty {
            return "Panel shared with macOS — cursor may fight"
        }
        if appModel.config.outputMode == .debugOnly {
            return "Connected — output is Debug / Log Only"
        }
        return "Active — \(appModel.effectiveOutputMode.rawValue)"
    }

    func refreshIcon() {
        let active = appModel.inputMonitoring == .granted
            && !appModel.connectedDevices.filter(\.isTouchDevice).isEmpty
        statusItem?.button?.image = Self.icon(active: active)
        statusItem?.button?.image?.isTemplate = true
        statusItem?.menu = buildMenu()
    }

    private static func icon(active: Bool) -> NSImage? {
        let name = active ? "hand.point.up.left.fill" : "hand.point.up.left"
        return NSImage(systemSymbolName: name, accessibilityDescription: "HIDTouch")
    }

    private func presentLoginItemFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not change the login item"
        alert.informativeText = """
        \(error.localizedDescription)

        Login registration needs the app to stay where it is. If it was moved \
        after being registered, macOS refuses to update the entry — remove \
        HIDTouch under System Settings › General › Login Items and add it again.
        """
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// Start-at-login registration.
///
/// `SMAppService` is the macOS 13+ replacement for hand-written LaunchAgent
/// plists and `SMLoginItemSetEnabled`. It is worth using for one reason beyond
/// being current: the entry appears under System Settings › General › Login
/// Items, where a user can see it and switch it off. A background process that
/// does not show up there is indistinguishable from something they would rather
/// not have installed.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
