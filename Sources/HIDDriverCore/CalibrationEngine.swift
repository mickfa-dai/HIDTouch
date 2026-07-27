import Foundation
import CoreGraphics

/// Calibration Point pair linking Raw Touch coordinates to Target Screen coordinates
public struct CalibrationPoint: Codable, Equatable {
    public var rawX: Double
    public var rawY: Double
    public var screenX: Double
    public var screenY: Double

    public init(rawX: Double, rawY: Double, screenX: Double, screenY: Double) {
        self.rawX = rawX
        self.rawY = rawY
        self.screenX = screenX
        self.screenY = screenY
    }
}

/// Affine Transformation Matrix (3x2) for mapping Raw Touch coordinates to Screen coordinates
/// screenX = A * rawX + B * rawY + C
/// screenY = D * rawX + E * rawY + F
public struct AffineMatrix: Codable, Equatable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var e: Double
    public var f: Double

    public static let identity = AffineMatrix(a: 1.0, b: 0.0, c: 0.0, d: 0.0, e: 1.0, f: 0.0)

    public init(a: Double, b: Double, c: Double, d: Double, e: Double, f: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.e = e
        self.f = f
    }

    /// Map a Raw Touch Point to Screen Point
    public func transform(rawX: Double, rawY: Double) -> CGPoint {
        let sx = a * rawX + b * rawY + c
        let sy = d * rawX + e * rawY + f
        return CGPoint(x: sx, y: sy)
    }

    /// Mean euclidean residual, in pixels, between the calibration samples and
    /// where this matrix maps them. Used to report calibration quality instead
    /// of leaving the user to discover a bad fit by feel.
    public func meanError(for points: [CalibrationPoint]) -> Double {
        guard !points.isEmpty else { return 0 }
        var total = 0.0
        for p in points {
            let mapped = transform(rawX: p.rawX, rawY: p.rawY)
            let dx = mapped.x - p.screenX
            let dy = mapped.y - p.screenY
            total += sqrt(dx * dx + dy * dy)
        }
        return total / Double(points.count)
    }

    /// Calculate Affine Matrix from 3 or more Calibration Points using Least Squares Method.
    /// Returns `nil` when the system is degenerate (fewer than 3 points, or
    /// samples that are collinear / identical) rather than silently handing back
    /// an identity matrix that looks like a successful calibration.
    public static func compute(from points: [CalibrationPoint]) -> AffineMatrix? {
        guard points.count >= 3 else {
            return nil
        }

        let n = Double(points.count)

        var sumX = 0.0, sumY = 0.0
        var sumXX = 0.0, sumYY = 0.0, sumXY = 0.0
        var sumSX = 0.0, sumSY = 0.0
        var sumSX_X = 0.0, sumSX_Y = 0.0
        var sumSY_X = 0.0, sumSY_Y = 0.0

        for p in points {
            let rx = p.rawX
            let ry = p.rawY
            let sx = p.screenX
            let sy = p.screenY

            sumX += rx
            sumY += ry
            sumXX += rx * rx
            sumYY += ry * ry
            sumXY += rx * ry
            sumSX += sx
            sumSY += sy
            sumSX_X += sx * rx
            sumSX_Y += sx * ry
            sumSY_X += sy * rx
            sumSY_Y += sy * ry
        }

        // Solve M * [A, B, C]^T = [sumSX_X, sumSX_Y, sumSX]^T
        // M = [[sumXX, sumXY, sumX], [sumXY, sumYY, sumY], [sumX, sumY, n]]
        let matrixA = [
            [sumXX, sumXY, sumX],
            [sumXY, sumYY, sumY],
            [sumX,  sumY,  n   ]
        ]

        let vecX = [sumSX_X, sumSX_Y, sumSX]
        let vecY = [sumSY_X, sumSY_Y, sumSY]

        guard let abc = solve3x3(matrix: matrixA, vector: vecX),
              let def = solve3x3(matrix: matrixA, vector: vecY) else {
            return nil
        }

        return AffineMatrix(
            a: abc[0], b: abc[1], c: abc[2],
            d: def[0], e: def[1], f: def[2]
        )
    }

    private static func solve3x3(matrix: [[Double]], vector: [Double]) -> [Double]? {
        // Cramer's rule for 3x3 system
        let m = matrix
        let detM = determinant3x3(m)

        // The normal-equation matrix is built from sums of squared raw
        // coordinates, so its determinant is easily ~1e20 — an absolute epsilon
        // would never trip. Compare against the matrix scale instead, which is
        // what actually catches collinear or duplicated calibration samples.
        let scale = m.flatMap { $0 }.map { abs($0) }.max() ?? 0
        let epsilon = max(1e-9, scale * scale * scale * 1e-12)
        if !detM.isFinite || abs(detM) < epsilon { return nil }

        var m1 = m; m1[0][0] = vector[0]; m1[1][0] = vector[1]; m1[2][0] = vector[2]
        var m2 = m; m2[0][1] = vector[0]; m2[1][1] = vector[1]; m2[2][1] = vector[2]
        var m3 = m; m3[0][2] = vector[0]; m3[1][2] = vector[1]; m3[2][2] = vector[2]

        let x = determinant3x3(m1) / detM
        let y = determinant3x3(m2) / detM
        let z = determinant3x3(m3) / detM

        return [x, y, z]
    }

    private static func determinant3x3(_ m: [[Double]]) -> Double {
        return m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
             - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
             + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    }
}
