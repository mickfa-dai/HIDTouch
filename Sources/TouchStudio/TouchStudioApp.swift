import SwiftUI
import AppKit
import HIDDriverCore

@main
struct TouchStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Deliberately no window scene. The app is a menu bar agent
        // (`LSUIElement`), and the driver runs without any window at all — the
        // configuration window is opened on demand by `MenuBarController`.
        // Declaring a `WindowGroup` here would put one on screen at every
        // launch, including the login-time one.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appModel: AppViewModel?
    private var menuBar: MenuBarController?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppViewModel()
        let menuBar = MenuBarController(appModel: model)
        menuBar.install()
        self.appModel = model
        self.menuBar = menuBar

        // Nothing has been set up yet, so an invisible agent would look like an
        // app that failed to start. Show the window once; after that the menu
        // bar is enough.
        if model.config.calibrationPoints.isEmpty || model.inputMonitoring != .granted {
            menuBar.openStudio()
        }

        // The status item summarises live state — permissions, whether a panel
        // is attached — none of which is KVO-observable on a SwiftUI model, so
        // it is sampled. A menu that is a second out of date is fine; wiring
        // Combine into AppKit for this would not earn its complexity.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak menuBar] _ in
            menuBar?.refreshIcon()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// Closing the window must not quit: the driver is the point, and it keeps
    /// running with no window open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        appModel?.shutdown()
    }
}

final class AppViewModel: ObservableObject, HIDDeviceMonitorDelegate {
    @Published var config: DriverConfig {
        didSet {
            guard config != oldValue else { return }
            applyConfig()
        }
    }

    @Published var connectedDevices: [HIDDeviceInfo] = []
    @Published var inspectLogs: [String] = []
    @Published var isInspectPaused = false
    @Published var availableDisplays: [DisplayInfo] = []

    /// Touch devices macOS still owns. While this is non-empty the built-in
    /// driver keeps moving the cursor from the panel's reports, which fights
    /// with anything this driver injects.
    @Published var unseizedTouchDevices: [HIDDeviceInfo] = []

    /// Layout derived from the panel's report descriptor, when it supports
    /// multi-touch at all.
    @Published var multiTouchLayout: MultiTouchLayout?
    /// Every finger currently on the panel, in screen coordinates.
    @Published var contacts: [MappedContact] = []
    @Published var lastGesture: GestureAction = .none

    /// Set when Virtual Multi-Touch was chosen but is unavailable, so the
    /// driver quietly fell back to mouse emulation.
    @Published var isFallingBackFromVirtualHID = false
    @Published var effectiveOutputMode: TouchOutputMode = .debugOnly

    @Published var inputMonitoring: PermissionState = .unknown
    @Published var hasAccessibility = false
    /// Set once a report actually arrives — proof the permission is live, which
    /// the TCC status alone does not guarantee after a rebuild.
    @Published var hasReceivedReport = false

    @Published var currentRawPoint: CGPoint = .zero
    @Published var currentScreenPoint: CGPoint = .zero
    @Published var lastTouchState: String = "NO TOUCH"
    /// Why the most recent packet failed to parse — makes a wrong byte offset
    /// visible instead of looking like a dead device.
    @Published var lastParseIssue: String?

    /// "AUTO_TOUCH", "ALL", or a specific device id. Applies to the hex log only.
    @Published var selectedDeviceFilterID: String = "AUTO_TOUCH"

    // Calibration state
    @Published var isCalibrating = false
    @Published var calibrationStep = 0
    @Published var calibrationMessage: String?
    @Published var calibrationError: String?
    private var collectedCalibrationPoints: [CalibrationPoint] = []
    private var isWaitingForTouchRelease = false
    private var lastRecordedTime = Date.distantPast

    let monitor = HIDDeviceMonitor()
    let pipeline: TouchPipeline
    private let calibrationWindow = CalibrationWindowController()
    private var pendingSave: DispatchWorkItem?

    let targetScreenRatios: [CGPoint] = [
        CGPoint(x: 0.1, y: 0.1), // Top-Left
        CGPoint(x: 0.9, y: 0.1), // Top-Right
        CGPoint(x: 0.9, y: 0.9), // Bottom-Right
        CGPoint(x: 0.1, y: 0.9)  // Bottom-Left
    ]

    /// Explains a stored output mode this build had to substitute.
    @Published var outputModeNotice: String?

