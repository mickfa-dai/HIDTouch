import Foundation
import CoreGraphics

/// Low-pass / Exponential Moving Average (EMA) Jitter Filter
public struct JitterFilter {
    /// 0.0 (max smooth) ~ 1.0 (no smooth)
    public private(set) var smoothingFactor: Double
    /// Minimum movement threshold in pixels
    public private(set) var deadbandPixels: Double

    private var lastPoint: CGPoint?

    public init(smoothingFactor: Double = 0.45, deadbandPixels: Double = 1.0) {
        self.smoothingFactor = JitterFilter.clampSmoothing(smoothingFactor)
        self.deadbandPixels = max(0.0, deadbandPixels)
    }

    /// Update the tuning parameters in place, keeping the current filter state.
    /// Values are clamped here so a bad config value cannot freeze the cursor.
    public mutating func configure(smoothingFactor: Double, deadbandPixels: Double) {
        self.smoothingFactor = JitterFilter.clampSmoothing(smoothingFactor)
        self.deadbandPixels = max(0.0, deadbandPixels)
    }

    public mutating func reset() {
        lastPoint = nil
    }

    public mutating func filter(point: CGPoint) -> CGPoint {
        guard point.x.isFinite, point.y.isFinite else {
            return lastPoint ?? .zero
        }

        guard let prev = lastPoint else {
            lastPoint = point
            return point
        }

        let dx = point.x - prev.x
        let dy = point.y - prev.y
        let distance = sqrt(dx * dx + dy * dy)

        // Ignore movements smaller than deadband
        if distance < deadbandPixels {
            return prev
        }

        // Adaptive smoothing: Fast movement gets less smoothing for responsiveness
        let adaptiveFactor = min(1.0, smoothingFactor + (distance / 50.0) * (1.0 - smoothingFactor))

        let filteredPoint = CGPoint(x: prev.x + dx * adaptiveFactor, y: prev.y + dy * adaptiveFactor)
        lastPoint = filteredPoint
        return filteredPoint
    }

    private static func clampSmoothing(_ value: Double) -> Double {
        guard value.isFinite else { return 0.45 }
        return max(0.01, min(1.0, value))
    }
}
