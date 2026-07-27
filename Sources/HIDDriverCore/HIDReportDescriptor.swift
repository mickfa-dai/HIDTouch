import Foundation

/// One `Input` field extracted from a HID report descriptor.
public struct HIDField: Equatable {
    public var reportID: UInt8
    public var usagePage: Int
    public var usage: Int
    /// Bit position within the report *payload* — i.e. after the report ID byte.
    public var bitOffset: Int
    public var bitSize: Int
    public var logicalMin: Int
    public var logicalMax: Int
    /// Index of the enclosing Digitizer `Finger` collection, when there is one.
    public var fingerIndex: Int?
}

/// A minimal HID report descriptor walker.
///
/// This exists because contact blocks are *not* a fixed shape: panels differ in
/// whether they report pressure, width, height or confidence per finger, so a
/// hard-coded "5 bytes per contact" only works for one device. Deriving the
/// layout from the descriptor is what makes the driver universal.
///
/// Only what this driver needs is modelled: `Input` items, their usages and bit
/// positions, and enough collection tracking to group fields per finger.
public enum HIDReportDescriptor {

    // Usage pages / usages this driver cares about
    public static let usagePageGenericDesktop = 0x01
    public static let usagePageDigitizer = 0x0D
    public static let usageX = 0x30
    public static let usageY = 0x31
    public static let usageTouchScreen = 0x04
    public static let usageFinger = 0x22
    public static let usageTipSwitch = 0x42
    public static let usageContactIdentifier = 0x51
    public static let usageContactCount = 0x54

    public static func parse(_ descriptor: [UInt8]) -> [HIDField] {
        var fields: [HIDField] = []

        // Global state (carried across items until changed)
        var usagePage = 0
        var logicalMin = 0
        var logicalMax = 0
        var reportSize = 0
        var reportCount = 0
        var reportID: UInt8 = 0
        var globalStack: [(Int, Int, Int, Int, Int, UInt8)] = []

        // Local state (cleared after every Main item)
        var usages: [Int] = []
        var usageMin: Int?
        var usageMax: Int?

        // Bit cursor per report ID
        var bitOffsets: [UInt8: Int] = [:]

        // Collection tracking
        var collectionUsages: [Int] = []      // usage of each open collection
        var collectionPages: [Int] = []
        var fingerIndex: Int? = nil
        var fingerCounter = -1
        var fingerDepth: Int? = nil

        var index = 0
        while index < descriptor.count {
            let prefix = descriptor[index]

            // Long items are not used by any digitizer in practice; skip safely.
            if prefix == 0xFE {
                guard index + 1 < descriptor.count else { break }
                let dataSize = Int(descriptor[index + 1])
                index += 3 + dataSize
                continue
            }

            let sizeCode = Int(prefix & 0x03)
            let byteCount = sizeCode == 3 ? 4 : sizeCode
            let type = Int((prefix >> 2) & 0x03)
            let tag = Int((prefix >> 4) & 0x0F)

            guard index + byteCount < descriptor.count else { break }
            var value = 0
            for offset in 0..<byteCount {
                value |= Int(descriptor[index + 1 + offset]) << (8 * offset)
            }
            // Logical minimum/maximum are signed
            var signedValue = value
            if byteCount > 0 {
                let signBit = 1 << (byteCount * 8 - 1)
                if value & signBit != 0 {
                    signedValue = value - (1 << (byteCount * 8))
                }
            }

            index += 1 + byteCount

            switch type {
            case 0: // Main
                switch tag {
                case 0x8: // Input
                    let isConstant = value & 0x01 != 0
                    let cursor = bitOffsets[reportID] ?? 0

                    if !isConstant {
                        for i in 0..<reportCount {
                            let fieldUsage: Int
                            if let usageMin = usageMin, let usageMax = usageMax {
                                fieldUsage = min(usageMin + i, usageMax)
                            } else if i < usages.count {
                                fieldUsage = usages[i]
                            } else {
                                fieldUsage = usages.last ?? 0
                            }
                            fields.append(HIDField(
                                reportID: reportID,
                                usagePage: usagePage,
                                usage: fieldUsage,
                                bitOffset: cursor + i * reportSize,
                                bitSize: reportSize,
                                logicalMin: logicalMin,
                                logicalMax: logicalMax,
                                fingerIndex: fingerIndex
                            ))
                        }
                    }
                    bitOffsets[reportID] = cursor + reportSize * reportCount

                case 0x9, 0xB: // Output, Feature — occupy no input report space
                    break

                case 0xA: // Collection
                    let collectionUsage = usages.first ?? 0
                    collectionUsages.append(collectionUsage)
                    collectionPages.append(usagePage)
                    if usagePage == usagePageDigitizer && collectionUsage == usageFinger {
                        fingerCounter += 1
                        fingerIndex = fingerCounter
                        fingerDepth = collectionUsages.count
                    }

                case 0xC: // End Collection
                    if let depth = fingerDepth, collectionUsages.count == depth {
                        fingerIndex = nil
                        fingerDepth = nil
                    }
                    if !collectionUsages.isEmpty { collectionUsages.removeLast() }
                    if !collectionPages.isEmpty { collectionPages.removeLast() }

                default:
                    break
                }
                usages.removeAll()
                usageMin = nil
                usageMax = nil

            case 1: // Global
                switch tag {
                case 0x0: usagePage = value
                case 0x1: logicalMin = signedValue
                case 0x2: logicalMax = signedValue
                case 0x7: reportSize = value
                case 0x8: reportID = UInt8(truncatingIfNeeded: value)
                case 0x9: reportCount = value
                case 0xA: globalStack.append((usagePage, logicalMin, logicalMax, reportSize, reportCount, reportID))
                case 0xB:
                    if let saved = globalStack.popLast() {
                        (usagePage, logicalMin, logicalMax, reportSize, reportCount, reportID) = saved
                    }
                default: break
                }

            case 2: // Local
                switch tag {
                case 0x0: usages.append(value)
                case 0x1: usageMin = value
                case 0x2: usageMax = value
                default: break
                }

            default:
                break
            }
        }

        return fields
    }

