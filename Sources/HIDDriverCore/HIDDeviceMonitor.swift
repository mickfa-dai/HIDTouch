import Foundation
import IOKit
import IOKit.hid

public struct HIDDeviceInfo: Identifiable, Equatable {
    /// Unique per *interface*, not per product: touch panels commonly expose a
    /// digitizer and a mouse collection under the same VID/PID, and collapsing
    /// them would hide the one we actually want.
    public var id: String
    public var vendorID: Int
    public var productID: Int
    public var locationID: Int
    public var manufacturer: String
    public var product: String
    public var usagePage: Int
    public var usage: Int

    public init(vendorID: Int, productID: Int, locationID: Int = 0, manufacturer: String, product: String, usagePage: Int, usage: Int) {
        self.id = "\(vendorID):\(productID):\(locationID):\(usagePage):\(usage)"
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
        self.manufacturer = manufacturer
        self.product = product
        self.usagePage = usagePage
        self.usage = usage
    }

    /// Compact identification shown in pickers and logs.
    public var shortLabel: String {
        String(format: "VID:0x%04X PID:0x%04X Usage:0x%02X/0x%02X", vendorID, productID, usagePage, usage)
    }
}

public protocol HIDDeviceMonitorDelegate: AnyObject {
    func hidDeviceMonitor(_ monitor: HIDDeviceMonitor, didDetectDevices devices: [HIDDeviceInfo])
    /// The panel's multi-touch layout, derived from its report descriptor once
    /// the device has been opened and switched out of mouse emulation.
    func hidDeviceMonitor(_ monitor: HIDDeviceMonitor, didResolveMultiTouchLayout layout: MultiTouchLayout, forDevice device: HIDDeviceInfo)
    func hidDeviceMonitor(_ monitor: HIDDeviceMonitor, didReceiveReport data: Data, reportID: UInt32, fromDevice device: HIDDeviceInfo)
}

public extension HIDDeviceInfo {
    /// Digitizer usage page — an unambiguous touch panel.
    var isDigitizer: Bool {
        usagePage == 0x0D
    }

    /// Vendor-defined usage pages (0xFF00+) carry firmware and configuration
    /// traffic, never touch coordinates. Touch panels commonly expose one
    /// alongside their real interfaces, and feeding it to the parser produces
    /// nothing but noise.
    var isVendorDefinedPage: Bool {
        usagePage >= 0xFF00
    }

    /// Apple's own input devices are natively supported by macOS and are never
    /// what this driver targets. The built-in trackpad reports a generic
    /// product string ("HID Device"), so the name blacklist alone misses it.
    var isAppleDevice: Bool {
        if vendorID == 0x05AC || vendorID == 0x004C { return true }
        let m = manufacturer.lowercased()
        return m == "apple" || m == "appl" || m.hasPrefix("apple ")
    }

    /// REALFORCE, LIGHTSPEED, Mouse, Keyboard などの既知の非タッチデバイス
    var isKnownNonTouchDevice: Bool {
        let name = (product + " " + manufacturer).lowercased()
        let nonTouchKeywords = ["realforce", "lightspeed", "mouse", "keyboard", "trackpad", "apple internal"]
        for kw in nonTouchKeywords {
            if name.contains(kw) {
                return true
            }
        }
        return false
    }

    /// キーボードやマルチメディアキー等の純粋なキーボード入力か
    var isKeyboardDevice: Bool {
        // Generic Desktop (0x01) の キーボード(0x06) / キーパッド(0x07)
        if usagePage == 0x01 && (usage == 0x06 || usage == 0x07) {
            return true
        }
        // Consumer Page (0x0C) -> 音量コントロール、メディアキー等
        if usagePage == 0x0C {
            return true
        }
        return false
    }

