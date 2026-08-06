import Foundation
import CoreGraphics
import HIDDriverCore

print("HIDTouch core self-test")

// MARK: - Calibration

Check.suite("AffineMatrix / calibration") {
    // Samples generated from a known affine map must recover that map.
    let expected = AffineMatrix(a: 0.4688, b: 0.0, c: -30.0, d: 0.0, e: -0.2637, f: 1110.0)
    let raws: [(Double, Double)] = [(410, 410), (3686, 410), (3686, 3686), (410, 3686)]
    let points = raws.map { rx, ry -> CalibrationPoint in
        let s = expected.transform(rawX: rx, rawY: ry)
        return CalibrationPoint(rawX: rx, rawY: ry, screenX: s.x, screenY: s.y)
    }

    if let m = AffineMatrix.compute(from: points) {
        Check.close(m.a, expected.a, 1e-6, "recovers coefficient a")
        Check.close(m.c, expected.c, 1e-3, "recovers offset c")
        Check.close(m.e, expected.e, 1e-6, "recovers coefficient e")
        Check.close(m.f, expected.f, 1e-3, "recovers offset f")
        Check.close(m.meanError(for: points), 0, 1e-3, "residual is ~0 for exact samples")
    } else {
        Check.expect(false, "solves a well-conditioned 4-point system")
    }

    // A rotated panel needs the cross terms b and d.
    let rotated = AffineMatrix(a: 0.0, b: 0.5, c: 12.0, d: -0.35, e: 0.0, f: 900.0)
    let rotatedRaws: [(Double, Double)] = [(100, 200), (3000, 250), (2900, 3100), (150, 3000)]
    let rotatedPoints = rotatedRaws.map { rx, ry -> CalibrationPoint in
        let s = rotated.transform(rawX: rx, rawY: ry)
        return CalibrationPoint(rawX: rx, rawY: ry, screenX: s.x, screenY: s.y)
    }
    if let m = AffineMatrix.compute(from: rotatedPoints) {
        Check.close(m.meanError(for: rotatedPoints), 0, 1e-3, "fits a rotated / flipped panel")
    } else {
        Check.expect(false, "fits a rotated / flipped panel")
    }

    // Degenerate inputs must be reported, not silently turned into identity.
    Check.expect(AffineMatrix.compute(from: Array(points.prefix(2))) == nil,
                 "rejects fewer than 3 points")

    let collinear = (0..<4).map { i -> CalibrationPoint in
        let t = Double(i) * 1000.0
        return CalibrationPoint(rawX: t, rawY: t, screenX: t * 0.5, screenY: t * 0.5)
    }
    Check.expect(AffineMatrix.compute(from: collinear) == nil, "rejects collinear samples")

    let duplicates = Array(repeating: CalibrationPoint(rawX: 2048, rawY: 2048, screenX: 720, screenY: 450), count: 4)
    Check.expect(AffineMatrix.compute(from: duplicates) == nil, "rejects four taps on the same spot")

    // Noisy samples still fit, and the residual reflects the noise.
    let truth = AffineMatrix(a: 0.5, b: 0.0, c: 0.0, d: 0.0, e: 0.5, f: 0.0)
    let noisy = zip([(0.0, 0.0), (4000.0, 0.0), (4000.0, 4000.0), (0.0, 4000.0)],
                    [(5.0, -5.0), (-5.0, 5.0), (5.0, 5.0), (-5.0, -5.0)]).map { raw, n -> CalibrationPoint in
        let s = truth.transform(rawX: raw.0, rawY: raw.1)
        return CalibrationPoint(rawX: raw.0, rawY: raw.1, screenX: s.x + n.0, screenY: s.y + n.1)
    }
    if let m = AffineMatrix.compute(from: noisy) {
        let e = m.meanError(for: noisy)
        Check.expect(e > 1.0 && e < 20.0, "reports a non-zero residual for noisy samples (got \(String(format: "%.2f", e)) px)")
    } else {
        Check.expect(false, "fits noisy samples")
    }
}

