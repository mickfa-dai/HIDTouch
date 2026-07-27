import Foundation
import IOKit
import IOKit.hid
import CHIDUserDevice

public class VirtualHIDDevice {
    private var userDevice: IOHIDUserDevice?

    /// True once `createVirtualDevice()` has succeeded. Creating an
    /// `IOHIDUserDevice` requires the restricted
    /// `com.apple.developer.hid.virtual.device` entitlement, which Apple grants
    /// per-team — on an unsigned or ad-hoc signed build this stays false and
    /// callers should fall back to CGEvent injection.
    public private(set) var isReady = false

    // Custom Multi-Touch Digitizer HID Report Descriptor (Usage Page 0x0D, Usage 0x04 Touchscreen)
    private static let digitizerReportDescriptor: [UInt8] = [
        0x05, 0x0D,        // Usage Page (Digitizer)
        0x09, 0x04,        // Usage (Touch Screen)
        0xA1, 0x01,        // Collection (Application)
        0x85, 0x01,        //   Report ID (1)
        0x09, 0x22,        //   Usage (Finger)
        0xA1, 0x02,        //   Collection (Logical)
        0x09, 0x42,        //     Usage (Tip Switch - Touch State)
        0x15, 0x00,        //     Logical Minimum (0)
        0x25, 0x01,        //     Logical Maximum (1)
        0x75, 0x01,        //     Report Size (1)
        0x95, 0x01,        //     Report Count (1)
        0x81, 0x02,        //     Input (Data, Var, Abs)
        0x75, 0x07,        //     Report Size (7) - Padding
        0x81, 0x03,        //     Input (Cnst, Var, Abs)
        0x09, 0x51,        //     Usage (Contact Identifier)
        0x75, 0x08,        //     Report Size (8)
        0x95, 0x01,        //     Report Count (1)
        0x81, 0x02,        //     Input (Data, Var, Abs)
        0x05, 0x01,        //     Usage Page (Generic Desktop)
        0x09, 0x30,        //     Usage (X)
        0x15, 0x00,        //     Logical Minimum (0)
        0x26, 0xFF, 0x7F,  //     Logical Maximum (32767)
        0x75, 0x10,        //     Report Size (16)
        0x95, 0x01,        //     Report Count (1)
        0x81, 0x02,        //     Input (Data, Var, Abs)
        0x09, 0x31,        //     Usage (Y)
        0x15, 0x00,        //     Logical Minimum (0)
        0x26, 0xFF, 0x7F,  //     Logical Maximum (32767)
        0x75, 0x10,        //     Report Size (16)
        0x95, 0x01,        //     Report Count (1)
        0x81, 0x02,        //     Input (Data, Var, Abs)
        0xC0,              //   End Collection
        0xC0               // End Collection
    ]

    public init() {}

    @discardableResult
    public func createVirtualDevice() -> Bool {
        if isReady { return true }
        let descriptorData = Data(Self.digitizerReportDescriptor)
        let properties: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: 0x0D,
            kIOHIDDeviceUsageKey as String: 0x04,
            kIOHIDReportDescriptorKey as String: descriptorData,
            kIOHIDVendorIDKey as String: 0x1234,
            kIOHIDProductIDKey as String: 0x5678,
            kIOHIDProductKey as String: "Virtual Multi-Touch Screen (HIDTouch)"
        ]

        if let unmanaged = HIDTouch_CreateVirtualUserDevice(properties as CFDictionary) {
            userDevice = unmanaged.takeRetainedValue()
            isReady = true
            print("[VirtualHIDDevice] Successfully instantiated Virtual Touchscreen HID Device.")
            return true
        } else {
            isReady = false
            print("""
            [VirtualHIDDevice] Could not create the virtual HID device.
                               IOHIDUserDeviceCreate requires the restricted entitlement
                               'com.apple.developer.hid.virtual.device', which must be granted by Apple
                               and embedded via a provisioning profile. Falling back to CGEvent injection.
            """)
            return false
        }
    }

    /// Send a Native Touch Event to macOS via IOHIDUserDevice
    public func sendTouchEvent(isDown: Bool, normalizedX: Double, normalizedY: Double, fingerID: UInt8 = 0) {
        guard let userDevice = userDevice else { return }

        // Clamp normalized coordinates (0.0 ~ 1.0) to Logical Range (0 ~ 32767)
        let clampedX = max(0.0, min(1.0, normalizedX))
        let clampedY = max(0.0, min(1.0, normalizedY))
        let logX = UInt16(clampedX * 32767.0)
        let logY = UInt16(clampedY * 32767.0)

        var report = [UInt8](repeating: 0, count: 7)
        report[0] = 0x01 // Report ID
        report[1] = isDown ? 0x01 : 0x00 // Tip Switch
        report[2] = fingerID // Contact Identifier
        report[3] = UInt8(logX & 0xFF)
        report[4] = UInt8((logX >> 8) & 0xFF)
        report[5] = UInt8(logY & 0xFF)
        report[6] = UInt8((logY >> 8) & 0xFF)

        let kr = HIDTouch_HandleUserDeviceReport(userDevice, report, report.count)
        if kr != kIOReturnSuccess {
            // Report handle warning
        }
    }
}
