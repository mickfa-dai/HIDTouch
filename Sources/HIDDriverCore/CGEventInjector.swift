import Foundation
import CoreGraphics

public enum TouchOutputMode: String, Codable, CaseIterable {
    case virtualHID = "Virtual Multi-Touch (Native)"
    case mouseEmulation = "Mouse Emulation (CGEvent)"
    case debugOnly = "Debug / Log Only"

    /// Whether this build can actually deliver events this way.
    public var isAvailable: Bool {
        switch self {
        case .virtualHID: return Permissions.hasVirtualHIDEntitlement
        case .mouseEmulation, .debugOnly: return true
        }
    }

    /// Modes worth offering. Listing one that silently degrades to another is
    /// worse than not listing it: the user picks it, nothing changes, and the
    /// reason is invisible.
    public static var availableCases: [TouchOutputMode] {
        allCases.filter(\.isAvailable)
    }

    /// Substitute for a stored mode this build cannot honour.
    public var resolvedForThisBuild: TouchOutputMode {
        isAvailable ? self : .mouseEmulation
    }
}

public class CGEventInjector {
    private var isMouseDown = false
    // Creating an event source per packet is wasteful on a ~100 Hz hot path.
    private let source = CGEventSource(stateID: .combinedSessionState)
    private var lastPoint: CGPoint = .zero

    /// Shortest press the system reliably turns into a click.
    ///
    /// A mouse-up posted in the same event cycle as its mouse-down is dropped:
    /// the press is delivered, the release never is, and the button stays stuck.
    /// Holding the release back by a few milliseconds is what makes a synthetic
    /// tap register.
    public var minimumPressDuration: TimeInterval = 0.040

    private var pressedAt: Date?
    private var pendingRelease: Timer?

    public init() {}

    /// Post a scroll event. macOS has no public multi-touch injection, so a
    /// two-finger pan is delivered as a pixel-precise scroll wheel event, which
    /// every app handles correctly.
    ///
    /// - Parameter point: where the fingers are, in global CoreGraphics
    ///   coordinates. **Passing this matters.** A scroll wheel event carries no
    ///   position of its own: the window server delivers it to whatever is under
    ///   the cursor. A two-finger pan does not move the cursor, so on a machine
    ///   with more than one display the scroll lands wherever the pointer
    ///   happens to be — commonly a different screen entirely, which is not
    ///   where the user is touching.
    public func postScroll(deltaX: Double, deltaY: Double, at point: CGPoint? = nil) {
        guard deltaX.isFinite, deltaY.isFinite else { return }
        guard abs(deltaX) >= 0.5 || abs(deltaY) >= 0.5 else { return }

        guard let event = CGEvent(scrollWheelEvent2Source: source,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(clamping: Int(deltaY.rounded())),
                                  wheel2: Int32(clamping: Int(deltaX.rounded())),
                                  wheel3: 0) else {
            return
        }
        place(event, at: point)
        event.post(tap: .cghidEventTap)
    }

    /// Aim a positionless event at the fingers.
    ///
    /// Both the warp and the explicit location are needed. Routing follows the
    /// event's location, but an application that consults `NSEvent.mouseLocation`
    /// — or simply draws a hover state — reads the real cursor, so leaving the
    /// pointer on another screen looks wrong even when the scroll goes to the
    /// right window.
    private func place(_ event: CGEvent, at point: CGPoint?) {
        guard let point = point, point.x.isFinite, point.y.isFinite else { return }
        CGWarpMouseCursorPosition(point)
        event.location = point
        lastPoint = point
    }

    // MARK: - Pinch

    /// The undocumented encoding of a gesture event.
    ///
    /// macOS delivers a pinch to applications as an `NSEvent` of type `.magnify`,
    /// and nothing in the public API produces one: `CGEvent` offers mouse,
    /// keyboard and scroll wheel events and stops there. The event type and the
    /// three fields below are the encoding the window server actually reads, and
    /// none of them appear in any SDK header. Apple guarantees nothing about
    /// them across releases — **if pinch stops working after a macOS update,
    /// this is the first place to look**, and the failure will be silent because
    /// an unrecognised gesture event is simply dropped.
    ///
    /// The phase values are public (`CGGesturePhase`), and the HID type matches
    /// `kIOHIDEventTypeZoom` from IOKit's HID event tables.
    private enum Gesture {
        /// `NSEventTypeGesture`.
        static let eventType = CGEventType(rawValue: 29)!
        /// Which kind of gesture the event carries.
        static let hidTypeField = CGEventField(rawValue: 110)!
        /// Fractional change in scale carried by this event.
        static let zoomValueField = CGEventField(rawValue: 113)!
        /// A `CGGesturePhase`.
        static let phaseField = CGEventField(rawValue: 132)!
        /// `kIOHIDEventTypeZoom`.
        static let zoomHIDType: Int64 = 8
    }

    private var isMagnifying = false

    /// True while a pinch has been opened and not yet closed.
    public var hasActiveMagnification: Bool { isMagnifying }

    /// Post one step of a pinch. `delta` is a *fractional* change in scale for
    /// this frame, the same quantity `NSEvent.magnification` carries: positive
    /// zooms in, and an app accumulates the steps itself.
    ///
    /// The opening `began` is emitted automatically on the first call, so
    /// callers only have to remember to `endMagnify()`.
    /// - Parameter point: where the fingers are. A gesture event is routed by
    ///   cursor position just like a scroll wheel event, so without this a pinch
    ///   zooms whichever screen the pointer was left on.
    public func postMagnify(delta: Double, at point: CGPoint? = nil) {
        guard delta.isFinite else { return }
        let phase: CGGesturePhase = isMagnifying ? .changed : .began
        isMagnifying = true
        postGesture(magnification: delta, phase: phase, at: point)
    }

