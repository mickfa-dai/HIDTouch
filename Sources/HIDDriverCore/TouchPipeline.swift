import Foundation
import CoreGraphics

/// A contact in both the panel's coordinate space and the calibrated screen space.
public struct MappedContact: Identifiable, Equatable {
    public var id: Int
    public var raw: CGPoint
    public var screen: CGPoint

    public init(id: Int, raw: CGPoint, screen: CGPoint) {
        self.id = id
        self.raw = raw
        self.screen = screen
    }
}

/// Outcome of feeding one HID report through the driver.
public struct TouchPipelineResult: Equatable {
    public var raw: RawTouchPoint
    /// Calibrated, jitter-filtered point in global CoreGraphics coordinates.
    public var screenPoint: CGPoint
    /// Bounds of the display the point was mapped onto.
    public var displayBounds: CGRect
    /// Output mode actually used, which may differ from the configured one when
    /// the virtual HID device is unavailable.
    public var effectiveMode: TouchOutputMode
    /// Every finger currently down. Single-contact reports yield one entry.
    public var contacts: [MappedContact]
    /// What the gesture recogniser decided to do with this frame.
    public var gesture: GestureAction
}

/// Raw report -> parse -> calibrate -> filter -> inject.
///
/// Owned by both `hidtouch-daemon` and HIDTouch Studio so the two cannot drift apart.
public final class TouchPipeline {
    public var config: DriverConfig {
        didSet {
            guard config != oldValue else { return }
            applyConfig()
        }
    }

    public let parser: HIDParser
    /// Set once a panel's multi-touch layout has been derived from its report
    /// descriptor. While nil the pipeline handles single contacts only.
    public var multiTouchLayout: MultiTouchLayout? {
        didSet {
            guard multiTouchLayout != oldValue else { return }
            multiTouchParser = multiTouchLayout.map { MultiTouchParser(layout: $0) }
            gestures.reset()
        }
    }

    private var multiTouchParser: MultiTouchParser?
    private var gestures = GestureRecognizer()
    private var jitterFilter: JitterFilter
    private let cgInjector = CGEventInjector()
    private let virtualDevice = VirtualHIDDevice()
    /// Creating the virtual device needs an entitlement that either exists or
    /// does not; latch the failure so the hot path does not retry (and log) on
    /// every single report.
    private var virtualDeviceUnavailable = false
    private var lastScreenPoint: CGPoint = .zero
    private var pendingLift: Timer?

    /// How long every contact must stay absent before the press is released.
    ///
    /// Panels routinely drop a contact for a single frame mid-touch. Releasing
    /// on the first empty frame turns that into a spurious mouse-up — which ends
    /// the click, breaks drags, and (because the release lands in the same event
    /// cycle as the press) can be dropped entirely, leaving the button stuck.
    public var liftDebounce: TimeInterval = 0.030

    /// Set to false to run the parsing/calibration path without moving the
    /// cursor — used while the calibration overlay is up.
    public var isInjectionEnabled = true

    /// True when the configured output is Virtual Multi-Touch but the virtual
    /// device could not be created, so events are silently going out as mouse
    /// emulation instead. Surfaced in the UI rather than only logged.
    public var isFallingBackFromVirtualHID: Bool {
        config.outputMode == .virtualHID && !virtualDevice.isReady
    }

    /// The mode events are actually being delivered through.
    public var effectiveOutputMode: TouchOutputMode { effectiveMode() }

    public init(config: DriverConfig) {
        self.config = config
        self.parser = HIDParser(format: config.reportFormat)
        self.jitterFilter = JitterFilter(smoothingFactor: config.smoothingFactor, deadbandPixels: config.deadbandPixels)
        applyGestureConfig()
    }

    /// Bring up the virtual HID device if the configuration asks for it.
    @discardableResult
    public func prepare() -> Bool {
        guard config.outputMode == .virtualHID else { return true }
        if virtualDevice.isReady { return true }
        guard !virtualDeviceUnavailable else { return false }

        if virtualDevice.createVirtualDevice() { return true }
        virtualDeviceUnavailable = true
        print("[TouchPipeline] Virtual HID unavailable — falling back to mouse emulation.")
        return false
    }

    /// Release any held mouse button and drop filter history.
    public func reset() {
        cancelPendingLift()
        cgInjector.releaseImmediately()
        jitterFilter.reset()
        gestures.reset()
    }

    private func cancelPendingLift() {
        pendingLift?.invalidate()
        pendingLift = nil
    }

