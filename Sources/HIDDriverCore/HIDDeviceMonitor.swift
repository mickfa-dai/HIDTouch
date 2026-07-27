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

    /// Digitizer interfaces that have delivered at least one input report.
    ///
    /// This is the only trustworthy evidence that a panel is really in
    /// multi-touch mode. Its configuration register is not: it reads back 0x02
    /// on a panel that is still emitting single-contact mouse-emulation
    /// reports.
    private var digitizersThatReported: Set<UInt> = []

    /// Why an arming attempt is being made. The two kinds get separate budgets:
    /// a run of blind timer attempts must not use up the ones made in response
    /// to hard evidence that the panel reverted, because those are the attempts
    /// that are actually known to be needed.
    private enum ArmReason: String {
        /// Fired on a timer while the digitizer has said nothing at all — which
        /// is also what an untouched panel looks like, so this is speculative.
        case settle
        /// A touch arrived on the panel's mouse collection while its digitizer
        /// stayed silent: proof the panel is in mouse-emulation mode.
        case evidence
    }

    /// Arming attempts per panel ("vid:pid") and reason, so a panel that cannot
    /// be armed does not take a feature-report write forever.
    private var armAttempts: [ArmReason: [String: Int]] = [:]
    private var lastArmAttempt: [String: Date] = [:]

    /// Shortest gap between two arming attempts on the same panel.
    ///
    /// Low enough that a touch which exposes a reverted panel is followed by a
    /// re-arm almost immediately: at 100 Hz a longer window means the recovery
    /// is rate-limited away and multi-touch stays broken until the *next* touch.
    public var rearmInterval: TimeInterval = 1.0

    /// Give up arming a panel after this many tries.
    public var maxArmAttempts: Int = 5

    /// Re-arm the panel on this cadence until its digitizer actually reports.
    ///
    /// Arming at enumeration is too early to stick. The panel this was developed
    /// against accepts the write, reads Device Mode back as 0x02, and then
    /// reverts to 0x00 a second or two later as it finishes its own
    /// initialisation — so the register says multi-touch while the hardware
    /// keeps emitting mouse-emulation packets. Retrying on a timer closes that
    /// window without having to guess the one correct delay.
    public var settleRearmInterval: TimeInterval = 2.5

    /// Re-arm timers, keyed by digitizer interface.
    private var settleTimers: [UInt: Timer] = [:]

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
        digitizersThatReported.removeAll()
        settleTimers.values.forEach { $0.invalidate() }
        settleTimers.removeAll()
        armAttempts.removeAll()
        lastArmAttempt.removeAll()
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
                armMultiTouch(device, info: info, reason: .settle)
                scheduleSettleRearm(device, info: info, key: key)
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
    ///
    /// Arming is **not idempotent, and the readback does not prove anything**.
    /// A panel will report Device Mode 0x02 while still emitting nothing but
    /// mouse-emulation packets, and writing the value the register already
    /// holds changes nothing inside the firmware — so a driver that reads 0x02,
    /// writes 0x02 and declares success leaves multi-touch dead with no
    /// indication that anything went wrong. Two things follow, and both matter:
    ///
    /// - the target mode is always approached through an explicit 0x00, making
    ///   the write a real transition rather than a no-op;
    /// - success is judged by `digitizersThatReported`, i.e. by whether the
    ///   digitizer actually starts speaking, never by the register.
    private func armMultiTouch(_ device: IOHIDDevice, info: HIDDeviceInfo, reason: ArmReason) {
        guard let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data,
              let reportID = Self.deviceConfigurationReportID(in: [UInt8](descriptor)) else {
            Log.hidInfo("[HID] \(info.product): no Device Configuration report, leaving input mode alone.")
            return
        }

        guard let current = readFeature(device, reportID: reportID) else {
            Log.hidError("[HID] \(info.product): device config report 0x\(String(format: "%02X", reportID)) is not readable; cannot enable multi-touch.")
            return
        }

        let panel = Self.panelKey(for: info)
        let attempt = (armAttempts[reason]?[panel] ?? 0) + 1
        armAttempts[reason, default: [:]][panel] = attempt
        lastArmAttempt[panel] = Date()

        Log.hidInfo("[HID] \(info.product): device config 0x\(String(format: "%02X", reportID)) reads \(Self.hex(current)); arming (\(reason.rawValue) \(attempt)/\(maxArmAttempts)).")

        // Whether the buffer carries the report ID as byte 0 varies by device;
        // infer it from what the read returned, but try both anyway.
        let echoesReportID = current.first == reportID
        let deviceIdentifier = Self.deviceIdentifier(from: current, reportID: reportID)

        for mode in Self.candidateDeviceModes {
            for prefixed in [echoesReportID, !echoesReportID] {
                func payload(_ value: UInt8) -> [UInt8] {
                    prefixed ? [reportID, value, deviceIdentifier] : [value, deviceIdentifier]
                }

                // Force a transition: drop to mouse emulation, then climb out.
                let reset = payload(Self.mouseEmulationMode)
                _ = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), reset, reset.count)

                let target = payload(mode)
                let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), target, target.count)
                guard result == kIOReturnSuccess else {
                    Log.hidInfo("[HID] \(info.product): write \(Self.hex(target)) rejected outright (\(Log.kr(result))).")
                    continue
                }

                guard let readback = readFeature(device, reportID: reportID) else { continue }
                if Self.deviceMode(from: readback, reportID: reportID) == mode {
                    Log.hidInfo("[HID] \(info.product): wrote \(Self.hex(reset)) then \(Self.hex(target)), reads back \(Self.hex(readback)). Multi-touch is only confirmed once the digitizer reports.")
                    return
                }
                Log.hidInfo("[HID] \(info.product): write \(Self.hex(target)) ignored (still \(Self.hex(readback))).")
            }
        }

        Log.hidError("[HID] \(info.product): the panel would not leave mouse-emulation mode. Multi-touch is unavailable; single-contact input still works.")
    }

    /// A touch arriving through the panel's mouse collection while its digitizer
    /// has never said a word is direct evidence that the panel is still in
    /// mouse-emulation mode — the one thing the configuration register cannot
    /// tell us. Arm it again, mid-touch.
    ///
    /// This is also what restores multi-touch after a sleep/wake or a USB
    /// re-enumeration power-cycles the panel behind our back: the recovery is
    /// driven by what the hardware is actually doing, so it needs no power
    /// notifications and no guesses about which events reset a panel. The cost
    /// is that the touch which triggers the recovery is itself handled as a
    /// single contact.
    private func rearmIfDigitizerIsSilent(for info: HIDDeviceInfo) {
        guard let match = open.first(where: {
            $0.value.info.isDigitizer
                && $0.value.info.vendorID == info.vendorID
                && $0.value.info.productID == info.productID
        }) else { return }

        guard !digitizersThatReported.contains(match.key) else { return }

        let panel = Self.panelKey(for: info)
        guard (armAttempts[.evidence]?[panel] ?? 0) < maxArmAttempts else { return }
        if let last = lastArmAttempt[panel], Date().timeIntervalSince(last) < rearmInterval { return }

        Log.hidInfo("[HID] \(info.product): touch arrived on the mouse collection while the digitizer is silent — the panel is still in mouse-emulation mode.")
        armMultiTouch(match.value.device, info: match.value.info, reason: .evidence)
    }

    /// Keep arming until the digitizer speaks, the attempt budget runs out, or
    /// the device goes away.
    ///
    /// Without this the panel is only repaired by the first touch after it
    /// reverts, and that touch is spent as a single contact. Scheduled in common
    /// modes for the same reason as everything else here: it has to keep firing
    /// while AppKit is tracking a press.
    private func scheduleSettleRearm(_ device: IOHIDDevice, info: HIDDeviceInfo, key: UInt) {
        settleTimers[key]?.invalidate()

        let timer = Timer(timeInterval: settleRearmInterval, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            // Stop for the reasons that mean there is nothing left to do:
            // the device is gone, it is working, or it will never work.
            guard self.open[key] != nil else { self.cancelSettleRearm(key: key); return }
            guard !self.digitizersThatReported.contains(key) else { self.cancelSettleRearm(key: key); return }
            guard (self.armAttempts[.settle]?[Self.panelKey(for: info)] ?? 0) < self.maxArmAttempts else {
                // Only the speculative budget is spent. A touch that proves the
                // panel reverted still gets its own attempts.
                Log.hidInfo("[HID] \(info.product): stopping speculative re-arms after \(self.maxArmAttempts) tries; a touch will still trigger one.")
                self.cancelSettleRearm(key: key)
                return
            }

            Log.hidInfo("[HID] \(info.product): digitizer still silent — re-arming (panels revert while they initialise).")
            self.armMultiTouch(device, info: info, reason: .settle)
        }

        settleTimers[key] = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelSettleRearm(key: UInt) {
        settleTimers[key]?.invalidate()
        settleTimers.removeValue(forKey: key)
    }

    private static func panelKey(for info: HIDDeviceInfo) -> String {
        "\(info.vendorID):\(info.productID)"
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
    private static let mouseEmulationMode: UInt8 = 0x00

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
        digitizersThatReported.remove(key)
        cancelSettleRearm(key: key)
        // A reconnect is a fresh panel as far as arming goes — a re-enumeration
        // is exactly the event most likely to have reset it, so it must not
        // inherit an exhausted attempt budget.
        let panel = Self.panelKey(for: info)
        for reason in armAttempts.keys {
            armAttempts[reason]?.removeValue(forKey: panel)
        }
        lastArmAttempt.removeValue(forKey: panel)
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

        if info.isDigitizer {
            if digitizersThatReported.insert(key).inserted {
                Log.hidInfo("[HID] \(info.product): digitizer is reporting — multi-touch confirmed live.")
                cancelSettleRearm(key: key)
            }
        } else if enableMultiTouch, info.isTouchDevice {
            rearmIfDigitizerIsSilent(for: info)
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