    /// タッチパネル・デジタイザーデバイスか。
    ///
    /// 安価なタッチパネルは Generic Desktop / Mouse (0x01/0x02) として列挙される
    /// ことが多いため、Usage だけでは判定できない。既知の非タッチデバイスを
    /// 除外していく方式をとる。
    var isTouchDevice: Bool {
        if isVendorDefinedPage { return false }
        if isAppleDevice { return false }
        if isDigitizer { return true }
        if isKeyboardDevice { return false }
        if isKnownNonTouchDevice { return false }
        return true
    }
}


/// Discovers HID devices and delivers their input reports.
///
/// Devices are opened **individually**, never through `IOHIDManagerOpen`.
/// `IOHIDManagerOpen` opens every matched device in one call and fails as a
/// whole if any single one is unavailable — and on a machine running
/// Karabiner-Elements (which takes exclusive ownership of keyboards) that means
/// it returns `kIOReturnExclusiveAccess` and this driver receives nothing at
/// all. Opening per device turns that into one skipped keyboard instead.
///
/// It also makes seizing work: a manager-level open holds a non-exclusive claim
/// on the touch panel, which stops a later `kIOHIDOptionsTypeSeizeDevice` open
/// from taking effect, leaving the built-in macOS driver free to keep moving
/// the cursor.
public class HIDDeviceMonitor {
    private var manager: IOHIDManager?
    public weak var delegate: HIDDeviceMonitorDelegate?
    public private(set) var connectedDevices: [HIDDeviceInfo] = []

    /// Take exclusive ownership of detected touch devices so the built-in macOS
    /// HID driver stops moving the cursor on its own. Only ever applied to
    /// devices that pass `isTouchDevice` — seizing indiscriminately would take
    /// the keyboard and mouse away from the user.
    public var seizeTouchDevices: Bool = true

    /// Write the Device Configuration feature report that takes Win8-style
    /// panels out of single-contact mouse emulation.
    public var enableMultiTouch: Bool = true

    /// Layout derived from the panel's report descriptor, once one is found.
    public private(set) var multiTouchLayout: MultiTouchLayout?

    private struct OpenDevice {
        var device: IOHIDDevice
        var info: HIDDeviceInfo
        var buffer: UnsafeMutablePointer<UInt8>
        var bufferLength: Int
        var isSeized: Bool
    }

    /// Keyed by the device pointer. Device info is needed on every input report,
    /// so caching it here avoids six IOKit property reads per packet.
    private var open: [UInt: OpenDevice] = [:]
    private var infoCache: [UInt: HIDDeviceInfo] = [:]
    /// Interfaces that have delivered at least one report, so the first packet
    /// from each can be logged exactly once.
    private var reportedDevices: Set<UInt> = []

    private static let reportBufferSize = 256

    /// True when at least one touch device is exclusively owned, i.e. macOS is
    /// no longer driving the cursor from it.
    public var hasSeizedTouchDevice: Bool {
        open.values.contains { $0.isSeized }
    }

    /// Touch devices we could not take exclusive ownership of. While this is
    /// non-empty the native driver still moves the cursor from those reports.
    public var unseizedTouchDevices: [HIDDeviceInfo] {
        open.values.filter { $0.info.isTouchDevice && !$0.isSeized }.map(\.info)
    }

    public init() {}

    public func startMonitoring() {
        guard manager == nil else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        // Match everything so the Inspect view can show any device's packets.
        IOHIDManagerSetDeviceMatching(manager, [:] as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context = context else { return }
            Unmanaged<HIDDeviceMonitor>.fromOpaque(context).takeUnretainedValue()
                .handleDeviceConnected(device: device)
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context = context else { return }
            Unmanaged<HIDDeviceMonitor>.fromOpaque(context).takeUnretainedValue()
                .handleDeviceDisconnected(device: device)
        }, context)

        // commonModes, not defaultMode. AppKit runs a control's press in
        // NSEventTrackingRunLoopMode, and a source registered only in
        // defaultMode stops being serviced for the whole duration. In this app —
        // which is both the source of the synthetic click and its target — that
        // means touching its own UI stops the driver from reading the finger
        // lift, so the mouse-up is never posted and AppKit waits forever for a
        // release that cannot come.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)