    init() {
        var loaded = ConfigManager.shared.loadConfig()

        // A config written when a different build (or a different machine) had
        // the entitlement would otherwise leave the picker showing a mode that
        // is no longer offered.
        let resolved = loaded.outputMode.resolvedForThisBuild
        var notice: String?
        if resolved != loaded.outputMode {
            notice = "Output mode was set to “\(loaded.outputMode.rawValue)”, which this build cannot provide (it needs the com.apple.developer.hid.virtual.device entitlement). Switched to “\(resolved.rawValue)”."
            loaded.outputMode = resolved
        }
        self.outputModeNotice = notice
        self.config = loaded
        self.pipeline = TouchPipeline(config: loaded)
        self.availableDisplays = DisplayHelper.getAllDisplays()

        monitor.delegate = self
        monitor.seizeTouchDevices = loaded.seizeTouchDevices
        monitor.enableMultiTouch = loaded.multiTouchEnabled
        monitor.startMonitoring()
        pipeline.prepare()

        if notice != nil { ConfigManager.shared.saveConfig(loaded) }
        installEventDiagnostics()
        refreshPermissions()
        // The user may grant the permission while the window is open; TCC does
        // not notify us, so poll cheaply.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
    }

    // MARK: - Diagnostics

    private var eventMonitors: [Any] = []

    /// Log the mouse events this process actually receives, so it is possible to
    /// tell "the synthetic event never arrived" apart from "it arrived and the
    /// control ignored it".
    private func installEventDiagnostics() {
        // The global half observes other applications' clicks, so this stays off
        // unless explicitly asked for:  HIDTOUCH_EVENT_TRACE=1 open HIDTouch\ Studio.app
        guard Log.isEventTraceEnabled else { return }
        Log.driverInfo("[EVT] event tracing enabled")
        let types: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp]

        if let local = NSEvent.addLocalMonitorForEvents(matching: types, handler: { event in
            Log.event(String(format: "[EVT] local %@ at (%.0f, %.0f) window=%@ active=%@ subtype=%d",
                                  event.type == .leftMouseDown ? "DOWN" : "UP  ",
                                  event.locationInWindow.x, event.locationInWindow.y,
                                  event.window == nil ? "nil" : "yes",
                                  NSApp.isActive ? "yes" : "no",
                                  Int(event.subtype.rawValue)))
            return event
        }) {
            eventMonitors.append(local)
        }