// The end-to-end path calibration actually takes: crosshairs at 10%/90% of a
// secondary display whose global origin is not (0, 0), on a y-inverted panel.
Check.suite("Calibration on an offset display") {
    let bounds = CGRect(x: 1920, y: -180, width: 1280, height: 800)
    let ratios: [CGPoint] = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1),
                             CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.1, y: 0.9)]
    let rawFor: (CGPoint) -> (Double, Double) = { r in (r.x * 4095.0, (1.0 - r.y) * 4095.0) }

    let points = ratios.map { r -> CalibrationPoint in
        let raw = rawFor(r)
        return CalibrationPoint(rawX: raw.0, rawY: raw.1,
                                screenX: bounds.origin.x + bounds.width * r.x,
                                screenY: bounds.origin.y + bounds.height * r.y)
    }

    guard let m = AffineMatrix.compute(from: points) else {
        Check.expect(false, "computes a matrix for the offset display")
        Check.summarize()
    }

    let centre = rawFor(CGPoint(x: 0.5, y: 0.5))
    let mapped = m.transform(rawX: centre.0, rawY: centre.1)
    Check.close(mapped.x, bounds.midX, 0.5, "panel centre maps to display centre X")
    Check.close(mapped.y, bounds.midY, 0.5, "panel centre maps to display centre Y")

    let topLeft = m.transform(rawX: 0, rawY: 4095)
    Check.close(topLeft.x, bounds.minX, 0.5, "extrapolates to the display's left edge")
    Check.close(topLeft.y, bounds.minY, 0.5, "extrapolates to the display's top edge")
}

// MARK: - Parser

Check.suite("HIDParser") {
    func packet(_ bytes: [UInt8]) -> Data { Data(bytes) }

    let parser = HIDParser(format: .standardWin8Touchscreen)
    if let p = parser.parse(reportData: packet([0x01, 0x01, 0x34, 0x12, 0x78, 0x56])) {
        Check.equal(p.rawX, 0x1234, "little-endian X")
        Check.equal(p.rawY, 0x5678, "little-endian Y")
        Check.expect(p.isDown, "tip switch reads as down")
    } else {
        Check.expect(false, "parses a standard little-endian report")
    }

    var beFormat = HIDReportFormat.standardWin8Touchscreen
    beFormat.isLittleEndian = false
    let beParser = HIDParser(format: beFormat)
    if let p = beParser.parse(reportData: packet([0x01, 0x01, 0x12, 0x34, 0x56, 0x78])) {
        Check.equal(p.rawX, 0x1234, "big-endian X")
        Check.equal(p.rawY, 0x5678, "big-endian Y")
    } else {
        Check.expect(false, "parses a big-endian report")
    }

    var maskFormat = HIDReportFormat.standardWin8Touchscreen
    maskFormat.touchStateBitMask = 0x04
    let maskParser = HIDParser(format: maskFormat)
    Check.expect(maskParser.parse(reportData: packet([0x01, 0x04, 0, 1, 0, 1]))?.isDown == true,
                 "custom bit mask detects touch down")
    Check.expect(maskParser.parse(reportData: packet([0x01, 0x03, 0, 1, 0, 1]))?.isDown == false,
                 "custom bit mask detects touch up")

    // A packet exactly long enough to hold the high byte of the last field must
    // parse; the bounds check used to be one byte off in this direction.
    Check.expect(parser.parse(reportData: packet([0x01, 0x01, 0xFF, 0x0F, 0xEE, 0x0E])) != nil,
                 "accepts an exactly-sized packet")

    Check.expect(parser.parse(reportData: packet([0x01, 0x01, 0x34, 0x12, 0x78])) == nil,
                 "rejects a short packet")
    Check.equal(parser.lastRejection, .tooShort(needed: 6, actual: 5), "reports why it was rejected")

    // A hand-edited config with a negative offset must not trap.
    var negativeFormat = HIDReportFormat.standardWin8Touchscreen
    negativeFormat.xByteOffset = -1
    let negativeParser = HIDParser(format: negativeFormat)
    Check.expect(negativeParser.parse(reportData: packet([0x01, 0x01, 0x34, 0x12, 0x78, 0x56])) == nil,
                 "rejects a negative byte offset instead of crashing")
    Check.equal(negativeParser.lastRejection, .negativeOffset, "reports the negative offset")

    var idFormat = HIDReportFormat.standardWin8Touchscreen
    idFormat.reportID = 2
    let idParser = HIDParser(format: idFormat)
    let data = packet([0x01, 0x01, 0x34, 0x12, 0x78, 0x56])
    Check.expect(idParser.parse(reportData: data, reportID: 1) == nil, "report ID filter rejects other IDs")
    Check.expect(idParser.parse(reportData: data, reportID: 2) != nil, "report ID filter accepts its ID")
    Check.expect(parser.parse(reportData: data, reportID: 7) != nil, "no filter accepts any report ID")

    var gateFormat = HIDReportFormat.standardWin8Touchscreen
    gateFormat.rawMaxX = 4095
    gateFormat.rawMaxY = 4095
    let gateParser = HIDParser(format: gateFormat)
    Check.expect(gateParser.parse(reportData: packet([0x01, 0x01, 0xFF, 0x0F, 0xFF, 0x0F])) != nil,
                 "raw max gate accepts in-range samples")
    Check.expect(gateParser.parse(reportData: packet([0x01, 0x01, 0x00, 0x10, 0x00, 0x10])) == nil,
                 "raw max gate discards out-of-range samples")
}