    /// Total payload size in bits for a report ID, derived from its fields.
    public static func payloadBits(of reportID: UInt8, in descriptor: [UInt8]) -> Int {
        // Recomputing from fields would miss constant padding, so walk again and
        // take the final cursor position.
        var usagePage = 0, reportSize = 0, reportCount = 0
        var currentID: UInt8 = 0
        var bitOffsets: [UInt8: Int] = [:]
        var index = 0
        _ = usagePage

        while index < descriptor.count {
            let prefix = descriptor[index]
            if prefix == 0xFE {
                guard index + 1 < descriptor.count else { break }
                index += 3 + Int(descriptor[index + 1])
                continue
            }
            let sizeCode = Int(prefix & 0x03)
            let byteCount = sizeCode == 3 ? 4 : sizeCode
            let type = Int((prefix >> 2) & 0x03)
            let tag = Int((prefix >> 4) & 0x0F)
            guard index + byteCount < descriptor.count else { break }
            var value = 0
            for offset in 0..<byteCount {
                value |= Int(descriptor[index + 1 + offset]) << (8 * offset)
            }
            index += 1 + byteCount

            if type == 0 && tag == 0x8 { // Input
                bitOffsets[currentID] = (bitOffsets[currentID] ?? 0) + reportSize * reportCount
            } else if type == 1 {
                switch tag {
                case 0x0: usagePage = value
                case 0x7: reportSize = value
                case 0x8: currentID = UInt8(truncatingIfNeeded: value)
                case 0x9: reportCount = value
                default: break
                }
            }
        }
        return bitOffsets[reportID] ?? 0
    }
}

