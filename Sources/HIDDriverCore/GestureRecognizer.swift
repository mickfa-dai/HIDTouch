import Foundation
import CoreGraphics

/// What the driver decided to do with a multi-touch frame.
public enum GestureAction: Equatable {
    /// One finger: drive the cursor as before.
    case pointer(contact: TouchContact)
    /// Two fingers moving together: scroll by this many screen pixels.
    case scroll(deltaX: Double, deltaY: Double)
    /// Two fingers moving apart or together: change scale by this fraction.
    /// Positive zooms in. Matches what `NSEvent.magnification` carries.
    case magnify(delta: Double)
    /// Three or more, or a gesture still settling — visualise only.
    case none
}

/// Turns a stream of multi-touch frames into cursor and scroll actions.
///
/// macOS has no public API for injecting real multi-touch, so anything beyond a
/// single pointer has to be recognised here and expressed as ordinary events.
/// Two-finger panning becomes a scroll wheel event, which is public API and
/// behaves correctly in every app.
public struct GestureRecognizer {
    /// Scale from calibrated screen pixels of finger travel to scroll pixels.
    public var scrollSensitivity: Double
    /// Fingers must move at least this far together before scrolling starts,
    /// so that a two-finger tap does not emit a stray scroll.
    public var scrollActivationPixels: Double
    /// Natural (content-follows-fingers) direction, matching the macOS default.
    public var naturalScrolling: Bool
    /// Whether a change in finger separation is mapped to a pinch at all.
    public var pinchEnabled: Bool
    /// Multiplies the fractional scale change sent to the application.
    public var pinchSensitivity: Double
    /// The gap between the fingers must change by at least this many pixels
    /// before the gesture is treated as a pinch rather than a pan.
    public var pinchActivationPixels: Double

    /// What a two-finger gesture was decided to be. Once decided it does not
    /// change until the fingers lift: a pinch inevitably drags the centroid
    /// around a little, and a pan inevitably wobbles the separation, so a
    /// recogniser that keeps re-deciding flickers between zooming and scrolling.
    private enum TwoFingerMode {
        case undecided, scroll, magnify
    }

    private var previousCentroid: CGPoint?
    private var previousCount: Int = 0
    private var mode: TwoFingerMode = .undecided
    /// Where the gesture started, which is what the activation thresholds are
    /// measured against.
    private var originCentroid: CGPoint?
    private var originSpread: Double?
    private var previousSpread: Double?

    public init(scrollSensitivity: Double = 1.0,
                scrollActivationPixels: Double = 6.0,
                naturalScrolling: Bool = true,
                pinchEnabled: Bool = true,
                pinchSensitivity: Double = 1.0,
                pinchActivationPixels: Double = 12.0) {
        self.scrollSensitivity = max(0.05, scrollSensitivity)
        self.scrollActivationPixels = max(0.0, scrollActivationPixels)
        self.naturalScrolling = naturalScrolling
        self.pinchEnabled = pinchEnabled
        self.pinchSensitivity = max(0.05, pinchSensitivity)
        self.pinchActivationPixels = max(1.0, pinchActivationPixels)
    }

    public mutating func configure(scrollSensitivity: Double,
                                   scrollActivationPixels: Double,
                                   naturalScrolling: Bool,
                                   pinchEnabled: Bool = true,
                                   pinchSensitivity: Double = 1.0,
                                   pinchActivationPixels: Double = 12.0) {
        self.scrollSensitivity = max(0.05, scrollSensitivity)
        self.scrollActivationPixels = max(0.0, scrollActivationPixels)
        self.naturalScrolling = naturalScrolling
        self.pinchEnabled = pinchEnabled
        self.pinchSensitivity = max(0.05, pinchSensitivity)
        self.pinchActivationPixels = max(1.0, pinchActivationPixels)
    }

    public mutating func reset() {
        previousCentroid = nil
        previousCount = 0
        mode = .undecided
        originCentroid = nil
        originSpread = nil
        previousSpread = nil
    }

    /// Feed one frame whose contacts have already been mapped to screen
    /// coordinates, and get back what should be injected.
    public mutating func handle(contacts: [TouchContact]) -> GestureAction {
        defer { previousCount = contacts.count }

        // Any change in finger count restarts the gesture: the centroid jumps
        // when a finger lands or lifts, and carrying that delta over would fling
        // the view.
        if contacts.count != previousCount {
            beginGesture(with: contacts)
            if contacts.count == 1 { return .pointer(contact: contacts[0]) }
            return .none
        }

        switch contacts.count {
        case 0:
            previousCentroid = nil
            return .none

        case 1:
            previousCentroid = nil
            return .pointer(contact: contacts[0])

        case 2:
            let current = centroid(of: contacts)
            let spread = separation(contacts[0], contacts[1])
            defer {
                previousCentroid = current
                previousSpread = spread
            }

            guard let previous = previousCentroid,
                  let lastSpread = previousSpread,
                  let origin = originCentroid,
                  let startSpread = originSpread,
                  lastSpread > 0, startSpread > 0 else { return .none }

            if mode == .undecided {
                // Measured from where the gesture started, not accumulated
                // frame by frame: accumulating |change| adds up sensor noise
                // monotonically, so a long slow pan eventually crosses the
                // pinch threshold on jitter alone. A net measure cancels it.
                let spreadChange = abs(spread - startSpread)
                let panDistance = distance(current, origin)

                if pinchEnabled && spreadChange >= pinchActivationPixels {
                    mode = .magnify
                } else if panDistance >= scrollActivationPixels {
                    mode = .scroll
                } else {
                    return .none
                }
            }

            switch mode {
            case .magnify:
                // A fraction, not a distance: this is what NSEvent.magnification
                // carries, and it makes a pinch cover the same ratio whether the
                // fingers started 2 cm or 10 cm apart.
                return .magnify(delta: (spread - lastSpread) / lastSpread * pinchSensitivity)

            case .scroll:
                let dx = current.x - previous.x
                let dy = current.y - previous.y
                let sign = naturalScrolling ? 1.0 : -1.0
                return .scroll(deltaX: dx * scrollSensitivity * sign,
                               deltaY: dy * scrollSensitivity * sign)

            case .undecided:
                return .none
            }

        default:
            // Three or more fingers are tracked and visualised but not mapped.
            previousCentroid = centroid(of: contacts)
            return .none
        }
    }

    private mutating func beginGesture(with contacts: [TouchContact]) {
        mode = .undecided
        guard !contacts.isEmpty else {
            previousCentroid = nil
            originCentroid = nil
            originSpread = nil
            previousSpread = nil
            return
        }

        let start = centroid(of: contacts)
        previousCentroid = start
        originCentroid = start

        let spread = contacts.count == 2 ? separation(contacts[0], contacts[1]) : nil
        originSpread = spread
        previousSpread = spread
    }

    private func centroid(of contacts: [TouchContact]) -> CGPoint {
        let sx = contacts.reduce(0.0) { $0 + $1.rawX }
        let sy = contacts.reduce(0.0) { $0 + $1.rawY }
        return CGPoint(x: sx / Double(contacts.count), y: sy / Double(contacts.count))
    }

    private func separation(_ a: TouchContact, _ b: TouchContact) -> Double {
        let dx = a.rawX - b.rawX
        let dy = a.rawY - b.rawY
        return (dx * dx + dy * dy).squareRoot()
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