// MARK: - Jitter filter

Check.suite("JitterFilter") {
    var filter = JitterFilter(smoothingFactor: 0.5, deadbandPixels: 2.0)
    Check.equal(filter.filter(point: CGPoint(x: 100, y: 200)), CGPoint(x: 100, y: 200),
                "first point passes through unchanged")

    var deadband = JitterFilter(smoothingFactor: 1.0, deadbandPixels: 5.0)
    _ = deadband.filter(point: CGPoint(x: 100, y: 100))
    Check.equal(deadband.filter(point: CGPoint(x: 102, y: 101)), CGPoint(x: 100, y: 100),
                "deadband suppresses sub-threshold movement")

    var smooth = JitterFilter(smoothingFactor: 0.5, deadbandPixels: 0)
    _ = smooth.filter(point: CGPoint(x: 0, y: 0))
    let lagged = smooth.filter(point: CGPoint(x: 10, y: 0))
    Check.expect(lagged.x > 0 && lagged.x < 10, "smoothing lags behind the target")

    var clamped = JitterFilter()
    clamped.configure(smoothingFactor: -5, deadbandPixels: -3)
    Check.close(clamped.smoothingFactor, 0.01, 1e-9, "configure clamps smoothing to the low bound")
    Check.close(clamped.deadbandPixels, 0.0, 1e-9, "configure clamps deadband to zero")
    clamped.configure(smoothingFactor: 9, deadbandPixels: 4)
    Check.close(clamped.smoothingFactor, 1.0, 1e-9, "configure clamps smoothing to the high bound")

    var nanSafe = JitterFilter(smoothingFactor: 0.5, deadbandPixels: 0)
    _ = nanSafe.filter(point: CGPoint(x: 50, y: 50))
    Check.equal(nanSafe.filter(point: CGPoint(x: CGFloat.nan, y: 0)), CGPoint(x: 50, y: 50),
                "non-finite input is ignored")

    var resettable = JitterFilter(smoothingFactor: 0.5, deadbandPixels: 0)
    _ = resettable.filter(point: .zero)
    resettable.reset()
    Check.equal(resettable.filter(point: CGPoint(x: 500, y: 500)), CGPoint(x: 500, y: 500),
                "reset drops the filter history")
}

// MARK: - Config

Check.suite("DriverConfig") {
    var config = DriverConfig.defaultConfig
    config.affineMatrix = AffineMatrix(a: 1, b: 2, c: 3, d: 4, e: 5, f: 6)
    config.calibrationPoints = [CalibrationPoint(rawX: 1, rawY: 2, screenX: 3, screenY: 4)]
    config.targetDisplayID = 42
    config.outputMode = .mouseEmulation

    if let data = try? JSONEncoder().encode(config),
       let decoded = try? JSONDecoder().decode(DriverConfig.self, from: data) {
        Check.equal(decoded, config, "round-trips through JSON")
    } else {
        Check.expect(false, "round-trips through JSON")
    }

    // A file written by an older build is missing newer keys; the calibration it
    // does contain must survive.
    let partial = """
    {
      "selectedVendorID": 1234,
      "selectedProductID": 5678,
      "affineMatrix": {"a": 0.5, "b": 0.0, "c": -10.0, "d": 0.0, "e": 0.25, "f": 8.0},
      "calibrationPoints": [{"rawX": 1, "rawY": 2, "screenX": 3, "screenY": 4}]
    }
    """
    if let decoded = try? JSONDecoder().decode(DriverConfig.self, from: Data(partial.utf8)) {
        Check.equal(decoded.selectedVendorID, 1234, "keeps known keys from an older file")
        Check.equal(decoded.calibrationPoints.count, 1, "keeps the stored calibration")
        Check.equal(decoded.outputMode, DriverConfig.defaultConfig.outputMode, "defaults the missing keys")
    } else {
        Check.expect(false, "decodes a config missing newer keys")
    }

    // One corrupt value must not discard the rest of the file.
    let malformed = """
    {
      "outputMode": "Some Mode That No Longer Exists",
      "smoothingFactor": 0.9,
      "affineMatrix": {"a": 2.0, "b": 0.0, "c": 0.0, "d": 0.0, "e": 2.0, "f": 0.0}
    }
    """
    if let decoded = try? JSONDecoder().decode(DriverConfig.self, from: Data(malformed.utf8)) {
        Check.equal(decoded.outputMode, DriverConfig.defaultConfig.outputMode, "falls back on a malformed enum")
        Check.close(decoded.smoothingFactor, 0.9, 1e-9, "keeps the neighbouring valid values")
        Check.close(decoded.affineMatrix.a, 2.0, 1e-9, "keeps the calibration next to a malformed value")
    } else {
        Check.expect(false, "survives a malformed value")
    }

    // An uncalibrated identity matrix plus mouse emulation would fling the
    // cursor to raw sensor coordinates, so injection must be opt-in.
    Check.equal(DriverConfig.defaultConfig.outputMode, .debugOnly, "does not inject events by default")
    Check.expect(HIDReportFormat.standardWin8Touchscreen.reportID == nil, "accepts any report ID by default")
}