/// Bit positions of one contact within a multi-touch report.
public struct ContactLayout: Equatable {
    public var tipSwitchBitOffset: Int
    public var contactIDBitOffset: Int?
    public var contactIDBitSize: Int
    public var xBitOffset: Int
    public var xBitSize: Int
    public var yBitOffset: Int
    public var yBitSize: Int
}

/// Everything needed to decode a panel's multi-touch report, derived from its
/// report descriptor rather than assumed.
public struct MultiTouchLayout: Equatable {
    public var reportID: UInt8
    public var contacts: [ContactLayout]
    public var contactCountBitOffset: Int?
    public var contactCountBitSize: Int
    public var logicalMaxX: Int
    public var logicalMaxY: Int
    /// Expected report length in bytes, including the leading report ID.
    public var reportLengthBytes: Int

    public var maxContacts: Int { contacts.count }

    /// Derive the layout from a raw report descriptor, or return nil when the
    /// device has no multi-contact touchscreen collection.
    public static func from(descriptor: [UInt8]) -> MultiTouchLayout? {
        let fields = HIDReportDescriptor.parse(descriptor)

        // The multi-touch report is the one carrying per-finger tip switches.
        let fingerFields = fields.filter { $0.fingerIndex != nil }
        guard let reportID = fingerFields.first(where: {
            $0.usagePage == HIDReportDescriptor.usagePageDigitizer
                && $0.usage == HIDReportDescriptor.usageTipSwitch
        })?.reportID else { return nil }

        let reportFields = fields.filter { $0.reportID == reportID }
        let byFinger = Dictionary(grouping: reportFields.filter { $0.fingerIndex != nil },
                                  by: { $0.fingerIndex! })

        var contacts: [ContactLayout] = []
        for index in byFinger.keys.sorted() {
            let group = byFinger[index] ?? []
            func field(_ page: Int, _ usage: Int) -> HIDField? {
                group.first { $0.usagePage == page && $0.usage == usage }
            }
            guard let tip = field(HIDReportDescriptor.usagePageDigitizer, HIDReportDescriptor.usageTipSwitch),
                  let x = field(HIDReportDescriptor.usagePageGenericDesktop, HIDReportDescriptor.usageX),
                  let y = field(HIDReportDescriptor.usagePageGenericDesktop, HIDReportDescriptor.usageY) else {
                continue
            }
            let contactID = field(HIDReportDescriptor.usagePageDigitizer, HIDReportDescriptor.usageContactIdentifier)
            contacts.append(ContactLayout(
                tipSwitchBitOffset: tip.bitOffset,
                contactIDBitOffset: contactID?.bitOffset,
                contactIDBitSize: contactID?.bitSize ?? 0,
                xBitOffset: x.bitOffset,
                xBitSize: x.bitSize,
                yBitOffset: y.bitOffset,
                yBitSize: y.bitSize
            ))
        }

        guard !contacts.isEmpty else { return nil }

        let contactCount = reportFields.first {
            $0.usagePage == HIDReportDescriptor.usagePageDigitizer
                && $0.usage == HIDReportDescriptor.usageContactCount
                && $0.fingerIndex == nil
        }

        let maxX = reportFields.first {
            $0.usagePage == HIDReportDescriptor.usagePageGenericDesktop && $0.usage == HIDReportDescriptor.usageX
        }?.logicalMax ?? 0
        let maxY = reportFields.first {
            $0.usagePage == HIDReportDescriptor.usagePageGenericDesktop && $0.usage == HIDReportDescriptor.usageY
        }?.logicalMax ?? 0

        let bits = HIDReportDescriptor.payloadBits(of: reportID, in: descriptor)

        return MultiTouchLayout(
            reportID: reportID,
            contacts: contacts,
            contactCountBitOffset: contactCount?.bitOffset,
            contactCountBitSize: contactCount?.bitSize ?? 8,
            logicalMaxX: maxX,
            logicalMaxY: maxY,
            reportLengthBytes: 1 + (bits + 7) / 8
        )
    }
}
