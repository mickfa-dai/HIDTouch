import Foundation

public struct DriverConfig: Codable, Equatable {
    /// 0/0 means "auto-detect": every device passing `isTouchDevice` drives the
    /// cursor. Otherwise only the matching VID/PID does.
    public var selectedVendorID: Int
    public var selectedProductID: Int
    public var reportFormat: HIDReportFormat
    public var calibrationPoints: [CalibrationPoint]
    public var affineMatrix: AffineMatrix
    public var smoothingFactor: Double
    public var deadbandPixels: Double
    public var outputMode: TouchOutputMode
    public var targetDisplayID: UInt32?
    /// Take exclusive ownership of the touch device (see `HIDDeviceMonitor`).
    public var seizeTouchDevices: Bool
    /// Switch the panel out of mouse emulation and decode multi-contact reports.
    public var multiTouchEnabled: Bool
    /// Screen pixels of scroll per pixel of two-finger travel.
    public var scrollSensitivity: Double
    /// Combined travel required before a two-finger pan becomes a scroll.
    public var scrollActivationPixels: Double
    /// Content follows the fingers, as macOS does by default.
    public var naturalScrolling: Bool

    public static let defaultConfig = DriverConfig(
        selectedVendorID: 0,
        selectedProductID: 0,
        reportFormat: .standardWin8Touchscreen,
        calibrationPoints: [],
        affineMatrix: .identity,
        smoothingFactor: 0.45,
        deadbandPixels: 1.0,
        // Injection is off until the user has inspected the packet format and
        // calibrated: an identity matrix plus mouse emulation would warp the
        // cursor to raw sensor coordinates the moment a panel is plugged in.
        outputMode: .debugOnly,
        targetDisplayID: nil,
        seizeTouchDevices: true,
        multiTouchEnabled: true,
        scrollSensitivity: 1.0,
        scrollActivationPixels: 6.0,
        naturalScrolling: true
    )

    public init(selectedVendorID: Int, selectedProductID: Int, reportFormat: HIDReportFormat, calibrationPoints: [CalibrationPoint], affineMatrix: AffineMatrix, smoothingFactor: Double, deadbandPixels: Double, outputMode: TouchOutputMode, targetDisplayID: UInt32? = nil, seizeTouchDevices: Bool = true, multiTouchEnabled: Bool = true, scrollSensitivity: Double = 1.0, scrollActivationPixels: Double = 6.0, naturalScrolling: Bool = true) {
        self.selectedVendorID = selectedVendorID
        self.selectedProductID = selectedProductID
        self.reportFormat = reportFormat
        self.calibrationPoints = calibrationPoints
        self.affineMatrix = affineMatrix
        self.smoothingFactor = smoothingFactor
        self.deadbandPixels = deadbandPixels
        self.outputMode = outputMode
        self.targetDisplayID = targetDisplayID
        self.seizeTouchDevices = seizeTouchDevices
        self.multiTouchEnabled = multiTouchEnabled
        self.scrollSensitivity = scrollSensitivity
        self.scrollActivationPixels = scrollActivationPixels
        self.naturalScrolling = naturalScrolling
    }

    /// Decode field by field so that adding a setting in a later version does
    /// not invalidate the whole file and silently wipe an existing calibration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DriverConfig.defaultConfig
        selectedVendorID = (try? c.decode(Int.self, forKey: .selectedVendorID)) ?? d.selectedVendorID
        selectedProductID = (try? c.decode(Int.self, forKey: .selectedProductID)) ?? d.selectedProductID
        reportFormat = (try? c.decode(HIDReportFormat.self, forKey: .reportFormat)) ?? d.reportFormat
        calibrationPoints = (try? c.decode([CalibrationPoint].self, forKey: .calibrationPoints)) ?? d.calibrationPoints
        affineMatrix = (try? c.decode(AffineMatrix.self, forKey: .affineMatrix)) ?? d.affineMatrix
        smoothingFactor = (try? c.decode(Double.self, forKey: .smoothingFactor)) ?? d.smoothingFactor
        deadbandPixels = (try? c.decode(Double.self, forKey: .deadbandPixels)) ?? d.deadbandPixels
        outputMode = (try? c.decode(TouchOutputMode.self, forKey: .outputMode)) ?? d.outputMode
        targetDisplayID = try? c.decodeIfPresent(UInt32.self, forKey: .targetDisplayID)
        seizeTouchDevices = (try? c.decode(Bool.self, forKey: .seizeTouchDevices)) ?? d.seizeTouchDevices
        multiTouchEnabled = (try? c.decode(Bool.self, forKey: .multiTouchEnabled)) ?? d.multiTouchEnabled
        scrollSensitivity = (try? c.decode(Double.self, forKey: .scrollSensitivity)) ?? d.scrollSensitivity
        scrollActivationPixels = (try? c.decode(Double.self, forKey: .scrollActivationPixels)) ?? d.scrollActivationPixels
        naturalScrolling = (try? c.decode(Bool.self, forKey: .naturalScrolling)) ?? d.naturalScrolling
    }

    /// Whether this device should drive the cursor.
    public func matches(device: HIDDeviceInfo) -> Bool {
        if selectedVendorID == 0 && selectedProductID == 0 {
            return device.isTouchDevice
        }
        return device.vendorID == selectedVendorID && device.productID == selectedProductID
    }
}

public class ConfigManager {
    public static let shared = ConfigManager()

    public let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("HIDTouch", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("[ConfigManager] Could not create \(dir.path): \(error.localizedDescription)")
        }
        fileURL = dir.appendingPathComponent("config.json")
    }

    public func loadConfig() -> DriverConfig {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .defaultConfig
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(DriverConfig.self, from: data)
        } catch {
            print("[ConfigManager] Failed to load \(fileURL.path): \(error.localizedDescription). Using defaults.")
            return .defaultConfig
        }
    }

    @discardableResult
    public func saveConfig(_ config: DriverConfig) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(config)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            print("[ConfigManager] Failed to save \(fileURL.path): \(error.localizedDescription)")
            return false
        }
    }
}