// MARK: - Device classification

Check.suite("Device classification") {
    func device(vid: Int = 0x1234, pid: Int = 0x5678, product: String = "Touch Panel",
                manufacturer: String = "Generic", usagePage: Int = 0x0D, usage: Int = 0x04) -> HIDDeviceInfo {
        HIDDeviceInfo(vendorID: vid, productID: pid, manufacturer: manufacturer,
                      product: product, usagePage: usagePage, usage: usage)
    }

    var auto = DriverConfig.defaultConfig
    auto.selectedVendorID = 0
    auto.selectedProductID = 0
    Check.expect(auto.matches(device: device()), "auto-detect drives a digitizer")
    Check.expect(!auto.matches(device: device(product: "REALFORCE R3", usagePage: 0x01, usage: 0x06)),
                 "auto-detect ignores a keyboard")

    var pinned = DriverConfig.defaultConfig
    pinned.selectedVendorID = 0x1234
    pinned.selectedProductID = 0x5678
    Check.expect(pinned.matches(device: device()), "pinned VID/PID matches its device")
    Check.expect(!pinned.matches(device: device(vid: 1, pid: 2)), "pinned VID/PID ignores other devices")

    Check.expect(!device(usagePage: 0x01, usage: 0x06).isTouchDevice, "keyboard usage is not a touch device")
    Check.expect(!device(usagePage: 0x01, usage: 0x07).isTouchDevice, "keypad usage is not a touch device")
    Check.expect(!device(usagePage: 0x0C, usage: 0x01).isTouchDevice, "consumer page is not a touch device")
    Check.expect(device(product: "USB Touch Mouse", usagePage: 0x0D, usage: 0x04).isTouchDevice,
                 "digitizer usage beats the product-name blacklist")
    // Cheap panels enumerate as Generic Desktop / Mouse, so usage alone cannot
    // be the filter.
    Check.expect(device(product: "HID Touch Panel", usagePage: 0x01, usage: 0x02).isTouchDevice,
                 "a mouse-usage panel is still detected")
    Check.expect(!device(product: "G Pro Wireless", manufacturer: "Logitech LIGHTSPEED",
                         usagePage: 0x01, usage: 0x02).isTouchDevice,
                 "a known mouse product name is excluded")

    // A panel exposing a digitizer and a mouse collection under one VID/PID must
    // produce two entries rather than collapsing into one.
    Check.expect(device(usagePage: 0x0D, usage: 0x04).id != device(usagePage: 0x01, usage: 0x02).id,
                 "two interfaces of one product get distinct ids")
}

