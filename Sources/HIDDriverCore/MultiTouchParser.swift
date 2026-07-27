import Foundation
import CoreGraphics

/// One finger currently on the panel.
public struct TouchContact: Identifiable, Equatable {
    /// Contact identifier reported by the panel — stable while the finger stays
    /// down, which is what lets gestures track individual fingers.
    public var id: Int
    public var rawX: Double
    public var rawY: Double

    public init(id: Int, rawX: Double, rawY: Double) {
        self.id = id
        self.rawX = rawX
        self.rawY = rawY
    }
}

/// A single multi-touch report: every finger down at one instant.
public struct TouchFrame: Equatable {
    public var contacts: [TouchContact]

    public init(contacts: [TouchContact]) {
        self.contacts = contacts
    }

    public var count: Int { contacts.count }
    public var isEmpty: Bool { contacts.isEmpty }

    /// Mean position of all contacts — the anchor gestures are measured from.
    public var centroid: CGPoint {
        guard !contacts.isEmpty else { return .zero }
        let sx = contacts.reduce(0.0) { $0 + $1.rawX }
        let sy = contacts.reduce(0.0) { $0 + $1.rawY }
        return CGPoint(x: sx / Double(contacts.count), y: sy / Double(contacts.count))
    }
}

public final class MultiTouchParser {
    public let layout: MultiTouchLayout

    public init(layout: MultiTouchLayout) {
        self.layout = layout
    }

    /// Decode a multi-touch report.
    /// - Parameter includesReportID: true when byte 0 of `data` is the report ID,
    ///   which is how IOKit delivers reports from this class of device.
    public func parse(_ data: Data, reportID: UInt32, includesReportID: Bool = true) -> TouchFrame? {
        guard reportID == UInt32(layout.reportID) else { return nil }

        let bytes = [UInt8](data)
        let payloadStart = includesReportID ? 1 : 0
        guard bytes.count > payloadStart else { return nil }
        let payload = Array(bytes[payloadStart...])

        // Trust the reported contact count when present; some panels leave stale
        // coordinates in the unused slots, so reading past it produces ghosts.
        // A zero count is treated as "not stated" rather than "no fingers": a
        // genuine all-lifted report also has every tip switch clear, so falling
        // back to the tip switches is correct in both cases and tolerates panels
        // that never populate the field.
        var declaredCount: Int?
        if let offset = layout.contactCountBitOffset,
           let value = Self.bits(payload, bitOffset: offset, bitCount: layout.contactCountBitSize),
           value > 0 {
            declaredCount = Int(value)
        }

        var contacts: [TouchContact] = []
        for slot in layout.contacts {
            guard let tip = Self.bits(payload, bitOffset: slot.tipSwitchBitOffset, bitCount: 1),
                  let x = Self.bits(payload, bitOffset: slot.xBitOffset, bitCount: slot.xBitSize),
                  let y = Self.bits(payload, bitOffset: slot.yBitOffset, bitCount: slot.yBitSize) else {
                break
            }
            guard tip != 0 else { continue }

            var identifier = contacts.count
            if let idOffset = slot.contactIDBitOffset, slot.contactIDBitSize > 0,
               let raw = Self.bits(payload, bitOffset: idOffset, bitCount: slot.contactIDBitSize) {
                identifier = Int(raw)
            }

            contacts.append(TouchContact(id: identifier, rawX: Double(x), rawY: Double(y)))
            if let declaredCount = declaredCount, contacts.count >= declaredCount { break }
        }

        if let declaredCount = declaredCount, declaredCount < contacts.count {
            contacts = Array(contacts.prefix(declaredCount))
        }

        return TouchFrame(contacts: contacts)
    }

    /// Read `bitCount` bits starting at `bitOffset`. HID packs fields
    /// least-significant-bit first within each byte.
    public static func bits(_ bytes: [UInt8], bitOffset: Int, bitCount: Int) -> UInt32? {
        guard bitCount > 0, bitCount <= 32, bitOffset >= 0 else { return nil }
        let lastBit = bitOffset + bitCount - 1
        guard lastBit / 8 < bytes.count else { return nil }

        var result: UInt32 = 0
        for i in 0..<bitCount {
            let bit = bitOffset + i
            let byte = bytes[bit / 8]
            let value = (byte >> UInt8(bit % 8)) & 0x01
            result |= UInt32(value) << UInt32(i)
        }
        return result
    }
}