        if let global = NSEvent.addGlobalMonitorForEvents(matching: types, handler: { event in
            Log.event(String(format: "[EVT] global %@ at (%.0f, %.0f) active=%@",
                                  event.type == .leftMouseDown ? "DOWN" : "UP  ",
                                  event.locationInWindow.x, event.locationInWindow.y,
                                  NSApp.isActive ? "yes" : "no"))
        }) {
            eventMonitors.append(global)
        }
    }

    // MARK: - Permissions

    private var permissionTimer: Timer?

    let signature = Permissions.signature

    func refreshPermissions() {
        let monitoring = Permissions.inputMonitoring
        let accessibility = Permissions.accessibility
        if monitoring != inputMonitoring { inputMonitoring = monitoring }
        if accessibility != hasAccessibility { hasAccessibility = accessibility }

        let fallback = pipeline.isFallingBackFromVirtualHID
        if fallback != isFallingBackFromVirtualHID { isFallingBackFromVirtualHID = fallback }
        let effective = pipeline.effectiveOutputMode
        if effective != effectiveOutputMode { effectiveOutputMode = effective }
    }

    /// Whether the mode actually in use needs Accessibility to inject anything.
    var needsAccessibility: Bool { effectiveOutputMode == .mouseEmulation }

    func requestInputMonitoring() {
        Permissions.requestInputMonitoring()
        refreshPermissions()
        if inputMonitoring != .granted {
            Permissions.openInputMonitoringSettings()
        }
    }

    func requestAccessibility() {
        Permissions.requestAccessibility()
        refreshPermissions()
        if !hasAccessibility {
            Permissions.openAccessibilitySettings()
        }
    }

    /// Give the devices back and let go of any held button or open gesture.
    ///
    /// Quitting mid-touch would otherwise leave the mouse button down or a pinch
    /// unclosed, and the app that was receiving them has no way to recover on
    /// its own.
    func shutdown() {
        pipeline.reset()
        monitor.stopMonitoring()
    }

    /// Re-open the HID manager after the user grants the permission, so the app
    /// starts working without a restart.
    func restartMonitoring() {
        monitor.stopMonitoring()
        connectedDevices.removeAll()
        hasReceivedReport = false
        monitor.seizeTouchDevices = config.seizeTouchDevices
        monitor.enableMultiTouch = config.multiTouchEnabled
        contacts.removeAll()
        monitor.startMonitoring()
    }

    // MARK: - Config

    func refreshDisplays() {
        DisplayHelper.invalidateCache()
        availableDisplays = DisplayHelper.getAllDisplays()
    }

    /// Binding that writes straight into the config and persists it.
    func binding<T: Equatable>(_ keyPath: WritableKeyPath<DriverConfig, T>) -> Binding<T> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { self.config[keyPath: keyPath] = $0 }
        )
    }

    private func applyConfig() {
        pipeline.config = config
        refreshPermissions()
        if monitor.seizeTouchDevices != config.seizeTouchDevices {
            monitor.seizeTouchDevices = config.seizeTouchDevices
            if !config.seizeTouchDevices {
                monitor.releaseSeizedDevices()
            }
        }
        scheduleSave()
    }

    /// Steppers and text fields fire on every keystroke; coalesce the writes.
    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = config
        let work = DispatchWorkItem { ConfigManager.shared.saveConfig(snapshot) }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func saveConfigNow() {
        pendingSave?.cancel()
        pendingSave = nil
        ConfigManager.shared.saveConfig(config)
    }

    // MARK: - Calibration

    var calibrationErrorPixels: Double {
        config.affineMatrix.meanError(for: config.calibrationPoints)
    }

    func startCalibration() {
        refreshDisplays()
        collectedCalibrationPoints.removeAll()
        calibrationStep = 0
        calibrationError = nil
        calibrationMessage = nil
        isWaitingForTouchRelease = false
        lastRecordedTime = Date.distantPast

        // Existing calibration is left untouched until the new one succeeds, so
        // cancelling does not destroy a working setup.
        isCalibrating = true
        pipeline.isInjectionEnabled = false

        let display = DisplayHelper.display(withID: config.targetDisplayID)
        calibrationWindow.show(on: display, model: self)
        print("[Calibration] Started 4-point calibration on \(display.name).")
    }

    func cancelCalibration() {
        finishCalibrationUI()
        calibrationMessage = "Calibration cancelled. Previous settings kept."
        print("[Calibration] Cancelled.")
    }

    private func finishCalibrationUI() {
        isCalibrating = false
        calibrationStep = 0
        collectedCalibrationPoints.removeAll()
        isWaitingForTouchRelease = false
        pipeline.isInjectionEnabled = true
        pipeline.reset()
        calibrationWindow.close()
    }

    private func recordCalibrationPoint(rawX: Double, rawY: Double) {
        guard calibrationStep < targetScreenRatios.count else { return }

        // The calibration window covers exactly this display, and SwiftUI's view
        // space is top-left / y-down like CoreGraphics, so a crosshair drawn at
        // (width * ratio.x, height * ratio.y) sits at this global point.
        let display = DisplayHelper.display(withID: config.targetDisplayID)
        let bounds = display.bounds
        let ratio = targetScreenRatios[calibrationStep]
        let targetX = bounds.origin.x + bounds.width * ratio.x
        let targetY = bounds.origin.y + bounds.height * ratio.y

        collectedCalibrationPoints.append(
            CalibrationPoint(rawX: rawX, rawY: rawY, screenX: targetX, screenY: targetY)
        )
        print(String(format: "[Calibration] Point %d/%d: Raw(%.0f, %.0f) -> Screen(%.1f, %.1f) on %@",
                     calibrationStep + 1, targetScreenRatios.count, rawX, rawY, targetX, targetY, display.name))

        calibrationStep += 1
        guard calibrationStep >= targetScreenRatios.count else { return }

        guard let matrix = AffineMatrix.compute(from: collectedCalibrationPoints) else {
            let points = collectedCalibrationPoints
            finishCalibrationUI()
            calibrationError = "Calibration failed: the four samples are collinear or identical. Check that the panel reports distinct coordinates for each corner."
            print("[Calibration] Failed — degenerate point set: \(points)")
            return
        }

        let error = matrix.meanError(for: collectedCalibrationPoints)
        config.calibrationPoints = collectedCalibrationPoints
        config.affineMatrix = matrix
        saveConfigNow()

        finishCalibrationUI()
        calibrationMessage = String(format: "Calibration complete — mean residual %.1f px.", error)
        print(String(format: "[Calibration] Matrix: X = %.6f*rx + %.6f*ry + %.2f | Y = %.6f*rx + %.6f*ry + %.2f (mean error %.2f px)",
                     matrix.a, matrix.b, matrix.c, matrix.d, matrix.e, matrix.f, error))
    }

    // MARK: - HIDDeviceMonitorDelegate

    func hidDeviceMonitor(_ monitor: HIDDeviceMonitor, didDetectDevices devices: [HIDDeviceInfo]) {
        onMain {
            self.connectedDevices = devices
            self.unseizedTouchDevices = monitor.unseizedTouchDevices
        }
    }

    func hidDeviceMonitor(_ monitor: HIDDeviceMonitor, didResolveMultiTouchLayout layout: MultiTouchLayout, forDevice device: HIDDeviceInfo) {
        onMain {
            self.pipeline.multiTouchLayout = layout
            self.multiTouchLayout = layout
        }
    }

    func hidDeviceMonitor(_ monitor: HIDDeviceMonitor, didReceiveReport data: Data, reportID: UInt32, fromDevice device: HIDDeviceInfo) {
        onMain {
            if !self.hasReceivedReport { self.hasReceivedReport = true }
            self.appendInspectLog(data: data, reportID: reportID, device: device)

            if self.isCalibrating {
                self.handleCalibrationReport(data: data, reportID: reportID, from: device)
                return
            }

            guard self.config.matches(device: device) else { return }

            guard let result = self.pipeline.process(reportData: data, reportID: reportID, from: device) else {
                self.lastParseIssue = self.pipeline.parser.lastRejection?.description
                return
            }

            self.lastParseIssue = nil
            self.currentRawPoint = CGPoint(x: result.raw.rawX, y: result.raw.rawY)
            self.currentScreenPoint = result.screenPoint
            self.contacts = result.contacts
            self.lastGesture = result.gesture
            self.lastTouchState = result.contacts.isEmpty ? "NO TOUCH" : (result.contacts.count == 1 ? "TOUCH DOWN" : "\(result.contacts.count) FINGERS")
        }
    }

    private func handleCalibrationReport(data: Data, reportID: UInt32, from device: HIDDeviceInfo) {
        guard config.matches(device: device) else { return }
        guard let raw = pipeline.parser.parse(reportData: data, reportID: reportID) else {
            lastParseIssue = pipeline.parser.lastRejection?.description
            return
        }

        lastParseIssue = nil
        currentRawPoint = CGPoint(x: raw.rawX, y: raw.rawY)
        lastTouchState = raw.isDown ? "TOUCH DOWN" : "TOUCH UP"

        if raw.isDown {
            let now = Date()
            if !isWaitingForTouchRelease && now.timeIntervalSince(lastRecordedTime) > 0.4 {
                lastRecordedTime = now
                isWaitingForTouchRelease = true
                recordCalibrationPoint(rawX: raw.rawX, rawY: raw.rawY)
            }
        } else {
            isWaitingForTouchRelease = false
        }
    }

    private func appendInspectLog(data: Data, reportID: UInt32, device: HIDDeviceInfo) {
        guard !isInspectPaused else { return }
        switch selectedDeviceFilterID {
        case "AUTO_TOUCH": guard device.isTouchDevice else { return }
        case "ALL": break
        default: guard device.id == selectedDeviceFilterID else { return }
        }

        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        // The usage pair matters: a panel exposes several interfaces under one
        // product name, and without it the log cannot tell them apart.
        let line = String(format: "%@ %02X/%02X | ID:0x%02X | %2d B | %@",
                          device.product, device.usagePage, device.usage,
                          reportID, data.count, hex)
        inspectLogs.append(line)
        if inspectLogs.count > 300 {
            inspectLogs.removeFirst(inspectLogs.count - 300)
        }
    }

    /// HID callbacks arrive on the run loop this object was created on (the main
    /// run loop). Dispatching asynchronously from there would only add a frame
    /// of input latency, so run inline when we are already on main.
    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