// Classification against the devices actually enumerated on the development
// machine, captured from `hidtouch-daemon --inspect`.
Check.suite("Device classification against real hardware") {
    func device(_ vid: Int, _ pid: Int, _ product: String, _ manufacturer: String,
                _ usagePage: Int, _ usage: Int) -> HIDDeviceInfo {
        HIDDeviceInfo(vendorID: vid, productID: pid, manufacturer: manufacturer,
                      product: product, usagePage: usagePage, usage: usage)
    }

    // The Goodix/WingCool panel exposes three interfaces under one VID/PID.
    let panelMouse = device(0x27C6, 0x0529, "TouchScreen", "WingCool Inc.", 0x01, 0x02)
    let panelDigitizer = device(0x27C6, 0x0529, "TouchScreen", "WingCool Inc.", 0x0D, 0x02)
    let panelVendor = device(0x27C6, 0x0529, "TouchScreen", "WingCool Inc.", 0xFF00, 0xFF)

    Check.expect(panelDigitizer.isTouchDevice, "the panel's digitizer interface is detected")
    Check.expect(panelMouse.isTouchDevice, "the panel's mouse interface is detected")
    Check.expect(!panelVendor.isTouchDevice, "the panel's vendor-defined interface is ignored")
    Check.expect(Set([panelMouse.id, panelDigitizer.id, panelVendor.id]).count == 3,
                 "all three interfaces of the panel are distinguishable")

    // False positives observed before the classifier was tightened.
    Check.expect(!device(0x05AC, 0x0265, "HID Device", "Generic", 0x01, 0x02).isTouchDevice,
                 "the built-in Apple trackpad is not a touch panel")
    Check.expect(!device(0x0000, 0x0000, "HID Device", "Apple", 0xFF00, 0xFF).isTouchDevice,
                 "an Apple vendor-defined interface is not a touch panel")
    Check.expect(!device(0x0000, 0x0000, "BTM", "APPL", 0xFF00, 0x48).isTouchDevice,
                 "the Bluetooth management interface is not a touch panel")

    // Devices that were already classified correctly must stay that way.
    Check.expect(!device(0x046D, 0xC098, "G502 X LIGHTSPEED", "Logitech", 0x01, 0x02).isTouchDevice,
                 "the Logitech mouse stays excluded")
    Check.expect(!device(0x0853, 0x031A, "REALFORCE C1H", "Topre", 0x01, 0x06).isTouchDevice,
                 "the REALFORCE keyboard stays excluded")
    Check.expect(!device(0x0000, 0x0000, "Headset", "Apple", 0x0C, 0x01).isTouchDevice,
                 "the headset consumer-control interface stays excluded")
    Check.expect(!device(0x05AC, 0x0251, "Karabiner DriverKit VirtualHIDKeyboard 1.8.0", "pqrs.org", 0x01, 0x06).isTouchDevice,
                 "the Karabiner virtual keyboard stays excluded")
}

// MARK: - Report descriptor parsing / multi-touch

Check.suite("HID report descriptor (real panel)") {
    let layout = MultiTouchLayout.from(descriptor: PanelFixture.digitizerDescriptor)
    guard let layout = layout else {
        Check.expect(false, "derives a multi-touch layout from the descriptor")
        Check.summarize()
    }

    Check.equal(layout.reportID, 0x0D, "finds the touchscreen report ID")
    Check.equal(layout.maxContacts, 10, "finds all 10 finger collections")
    Check.equal(layout.logicalMaxX, 16383, "reads the X logical maximum")
    Check.equal(layout.logicalMaxY, 9599, "reads the Y logical maximum")
    Check.equal(layout.reportLengthBytes, 52, "computes the report length")

    // Contact blocks are 5 bytes here: 1 status byte then X and Y as 16-bit LE.
    let first = layout.contacts[0]
    Check.equal(first.tipSwitchBitOffset, 0, "first contact tip switch at bit 0")
    Check.equal(first.contactIDBitOffset, 4, "first contact identifier at bit 4")
    Check.equal(first.xBitOffset, 8, "first contact X at bit 8")
    Check.equal(first.xBitSize, 16, "X is 16 bits")
    Check.equal(first.yBitOffset, 24, "first contact Y at bit 24")

    let second = layout.contacts[1]
    Check.equal(second.tipSwitchBitOffset, 40, "second contact starts 5 bytes later")
    Check.equal(second.xBitOffset, 48, "second contact X at bit 48")

    Check.equal(layout.contactCountBitOffset, 400, "contact count follows the 10 contacts")

    // The Device Configuration collection is what switches the panel out of
    // mouse emulation.
    Check.equal(HIDDeviceMonitor.deviceConfigurationReportID(in: PanelFixture.digitizerDescriptor), 0x21,
                "finds the device configuration report ID")
}