    /// Release after `liftDebounce`, unless a contact comes back first.
    private func scheduleLift(at point: CGPoint, bounds: CGRect, mode: TouchOutputMode) {
        guard pendingLift == nil else { return }
        // Common modes: the release has to fire even while AppKit is tracking
        // the press this driver just delivered.
        let timer = Timer(timeInterval: liftDebounce, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.pendingLift = nil
            self.jitterFilter.reset()
            guard self.isInjectionEnabled else { return }
            switch mode {
            case .virtualHID: self.sendVirtual(isDown: false, point: point, bounds: bounds)
            case .mouseEmulation: self.cgInjector.reset(at: point)
            case .debugOnly: break
            }
        }
        pendingLift = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    public func process(reportData: Data, reportID: UInt32, from device: HIDDeviceInfo) -> TouchPipelineResult? {
        guard config.matches(device: device) else { return nil }

        if config.multiTouchEnabled,
           let multiTouchParser = multiTouchParser,
           let frame = multiTouchParser.parse(reportData, reportID: reportID) {
            return processMultiTouch(frame)
        }

        guard let raw = parser.parse(reportData: reportData, reportID: reportID) else { return nil }
        return processSingle(raw)
    }

    // MARK: - Single contact

    private func processSingle(_ raw: RawTouchPoint) -> TouchPipelineResult {
        let transformed = config.affineMatrix.transform(rawX: raw.rawX, rawY: raw.rawY)
        var point = jitterFilter.filter(point: transformed)

        // A finger lift starts a new stroke; carrying EMA state across would
        // drag the next touch out of its landing position.
        if !raw.isDown {
            jitterFilter.reset()
        }

        let bounds = targetBounds()
        let mode = effectiveMode()

        if raw.isDown { cancelPendingLift() }

        if isInjectionEnabled {
            switch mode {
            case .virtualHID:
                sendVirtual(isDown: raw.isDown, point: point, bounds: bounds)
            case .mouseEmulation:
                if raw.isDown {
                    cgInjector.postTouchEvent(screenPoint: point, isDown: true, clampTo: bounds)
                } else {
                    scheduleLift(at: point, bounds: bounds, mode: mode)
                }
                point = clamp(point, to: bounds)
            case .debugOnly:
                break
            }
        }

        lastScreenPoint = point
        let contact = MappedContact(id: raw.id, raw: CGPoint(x: raw.rawX, y: raw.rawY), screen: point)
        return TouchPipelineResult(raw: raw, screenPoint: point, displayBounds: bounds,
                                   effectiveMode: mode,
                                   contacts: raw.isDown ? [contact] : [],
                                   gesture: raw.isDown ? .pointer(contact: TouchContact(id: raw.id, rawX: point.x, rawY: point.y)) : .none)
    }

    // MARK: - Multi contact

    private func processMultiTouch(_ frame: TouchFrame) -> TouchPipelineResult {
        let bounds = targetBounds()
        let mode = effectiveMode()

        let mapped = frame.contacts.map { contact -> MappedContact in
            let screen = config.affineMatrix.transform(rawX: contact.rawX, rawY: contact.rawY)
            return MappedContact(id: contact.id,
                                 raw: CGPoint(x: contact.rawX, y: contact.rawY),
                                 screen: screen)
        }

        // The recogniser works in screen space so its thresholds are in pixels
        // and stay meaningful across panels of different resolutions.
        let screenContacts = mapped.map { TouchContact(id: $0.id, rawX: $0.screen.x, rawY: $0.screen.y) }
        let action = gestures.handle(contacts: screenContacts)

        var point = lastScreenPoint
        var isDown = false

        // A contact of any kind means the finger never really left.
        if !frame.isEmpty { cancelPendingLift() }


        switch action {
        case .pointer(let contact):
            isDown = true
            point = jitterFilter.filter(point: CGPoint(x: contact.rawX, y: contact.rawY))
            if isInjectionEnabled {
                switch mode {
                case .virtualHID: sendVirtual(isDown: true, point: point, bounds: bounds)
                case .mouseEmulation:
                    cgInjector.postTouchEvent(screenPoint: point, isDown: true, clampTo: bounds)
                    point = clamp(point, to: bounds)
                case .debugOnly: break
                }
            }

        case .scroll(let dx, let dy):
            if isInjectionEnabled && mode != .debugOnly {
                cgInjector.postScroll(deltaX: dx, deltaY: dy)
            }

        case .none:
            // No fingers left — but wait out the debounce before releasing, in
            // case this is a single dropped frame rather than a real lift.
            if frame.isEmpty {
                scheduleLift(at: point, bounds: bounds, mode: mode)
            }
        }

        lastScreenPoint = point
        let primary = mapped.first
        let raw = RawTouchPoint(id: primary?.id ?? 0,
                                isDown: isDown,
                                rawX: Double(primary?.raw.x ?? 0),
                                rawY: Double(primary?.raw.y ?? 0))

        return TouchPipelineResult(raw: raw, screenPoint: point, displayBounds: bounds,
                                   effectiveMode: mode, contacts: mapped, gesture: action)
    }

    // MARK: - Helpers

    private func targetBounds() -> CGRect {
        DisplayHelper.display(withID: config.targetDisplayID).bounds
    }

    private func effectiveMode() -> TouchOutputMode {
        if config.outputMode == .virtualHID && !virtualDevice.isReady { return .mouseEmulation }
        return config.outputMode
    }

    private func sendVirtual(isDown: Bool, point: CGPoint, bounds: CGRect) {
        let normX = bounds.width > 0 ? (point.x - bounds.origin.x) / bounds.width : 0
        let normY = bounds.height > 0 ? (point.y - bounds.origin.y) / bounds.height : 0
        virtualDevice.sendTouchEvent(isDown: isDown, normalizedX: normX, normalizedY: normY)
    }

    private func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        guard !bounds.isEmpty else { return point }
        return CGPoint(x: max(bounds.minX, min(bounds.maxX - 1, point.x)),
                       y: max(bounds.minY, min(bounds.maxY - 1, point.y)))
    }

    private func applyConfig() {
        parser.format = config.reportFormat
        jitterFilter.configure(smoothingFactor: config.smoothingFactor, deadbandPixels: config.deadbandPixels)
        applyGestureConfig()
        prepare()
    }

    private func applyGestureConfig() {
        gestures.configure(scrollSensitivity: config.scrollSensitivity,
                           scrollActivationPixels: config.scrollActivationPixels,
                           naturalScrolling: config.naturalScrolling)
    }
}
