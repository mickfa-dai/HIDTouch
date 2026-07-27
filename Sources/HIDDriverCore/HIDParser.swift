import Foundation

/// Represents a single touch point extracted from a raw HID report
public struct RawTouchPoint: Identifiable, Equatable {
    public var id: Int
    public var isDown: Bool
    public var rawX: Double
    public var rawY: Double
    public var pressure: Double
    public var timestamp: Date

    public init(id: Int, isDown: Bool, rawX: Double, rawY: Double, pressure: Double = 1.0, timestamp: Date = Date()) {
        self.id = id
        self.isDown = isDown
        self.rawX = rawX
        self.rawY = rawY
        self.pressure = pressure
        self.timestamp = timestamp
    }
}

/// Why a report was not turned into a touch point. Surfaced in the UI so that
/// an incorrect offset configuration is visible instead of silently dropping
/// every packet.
public enum HIDParseRejection: Equatable {
    case reportIDMismatch(expected: UInt8, actual: UInt32)
    case negativeOffset
    case tooShort(needed: Int, actual: Int)
    case outOfRange(rawX: Double, rawY: Double)

    public var description: String {
        switch self {
        case .reportIDMismatch(let expected, let actual):
            return String(format: "Report ID mismatch (expected 0x%02X, got 0x%02X)", expected, actual)
        case .negativeOffset:
            return "Byte offsets must be >= 0"
        case .tooShort(let needed, let actual):
            return "Packet too short (needs \(needed) bytes, got \(actual))"
        case .outOfRange(let rawX, let rawY):
            return String(format: "Raw value out of range (%.0f, %.0f)", rawX, rawY)
        }
    }
}

/// Configuration for parsing HID Report Packet bitstream.
///
/// All offsets index into the report buffer exactly as it is shown in the HID
/// Inspect hex dump, so the values read off the inspector can be entered here
/// directly.
public struct HIDReportFormat: Codable, Equatable {
    /// `nil` accepts every report ID; set it to reject reports from other
    /// collections on the same interface.
    public var reportID: UInt8?
    public var xByteOffset: Int
    public var yByteOffset: Int
    public var isLittleEndian: Bool
    /// Upper bound used as a validity gate — reports carrying larger values are
    /// treated as noise. Defaults to the full 16-bit range (accept everything).
    public var rawMaxX: Double
    public var rawMaxY: Double
    public var touchStateByteOffset: Int
    public var touchStateBitMask: UInt8

    public static let standardWin8Touchscreen = HIDReportFormat(
        reportID: nil,
        xByteOffset: 2,
        yByteOffset: 4,
        isLittleEndian: true,
        rawMaxX: 65535.0,
        rawMaxY: 65535.0,
        touchStateByteOffset: 1,
        touchStateBitMask: 0x01
    )

    public init(reportID: UInt8? = nil, xByteOffset: Int, yByteOffset: Int, isLittleEndian: Bool = true, rawMaxX: Double = 65535.0, rawMaxY: Double = 65535.0, touchStateByteOffset: Int = 1, touchStateBitMask: UInt8 = 0x01) {
        self.reportID = reportID
        self.xByteOffset = xByteOffset
        self.yByteOffset = yByteOffset
        self.isLittleEndian = isLittleEndian
        self.rawMaxX = rawMaxX
        self.rawMaxY = rawMaxY
        self.touchStateByteOffset = touchStateByteOffset
        self.touchStateBitMask = touchStateBitMask
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HIDReportFormat.standardWin8Touchscreen
        reportID = try? c.decodeIfPresent(UInt8.self, forKey: .reportID)
        xByteOffset = (try? c.decode(Int.self, forKey: .xByteOffset)) ?? d.xByteOffset
        yByteOffset = (try? c.decode(Int.self, forKey: .yByteOffset)) ?? d.yByteOffset
        isLittleEndian = (try? c.decode(Bool.self, forKey: .isLittleEndian)) ?? d.isLittleEndian
        rawMaxX = (try? c.decode(Double.self, forKey: .rawMaxX)) ?? d.rawMaxX
        rawMaxY = (try? c.decode(Double.self, forKey: .rawMaxY)) ?? d.rawMaxY
        touchStateByteOffset = (try? c.decode(Int.self, forKey: .touchStateByteOffset)) ?? d.touchStateByteOffset
        touchStateBitMask = (try? c.decode(UInt8.self, forKey: .touchStateBitMask)) ?? d.touchStateBitMask
    }
}

public class HIDParser {
    public var format: HIDReportFormat
    /// Reason the most recent report was discarded, or `nil` if it parsed.
    public private(set) var lastRejection: HIDParseRejection?

    public init(format: HIDReportFormat = .standardWin8Touchscreen) {
        self.format = format
    }

    /// Parse a raw HID report into a `RawTouchPoint`.
    /// - Parameter reportID: report ID delivered alongside the buffer by IOKit,
    ///   used only when `format.reportID` is set.
    public func parse(reportData: Data, reportID: UInt32? = nil) -> RawTouchPoint? {
        if let expected = format.reportID, let actual = reportID, UInt32(expected) != actual {
            lastRejection = .reportIDMismatch(expected: expected, actual: actual)
            return nil
        }

        guard format.xByteOffset >= 0, format.yByteOffset >= 0, format.touchStateByteOffset >= 0 else {
            lastRejection = .negativeOffset
            return nil
        }

        let bytes = [UInt8](reportData)
        // Both X and Y read two bytes starting at their offset.
        let needed = max(format.xByteOffset, format.yByteOffset) + 2
        guard bytes.count >= needed else {
            lastRejection = .tooShort(needed: needed, actual: bytes.count)
            return nil
        }

        // Parse Touch Down/Up state
        let isDown: Bool
        if format.touchStateByteOffset < bytes.count {
            isDown = (bytes[format.touchStateByteOffset] & format.touchStateBitMask) != 0
        } else {
            isDown = true
        }

        // Parse Raw X & Y 16-bit values
        let rx: Double
        let ry: Double

        if format.isLittleEndian {
            let u16X = UInt16(bytes[format.xByteOffset]) | (UInt16(bytes[format.xByteOffset + 1]) << 8)
            let u16Y = UInt16(bytes[format.yByteOffset]) | (UInt16(bytes[format.yByteOffset + 1]) << 8)
            rx = Double(u16X)
            ry = Double(u16Y)
        } else {
            let u16X = (UInt16(bytes[format.xByteOffset]) << 8) | UInt16(bytes[format.xByteOffset + 1])
            let u16Y = (UInt16(bytes[format.yByteOffset]) << 8) | UInt16(bytes[format.yByteOffset + 1])
            rx = Double(u16X)
            ry = Double(u16Y)
        }

        // Discard obviously bogus samples (e.g. status reports sharing the interface)
        if (format.rawMaxX > 0 && rx > format.rawMaxX) || (format.rawMaxY > 0 && ry > format.rawMaxY) {
            lastRejection = .outOfRange(rawX: rx, rawY: ry)
            return nil
        }

        lastRejection = nil
        return RawTouchPoint(id: 0, isDown: isDown, rawX: rx, rawY: ry)
    }
}