Check.suite("Multi-touch parsing (real packet)") {
    guard let layout = MultiTouchLayout.from(descriptor: PanelFixture.digitizerDescriptor) else {
        Check.expect(false, "layout available")
        Check.summarize()
    }
    let parser = MultiTouchParser(layout: layout)

    guard let frame = parser.parse(Data(PanelFixture.twoFingerReport), reportID: 0x0D) else {
        Check.expect(false, "parses the captured two-finger report")
        Check.summarize()
    }

    Check.equal(frame.count, 2, "sees two contacts")
    if frame.count == 2 {
        Check.equal(frame.contacts[0].id, 1, "first contact identifier")
        Check.equal(frame.contacts[0].rawX, 7034, "first contact X")
        Check.equal(frame.contacts[0].rawY, 8229, "first contact Y")
        Check.equal(frame.contacts[1].id, 0, "second contact identifier")
        Check.equal(frame.contacts[1].rawX, 10610, "second contact X")
        Check.equal(frame.contacts[1].rawY, 5659, "second contact Y")
    }

    Check.close(frame.centroid.x, (7034 + 10610) / 2, 0.001, "centroid X is the mean")
    Check.close(frame.centroid.y, (8229 + 5659) / 2, 0.001, "centroid Y is the mean")

    // A report for a different collection must not be mistaken for touch data.
    Check.expect(parser.parse(Data(PanelFixture.twoFingerReport), reportID: 0x05) == nil,
                 "ignores reports from another collection")

    // An all-zero report means every finger lifted.
    let empty = parser.parse(Data([0x0D] + [UInt8](repeating: 0, count: 51)), reportID: 0x0D)
    Check.equal(empty?.count, 0, "an empty report reports no contacts")

    // Truncated data must not read out of bounds.
    Check.expect(parser.parse(Data([0x0D, 0x01]), reportID: 0x0D)?.isEmpty != false
                 || parser.parse(Data([0x0D, 0x01]), reportID: 0x0D) != nil,
                 "a truncated report does not crash")
}

Check.suite("Bit extraction") {
    // HID packs fields least-significant-bit first within each byte.
    let bytes: [UInt8] = [0b1010_0001, 0b0000_0011]
    Check.equal(MultiTouchParser.bits(bytes, bitOffset: 0, bitCount: 1), 1, "bit 0")
    Check.equal(MultiTouchParser.bits(bytes, bitOffset: 5, bitCount: 3), 0b101, "bits 5-7")
    Check.equal(MultiTouchParser.bits(bytes, bitOffset: 8, bitCount: 8), 0b11, "second byte")
    Check.equal(MultiTouchParser.bits(bytes, bitOffset: 0, bitCount: 16), 0x03A1, "16-bit little endian")
    Check.expect(MultiTouchParser.bits(bytes, bitOffset: 12, bitCount: 8) == nil, "reads past the end return nil")
}

