import Foundation
import CoreGraphics

/// What the driver decided to do with a multi-touch frame.
public enum GestureAction: Equatable {
    /// One finger: drive the cursor as before.
    case pointer(contact: TouchContact)
    /// Two fingers: scroll by this many screen pixels.
    case scroll(deltaX: Double, deltaY: Double)
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

    private var previousCentroid: CGPoint?
    private var previousCount: Int = 0
    private var scrollActive = false
    private var pendingTravel: Double = 0

    public init(scrollSensitivity: Double = 1.0,
                scrollActivationPixels: Double = 6.0,
                naturalScrolling: Bool = true) {
        self.scrollSensitivity = max(0.05, scrollSensitivity)
        self.scrollActivationPixels = max(0.0, scrollActivationPixels)
        self.naturalScrolling = naturalScrolling
    }

    public mutating func configure(scrollSensitivity: Double,
                                   scrollActivationPixels: Double,
                                   naturalScrolling: Bool) {
        self.scrollSensitivity = max(0.05, scrollSensitivity)
        self.scrollActivationPixels = max(0.0, scrollActivationPixels)
        self.naturalScrolling = naturalScrolling
    }

    public mutating func reset() {
        previousCentroid = nil
        previousCount = 0
        scrollActive = false
        pendingTravel = 0
    }

    /// Feed one frame whose contacts have already been mapped to screen
    /// coordinates, and get back what should be injected.
    public mutating func handle(contacts: [TouchContact]) -> GestureAction {
        defer { previousCount = contacts.count }

        // Any change in finger count restarts the gesture: the centroid jumps
        // when a finger lands or lifts, and carrying that delta over would fling
        // the view.
        if contacts.count != previousCount {
            previousCentroid = contacts.isEmpty ? nil : centroid(of: contacts)
            scrollActive = false
            pendingTravel = 0
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
            defer { previousCentroid = current }
            guard let previous = previousCentroid else { return .none }

            let dx = current.x - previous.x
            let dy = current.y - previous.y

            if !scrollActive {
                pendingTravel += (dx * dx + dy * dy).squareRoot()
                guard pendingTravel >= scrollActivationPixels else { return .none }
                scrollActive = true
            }

            let sign = naturalScrolling ? 1.0 : -1.0
            return .scroll(deltaX: dx * scrollSensitivity * sign,
                           deltaY: dy * scrollSensitivity * sign)

        default:
            // Three or more fingers are tracked and visualised but not mapped.
            previousCentroid = centroid(of: contacts)
            return .none
        }
    }

    private func centroid(of contacts: [TouchContact]) -> CGPoint {
        let sx = contacts.reduce(0.0) { $0 + $1.rawX }
        let sy = contacts.reduce(0.0) { $0 + $1.rawY }
        return CGPoint(x: sx / Double(contacts.count), y: sy / Double(contacts.count))
    }
}