        Log.hidInfo("[HID] Discovery started (per-device open, seize touch devices: \(seizeTouchDevices)).")
        rescan()
    }

    /// Pick up devices already present. The matching callback covers hotplug,
    /// but without a manager-level open it is not guaranteed to fire for
    /// devices that were attached before we started.
    public func rescan() {
        guard let manager = manager else { return }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            Log.hidError("[HID] IOHIDManagerCopyDevices returned nothing.")
            return
        }
        for device in devices {
            handleDeviceConnected(device: device)
        }
    }

    public func stopMonitoring() {
        guard let manager = manager else { return }

        for key in open.keys {
            closeDevice(key: key)
        }
        open.removeAll()
        infoCache.removeAll()
        reportedDevices.removeAll()
        connectedDevices.removeAll()

        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
        self.manager = nil
        Log.hidInfo("[HID] Monitoring stopped.")
        delegate?.hidDeviceMonitor(self, didDetectDevices: connectedDevices)
    }

    /// Give exclusive ownership back without tearing the monitor down, then
    /// re-open the devices in shared mode so reports keep arriving.
    public func releaseSeizedDevices() {
        let seizedKeys = open.filter { $0.value.isSeized }.map(\.key)
        for key in seizedKeys {
            guard let entry = open[key] else { continue }
            closeDevice(key: key)
            open.removeValue(forKey: key)
            openDevice(entry.device, info: entry.info, allowSeize: false)
        }
        Log.hidInfo("[HID] Released exclusive ownership of \(seizedKeys.count) device(s).")
    }

    // MARK: - Device lifecycle

    private func handleDeviceConnected(device: IOHIDDevice) {
        let key = Self.cacheKey(for: device)
        guard open[key] == nil else { return }

        let info = deviceInfo(for: device)
        guard !connectedDevices.contains(where: { $0.id == info.id }) else { return }

        connectedDevices.append(info)
        Log.hidInfo("[HID] Found: \(info.product) (\(info.manufacturer)) [\(info.shortLabel)] Touch:\(info.isTouchDevice)")

        openDevice(device, info: info, allowSeize: seizeTouchDevices && info.isTouchDevice)
        delegate?.hidDeviceMonitor(self, didDetectDevices: connectedDevices)
    }

    private func openDevice(_ device: IOHIDDevice, info: HIDDeviceInfo, allowSeize: Bool) {
        let key = Self.cacheKey(for: device)
        var isSeized = false
        var result: IOReturn = kIOReturnSuccess

        if allowSeize {
            result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            if result == kIOReturnSuccess {
                isSeized = true
                Log.hidInfo("[HID] SEIZED \(info.product) [\(info.shortLabel)] — macOS will not move the cursor from this device.")
            } else {
                Log.hidError("[HID] Seize failed for \(info.product) [\(info.shortLabel)]: \(Log.kr(result)). Falling back to shared access; macOS keeps driving the cursor from it.")
            }
        }

        if !isSeized {
            result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard result == kIOReturnSuccess else {
                // One unavailable device (a keyboard held by another driver, say)
                // must not stop the rest from working.
                Log.hidError("[HID] Could not open \(info.product) [\(info.shortLabel)]: \(Log.kr(result)). Skipping this device.")
                return
            }
        }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.reportBufferSize)
        buffer.initialize(repeating: 0, count: Self.reportBufferSize)

        open[key] = OpenDevice(device: device, info: info, buffer: buffer,
                               bufferLength: Self.reportBufferSize, isSeized: isSeized)

        if info.isDigitizer {
            if enableMultiTouch {
                enableMultiTouchMode(device, info: info)
            }
            if let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data,
               let layout = MultiTouchLayout.from(descriptor: [UInt8](descriptor)) {
                multiTouchLayout = layout
                Log.hidInfo("[HID] \(info.product): multi-touch layout — report 0x\(String(format: "%02X", layout.reportID)), \(layout.maxContacts) contacts, \(layout.reportLengthBytes) bytes, X<=\(layout.logicalMaxX) Y<=\(layout.logicalMaxY).")
                delegate?.hidDeviceMonitor(self, didResolveMultiTouchLayout: layout, forDevice: info)
            }
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.reportBufferSize, { context, _, sender, _, reportID, report, reportLength in
            guard let context = context, let sender = sender, reportLength > 0 else { return }
            let monitor = Unmanaged<HIDDeviceMonitor>.fromOpaque(context).takeUnretainedValue()
            let hidDevice = unsafeBitCast(sender, to: IOHIDDevice.self)
            let data = Data(bytes: report, count: reportLength)
            monitor.handleInputReport(device: hidDevice, reportID: UInt32(reportID), data: data)
        }, context)

        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
    }

    /// Switch a Win8-style digitizer out of mouse-emulation and into multi-touch.
    ///
    /// These panels power up reporting a single contact through their Mouse
    /// collection, and only start emitting the multi-contact report once the
    /// host writes the Device Configuration feature report (Digitizer usage
    /// 0x0E, containing Device Mode 0x52). Windows does this at enumeration;
    /// macOS does not, which is why the digitizer collection is silent.
    private func enableMultiTouchMode(_ device: IOHIDDevice, info: HIDDeviceInfo) {
        guard let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data,
              let reportID = Self.deviceConfigurationReportID(in: [UInt8](descriptor)) else {
            Log.hidInfo("[HID] \(info.product): no Device Configuration report, leaving input mode alone.")
            return
        }

        guard let current = readFeature(device, reportID: reportID) else {
            Log.hidError("[HID] \(info.product): device config report 0x\(String(format: "%02X", reportID)) is not readable; cannot enable multi-touch.")
            return
        }
        Log.hidInfo("[HID] \(info.product): device config 0x\(String(format: "%02X", reportID)) currently \(Self.hex(current)).")

        // Whether the buffer carries the report ID as byte 0 varies by device;
        // infer it from what the read returned, but try both anyway.
        let echoesReportID = current.first == reportID
        let deviceIdentifier = Self.deviceIdentifier(from: current, reportID: reportID)

        // A SetReport returning success only means the request was delivered —
        // this panel accepts and silently ignores the wrong buffer layout — so
        // every attempt is confirmed by reading the value back.
        for mode in Self.candidateDeviceModes {
            for prefixed in [echoesReportID, !echoesReportID] {
                let payload: [UInt8] = prefixed
                    ? [reportID, mode, deviceIdentifier]
                    : [mode, deviceIdentifier]

                let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), payload, payload.count)
                guard result == kIOReturnSuccess else {
                    Log.hidInfo("[HID] \(info.product): write \(Self.hex(payload)) rejected outright (\(Log.kr(result))).")
                    continue
                }

                guard let readback = readFeature(device, reportID: reportID) else { continue }
                if Self.deviceMode(from: readback, reportID: reportID) == mode {
                    Log.hidInfo("[HID] \(info.product): multi-touch ENABLED — wrote \(Self.hex(payload)), reads back \(Self.hex(readback)).")
                    return
                }
                Log.hidInfo("[HID] \(info.product): write \(Self.hex(payload)) ignored (still \(Self.hex(readback))).")
            }
        }

        Log.hidError("[HID] \(info.product): the panel would not leave mouse-emulation mode. Multi-touch is unavailable; single-contact input still works.")
    }

    private func readFeature(_ device: IOHIDDevice, reportID: UInt8) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 16)
        var length: CFIndex = CFIndex(buffer.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), &buffer, &length)
        guard result == kIOReturnSuccess, length >= 2 else { return nil }
        return Array(buffer.prefix(Int(length)))
    }

    /// Device Mode values from the HID digitizer usage tables: 0 = mouse
    /// emulation, 2 = multiple-input (what Windows and Linux write), 3 = seen
    /// on some panels that ignore 2.
    private static let candidateDeviceModes: [UInt8] = [0x02, 0x03]

    private static func deviceMode(from report: [UInt8], reportID: UInt8) -> UInt8? {
        guard !report.isEmpty else { return nil }
        if report.first == reportID && report.count >= 2 { return report[1] }
        return report[0]
    }

    private static func deviceIdentifier(from report: [UInt8], reportID: UInt8) -> UInt8 {
        if report.first == reportID { return report.count >= 3 ? report[2] : 0 }
        return report.count >= 2 ? report[1] : 0
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Find the report ID of the Digitizer "Device Configuration" application
    /// collection — the descriptor sequence
    /// `05 0D 09 0E A1 01 85 <id>` (Usage Page Digitizer, Usage Device
    /// Configuration, Collection Application, Report ID).
    public static func deviceConfigurationReportID(in descriptor: [UInt8]) -> UInt8? {
        var index = 0
        while index + 7 < descriptor.count {
            if descriptor[index] == 0x05, descriptor[index + 1] == 0x0D,
               descriptor[index + 2] == 0x09, descriptor[index + 3] == 0x0E,
               descriptor[index + 4] == 0xA1, descriptor[index + 5] == 0x01,
               descriptor[index + 6] == 0x85 {
                return descriptor[index + 7]
            }
            index += 1
        }
        return nil
    }

    private func closeDevice(key: UInt) {
        guard let entry = open[key] else { return }
        IOHIDDeviceRegisterInputReportCallback(entry.device, entry.buffer, entry.bufferLength, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(entry.device, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
        let options = entry.isSeized ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone
        IOHIDDeviceClose(entry.device, IOOptionBits(options))
        entry.buffer.deinitialize(count: entry.bufferLength)
        entry.buffer.deallocate()
    }

    private func handleDeviceDisconnected(device: IOHIDDevice) {
        let key = Self.cacheKey(for: device)
        let info = infoCache[key] ?? extractDeviceInfo(from: device)

        if open[key] != nil {
            closeDevice(key: key)
            open.removeValue(forKey: key)
        }
        infoCache.removeValue(forKey: key)
        reportedDevices.remove(key)
        connectedDevices.removeAll(where: { $0.id == info.id })
        Log.hidInfo("[HID] Disconnected: \(info.product)")
        delegate?.hidDeviceMonitor(self, didDetectDevices: connectedDevices)
    }

    private func handleInputReport(device: IOHIDDevice, reportID: UInt32, data: Data) {
        let info = deviceInfo(for: device)

        // A panel exposes several interfaces under one product name and they do
        // not all speak the same report format. Log the first packet from each
        // so it is possible to tell which one actually carries coordinates,
        // without spamming the log at the panel's report rate.
        let key = Self.cacheKey(for: device)
        if reportedDevices.insert(key).inserted {
            let hex = data.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " ")
            Log.hidInfo("[HID] First report from \(info.product) [\(info.shortLabel)]: ID 0x\(String(format: "%02X", reportID)), \(data.count) bytes: \(hex)")
        }

        delegate?.hidDeviceMonitor(self, didReceiveReport: data, reportID: reportID, fromDevice: info)
    }

    // MARK: - Device info

    private func deviceInfo(for device: IOHIDDevice) -> HIDDeviceInfo {
        let key = Self.cacheKey(for: device)
        if let cached = infoCache[key] { return cached }
        let info = extractDeviceInfo(from: device)
        infoCache[key] = info
        return info
    }

    private static func cacheKey(for device: IOHIDDevice) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    }

    private func extractDeviceInfo(from device: IOHIDDevice) -> HIDDeviceInfo {
        let vendorID = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        let locationID = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int) ?? 0
        let manufacturer = (IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String) ?? "Generic"
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "HID Device"
        let usagePage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
        let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? 0

        return HIDDeviceInfo(vendorID: vendorID, productID: productID, locationID: locationID,
                             manufacturer: manufacturer, product: product,
                             usagePage: usagePage, usage: usage)
    }
}