Check.suite("Gesture recognition") {
    func contact(_ id: Int, _ x: Double, _ y: Double) -> TouchContact {
        TouchContact(id: id, rawX: x, rawY: y)
    }

    var g = GestureRecognizer(scrollSensitivity: 1.0, scrollActivationPixels: 6.0, naturalScrolling: true)

    // One finger drives the pointer.
    if case .pointer(let c) = g.handle(contacts: [contact(0, 100, 100)]) {
        Check.equal(c.rawX, 100, "one finger reports a pointer at its position")
    } else {
        Check.expect(false, "one finger reports a pointer")
    }

    // Two fingers must travel past the threshold before scrolling starts, so a
    // two-finger tap does not nudge the view.
    g.reset()
    _ = g.handle(contacts: [contact(0, 100, 100), contact(1, 200, 100)])
    if case .none = g.handle(contacts: [contact(0, 101, 101), contact(1, 201, 101)]) {
        Check.expect(true, "a small two-finger movement does not scroll")
    } else {
        Check.expect(false, "a small two-finger movement does not scroll")
    }

    // Past the threshold it scrolls by the centroid delta.
    let action = g.handle(contacts: [contact(0, 100, 130), contact(1, 200, 130)])
    if case .scroll(let dx, let dy) = action {
        Check.close(dx, -1, 0.001, "scroll dx follows the centroid")
        Check.close(dy, 29, 0.001, "scroll dy follows the centroid")
    } else {
        Check.expect(false, "crossing the threshold produces a scroll")
    }

    // Inverted direction flips the sign.
    var natural = GestureRecognizer(scrollSensitivity: 1.0, scrollActivationPixels: 0, naturalScrolling: false)
    _ = natural.handle(contacts: [contact(0, 0, 0), contact(1, 100, 0)])
    if case .scroll(_, let dy) = natural.handle(contacts: [contact(0, 0, 10), contact(1, 100, 10)]) {
        Check.expect(dy < 0, "disabling natural scrolling inverts the direction")
    } else {
        Check.expect(false, "produces a scroll with natural scrolling off")
    }

    // Sensitivity scales the delta.
    var fast = GestureRecognizer(scrollSensitivity: 2.0, scrollActivationPixels: 0, naturalScrolling: true)
    _ = fast.handle(contacts: [contact(0, 0, 0), contact(1, 100, 0)])
    if case .scroll(_, let dy) = fast.handle(contacts: [contact(0, 0, 10), contact(1, 100, 10)]) {
        Check.close(dy, 20, 0.001, "sensitivity scales the scroll delta")
    } else {
        Check.expect(false, "scales the scroll delta")
    }

    // A finger landing or lifting must not emit the centroid jump as a scroll.
    var landing = GestureRecognizer(scrollSensitivity: 1.0, scrollActivationPixels: 0, naturalScrolling: true)
    _ = landing.handle(contacts: [contact(0, 0, 0)])
    if case .none = landing.handle(contacts: [contact(0, 0, 0), contact(1, 900, 900)]) {
        Check.expect(true, "a second finger landing does not fling the view")
    } else {
        Check.expect(false, "a second finger landing does not fling the view")
    }

    // MARK: Pinch

    // Fingers moving apart past the threshold zoom in; the delta is a fraction
    // of the current separation, not a distance.
    var pinch = GestureRecognizer(scrollActivationPixels: 6, pinchEnabled: true,
                                  pinchSensitivity: 1.0, pinchActivationPixels: 12)
    _ = pinch.handle(contacts: [contact(0, 0, 0), contact(1, 100, 0)])
    if case .magnify(let delta) = pinch.handle(contacts: [contact(0, -10, 0), contact(1, 110, 0)]) {
        Check.expect(delta > 0, "spreading the fingers zooms in")
        Check.close(delta, 20.0 / 100.0, 0.001, "pinch delta is the fractional change in separation")
    } else {
        Check.expect(false, "spreading the fingers past the threshold pinches")
    }

    // Bringing them together zooms out.
    var pinchIn = GestureRecognizer(pinchEnabled: true, pinchActivationPixels: 12)
    _ = pinchIn.handle(contacts: [contact(0, 0, 0), contact(1, 200, 0)])
    if case .magnify(let delta) = pinchIn.handle(contacts: [contact(0, 20, 0), contact(1, 180, 0)]) {
        Check.expect(delta < 0, "closing the fingers zooms out")
    } else {
        Check.expect(false, "closing the fingers pinches")
    }

    // The same separation change scales the same amount regardless of how far
    // apart the fingers started — that is the point of using a ratio.
    var near = GestureRecognizer(pinchEnabled: true, pinchActivationPixels: 5)
    var far = GestureRecognizer(pinchEnabled: true, pinchActivationPixels: 5)
    _ = near.handle(contacts: [contact(0, 0, 0), contact(1, 100, 0)])
    _ = far.handle(contacts: [contact(0, 0, 0), contact(1, 400, 0)])
    if case .magnify(let a) = near.handle(contacts: [contact(0, 0, 0), contact(1, 110, 0)]),
       case .magnify(let b) = far.handle(contacts: [contact(0, 0, 0), contact(1, 440, 0)]) {
        Check.close(a, b, 0.001, "a 10% spread means the same zoom at any finger distance")
    } else {
        Check.expect(false, "both distances produce a pinch")
    }

    // A pan holds its separation, so it must stay a scroll however far it goes.
    var pan = GestureRecognizer(scrollActivationPixels: 6, pinchEnabled: true, pinchActivationPixels: 12)
    _ = pan.handle(contacts: [contact(0, 0, 0), contact(1, 100, 0)])
    var stayedScroll = true
    for step in stride(from: 20.0, through: 400.0, by: 20.0) {
        if case .magnify = pan.handle(contacts: [contact(0, step, step), contact(1, 100 + step, step)]) {
            stayedScroll = false
        }
    }
    Check.expect(stayedScroll, "a long pan never turns into a pinch")

    // Once decided, the mode is locked: a pinch that drags its centroid must
    // not start scrolling halfway through.
    var locked = GestureRecognizer(scrollActivationPixels: 6, pinchEnabled: true, pinchActivationPixels: 12)
    _ = locked.handle(contacts: [contact(0, 0, 0), contact(1, 100, 0)])
    _ = locked.handle(contacts: [contact(0, -20, 0), contact(1, 120, 0)])
    var stayedPinch = true
    for step in stride(from: 10.0, through: 200.0, by: 10.0) {
        if case .scroll = locked.handle(contacts: [contact(0, -20 + step, step), contact(1, 120 + step, step)]) {
            stayedPinch = false
        }
    }
    Check.expect(stayedPinch, "a pinch that drifts does not become a scroll")

    // With pinch off, spreading the fingers must produce nothing at all — a
    // symmetric spread leaves the centroid where it was, so there is no pan to
    // report either.
    var noPinch = GestureRecognizer(scrollActivationPixels: 6, pinchEnabled: false, pinchActivationPixels: 12)
    _ = noPinch.handle(contacts: [contact(0, 0, 0), contact(1, 100, 0)])
    if case .none = noPinch.handle(contacts: [contact(0, -50, 0), contact(1, 150, 0)]) {
        Check.expect(true, "with pinch off, spreading the fingers does nothing")
    } else {
        Check.expect(false, "with pinch off, spreading the fingers does nothing")
    }

    // Panning is unaffected by the pinch switch.
    var noPinchPan = GestureRecognizer(scrollActivationPixels: 6, pinchEnabled: false)
    _ = noPinchPan.handle(contacts: [contact(0, 0, 0), contact(1, 100, 0)])
    if case .scroll = noPinchPan.handle(contacts: [contact(0, 0, 40), contact(1, 100, 40)]) {
        Check.expect(true, "with pinch off, a two-finger pan still scrolls")
    } else {
        Check.expect(false, "with pinch off, a two-finger pan still scrolls")
    }

    // Sensitivity scales the fraction handed to the application.
    var strong = GestureRecognizer(pinchEnabled: true, pinchSensitivity: 3.0, pinchActivationPixels: 5)
    _ = strong.handle(contacts: [contact(0, 0, 0), contact(1, 100, 0)])
    if case .magnify(let delta) = strong.handle(contacts: [contact(0, -5, 0), contact(1, 105, 0)]) {
        Check.close(delta, 10.0 / 100.0 * 3.0, 0.001, "pinch sensitivity scales the delta")
    } else {
        Check.expect(false, "pinch sensitivity scales the delta")
    }

    // Three or more fingers are tracked but not mapped to anything.
    var many = GestureRecognizer()
    _ = many.handle(contacts: [contact(0, 0, 0), contact(1, 10, 0), contact(2, 20, 0)])
    if case .none = many.handle(contacts: [contact(0, 0, 50), contact(1, 10, 50), contact(2, 20, 50)]) {
        Check.expect(true, "three fingers produce no injection")
    } else {
        Check.expect(false, "three fingers produce no injection")
    }

    // Lifting everything returns to idle.
    var lift = GestureRecognizer()
    _ = lift.handle(contacts: [contact(0, 5, 5)])
    if case .none = lift.handle(contacts: []) {
        Check.expect(true, "an empty frame is idle")
    } else {
        Check.expect(false, "an empty frame is idle")
    }
}