    /// Close an in-flight pinch. Safe to call when there is none.
    ///
    /// Skipping this leaves the receiving app inside its gesture handler: the
    /// zoom keeps tracking after the fingers are gone, and the next pinch is
    /// appended to the abandoned one instead of starting fresh.
    public func endMagnify() {
        guard isMagnifying else { return }
        isMagnifying = false
        postGesture(magnification: 0, phase: .ended)
    }

    private func postGesture(magnification: Double, phase: CGGesturePhase, at point: CGPoint? = nil) {
        guard let event = CGEvent(source: source) else { return }
        event.type = Gesture.eventType
        event.setIntegerValueField(Gesture.hidTypeField, value: Gesture.zoomHIDType)
        event.setIntegerValueField(Gesture.phaseField, value: Int64(phase.rawValue))
        event.setDoubleValueField(Gesture.zoomValueField, value: magnification)
        // `endMagnify` passes no point, and needs none: every preceding frame
        // warped the cursor onto the fingers, so the closing event already
        // resolves to the window the gesture was running in.
        place(event, at: point)
        event.post(tap: .cghidEventTap)

        Log.event(String(format: "[EVT] posted MAGNIFY %+.4f phase=%d", magnification, phase.rawValue))
    }

    /// Release a held button — call when the driver stops or every finger lifts.
    ///
    /// Routed through `postTouchEvent` rather than posting its own event: when
    /// this had a separate implementation it skipped the cursor warp, the
    /// explicit location and the click state, and the resulting mouse-up was
    /// never delivered — leaving the button stuck down so every later touch
    /// arrived as a drag and no click ever registered.
    public func reset(at point: CGPoint? = nil) {
        guard isMouseDown else { return }
        postTouchEvent(screenPoint: point ?? lastPoint, isDown: false)
    }

    /// Release without waiting — for shutdown, where there is no next run loop
    /// turn to deliver a deferred event.
    public func releaseImmediately() {
        pendingRelease?.invalidate()
        pendingRelease = nil
        endMagnify()
        guard isMouseDown else { return }
        post(.leftMouseUp, at: lastPoint)
        isMouseDown = false
        pressedAt = nil
    }

    /// Post a cursor event at `screenPoint` (global CoreGraphics coordinates).
    /// - Parameter clampTo: bounds the point is confined to. A miscalibrated
    ///   affine matrix can otherwise warp the cursor far off-screen where the
    ///   user cannot recover it.
    public func postTouchEvent(screenPoint: CGPoint, isDown: Bool, clampTo bounds: CGRect? = nil) {
        guard screenPoint.x.isFinite, screenPoint.y.isFinite else { return }

        var point = screenPoint
        if let bounds = bounds, !bounds.isEmpty {
            point.x = max(bounds.minX, min(bounds.maxX - 1, point.x))
            point.y = max(bounds.minY, min(bounds.maxY - 1, point.y))
        }

        if isDown {
            // A press cancels any release still waiting out the minimum
            // duration, so a re-press during that window is not swallowed.
            pendingRelease?.invalidate()
            pendingRelease = nil

            if !isMouseDown {
                isMouseDown = true
                pressedAt = Date()
                post(.leftMouseDown, at: point)
            } else {
                post(.leftMouseDragged, at: point)
            }
            lastPoint = point
            return
        }

        guard isMouseDown else {
            post(.mouseMoved, at: point)
            lastPoint = point
            return
        }

        lastPoint = point
        let held = pressedAt.map { Date().timeIntervalSince($0) } ?? minimumPressDuration
        guard held < minimumPressDuration else {
            releaseNow(at: point)
            return
        }

        // Too quick to register — hold the release back just long enough.
        // Scheduled in common modes so it still fires while AppKit is tracking a
        // press, which is exactly when the release matters most.
        guard pendingRelease == nil else { return }
        let timer = Timer(timeInterval: minimumPressDuration - held, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.pendingRelease = nil
            guard self.isMouseDown else { return }
            self.releaseNow(at: self.lastPoint)
        }
        pendingRelease = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func releaseNow(at point: CGPoint) {
        isMouseDown = false
        pressedAt = nil
        post(.leftMouseUp, at: point)
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        if type == .leftMouseDown || type == .leftMouseUp {
            Log.event(String(format: "[EVT] posted %@ at (%.0f, %.0f)",
                             type == .leftMouseDown ? "DOWN" : "UP  ", point.x, point.y))
        }

        // 1. Warp mouse cursor immediately to target screen coordinate
        CGWarpMouseCursorPosition(point)

        // 2. Create CGEvent at target point
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
            return
        }

        // 3. Explicitly force set location
        event.location = point

        // 4. Click state. AppKit derives NSEvent.clickCount from this field, and
        //    a press whose clickCount is 0 is not treated as a click — the
        //    control under the cursor simply ignores it. A drag carries the
        //    click state of the press it belongs to.
        if type == .leftMouseDown || type == .leftMouseUp || type == .leftMouseDragged {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }

        // 5. Post to HID System Tap
        event.post(tap: .cghidEventTap)
    }
}
