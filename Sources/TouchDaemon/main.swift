import Foundation
import HIDDriverCore
import CoreGraphics

print("==================================================")
print("   HIDTouch Driver Daemon v1.0 (macOS USB HID Touch)")
print("==================================================")

final class DaemonRunner: HIDDeviceMonitorDelegate {
    let monitor = HIDDeviceMonitor()
    let pipeline: TouchPipeline
    let config: DriverConfig

    var isInspectMode = false

    init(config incoming: DriverConfig) {
        var config = incoming
        let resolved = config.outputMode.resolvedForThisBuild
        if resolved != config.outputMode {
            print("NOTE: output mode \(config.outputMode.rawValue) needs the com.apple.developer.hid.virtual.device entitlement, which this build does not carry. Using \(resolved.rawValue).")
            config.outputMode = resolved
        }
        self.config = config
        self.pipeline = TouchPipeline(config: config)
        monitor.delegate = self
        monitor.seizeTouchDevices = config.seizeTouchDevices
        monitor.enableMultiTouch = config.multiTouchEnabled
    }

    func start(inspect: Bool) {
        self.isInspectMode = inspect

        let signature = Permissions.signature
        print("Code signature: \(signature.summary)")
        print("Input Monitoring: \(Permissions.inputMonitoring.label)")
        if Permissions.inputMonitoring != .granted {
            print("""
            WARNING: without Input Monitoring no input reports will arrive (devices still enumerate).
                     Grant it in System Settings > Privacy & Security > Input Monitoring.
            """)
            if signature.isAdHoc {
                print("         This binary is ad-hoc signed, so every rebuild invalidates the grant.")
            }
            Permissions.requestInputMonitoring()
        }
        if !inspect && config.outputMode == .mouseEmulation && !Permissions.accessibility {
            print("WARNING: Accessibility is not granted; cursor events will be dropped.")
        }

        if inspect {
            print("Mode: Inspect / Raw Hex Dump")
            // Never take the device away from the system or move the cursor
            // while the user is only looking at packets.
            monitor.seizeTouchDevices = false
            pipeline.isInjectionEnabled = false
        } else {
            print("Mode: Driver Daemon (\(config.outputMode.rawValue))")
            print("Target display: \(DisplayHelper.display(withID: config.targetDisplayID).name)")
            if config.selectedVendorID == 0 && config.selectedProductID == 0 {
                print("Input device: auto-detect (all devices classified as touch)")
            } else {
                print(String(format: "Input device: VID:0x%04X PID:0x%04X", config.selectedVendorID, config.selectedProductID))
            }
            if config.calibrationPoints.isEmpty {
                print("WARNING: no calibration data. Run HIDTouch Studio and calibrate before enabling injection.")
            }
            pipeline.prepare()
        }

        // Release a held mouse button if we are killed mid-stroke.
        for sig in [SIGINT, SIGTERM] {
            signal(sig) { _ in
                DaemonRunner.shared?.shutdown()
                exit(0)
            }
        }

        monitor.startMonitoring()
        RunLoop.current.run()
    }

    func shutdown() {
        pipeline.reset()
        monitor.stopMonitoring()
    }

    func hidDeviceMonitor(_ monitor: HIDDeviceMonitor, didDetectDevices devices: [HIDDeviceInfo]) {
        print("\n--- Connected USB HID Devices (\(devices.count)) ---")
        for d in devices {
            let marker = config.matches(device: d) ? "*" : " "
            print("  \(marker) \(d.product) (\(d.manufacturer)) | \(d.shortLabel)")
        }
        print("  ('*' = drives the cursor)")
        print("---------------------------------------------------\n")
    }

    func hidDeviceMonitor(_ monitor: HIDDeviceMonitor, didResolveMultiTouchLayout layout: MultiTouchLayout, forDevice device: HIDDeviceInfo) {
        pipeline.multiTouchLayout = layout
        print("Multi-touch: \(layout.maxContacts) contacts via report 0x\(String(format: "%02X", layout.reportID))")
    }

    func hidDeviceMonitor(_ monitor: HIDDeviceMonitor, didReceiveReport data: Data, reportID: UInt32, fromDevice device: HIDDeviceInfo) {
        if isInspectMode {
            guard device.isTouchDevice else { return }
            let hexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            print(String(format: "[%@] ID:0x%02X (%d bytes): %@", device.product, reportID, data.count, hexString))
            return
        }

        guard let result = pipeline.process(reportData: data, reportID: reportID, from: device) else { return }

        print(String(format: "[Touch] Raw: (%5.0f, %5.0f) -> Screen: (%7.1f, %7.1f) | %@",
                     result.raw.rawX, result.raw.rawY,
                     result.screenPoint.x, result.screenPoint.y,
                     result.raw.isDown ? "DOWN" : "UP"))
    }

    static var shared: DaemonRunner?
}

let args = CommandLine.arguments
if args.contains("--help") || args.contains("-h") {
    print("""

    Usage: hidtouch-daemon [--inspect]

      --inspect   Dump raw HID packets as hex without seizing the device or
                  injecting any events. Use the offsets shown here to fill in
                  the report format in HIDTouch Studio.

    Configuration is read from \(ConfigManager.shared.fileURL.path)
    """)
    exit(0)
}

let runner = DaemonRunner(config: ConfigManager.shared.loadConfig())
DaemonRunner.shared = runner
runner.start(inspect: args.contains("--inspect"))