Check.suite("Output mode availability") {
    // Mouse emulation and debug-only are always deliverable.
    Check.expect(TouchOutputMode.mouseEmulation.isAvailable, "mouse emulation is always available")
    Check.expect(TouchOutputMode.debugOnly.isAvailable, "debug-only is always available")

    // Virtual multi-touch depends on a restricted entitlement, so it tracks
    // whatever this build actually carries.
    Check.equal(TouchOutputMode.virtualHID.isAvailable, Permissions.hasVirtualHIDEntitlement,
                "virtual multi-touch availability follows the entitlement")
    Check.equal(TouchOutputMode.availableCases.contains(.virtualHID), Permissions.hasVirtualHIDEntitlement,
                "the picker only offers virtual multi-touch when it would work")
    Check.expect(TouchOutputMode.availableCases.contains(.mouseEmulation),
                 "mouse emulation is always offered")

    // A stored mode this build cannot honour is substituted, never left to
    // silently degrade.
    Check.equal(TouchOutputMode.mouseEmulation.resolvedForThisBuild, .mouseEmulation,
                "an available mode is left alone")
    Check.equal(TouchOutputMode.debugOnly.resolvedForThisBuild, .debugOnly,
                "debug-only is left alone")
    let resolvedVirtual = TouchOutputMode.virtualHID.resolvedForThisBuild
    Check.expect(resolvedVirtual.isAvailable, "the substituted mode is itself available")
    if !Permissions.hasVirtualHIDEntitlement {
        Check.equal(resolvedVirtual, .mouseEmulation, "virtual multi-touch falls back to mouse emulation")
    }
}

Check.summarize()
