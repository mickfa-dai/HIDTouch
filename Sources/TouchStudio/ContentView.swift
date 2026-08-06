import SwiftUI
import HIDDriverCore

struct ContentView: View {
    @EnvironmentObject var appModel: AppViewModel
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
                .padding()
                .background(.ultraThinMaterial)

            Divider()

            TabView(selection: $selectedTab) {
                DashboardView()
                    .tabItem { Label("Dashboard", systemImage: "macwindow.on.rectangle") }
                    .tag(0)

                InspectView()
                    .tabItem { Label("HID Inspect", systemImage: "cpu") }
                    .tag(1)

                SettingsView()
                    .tabItem { Label("Report Format", systemImage: "slider.horizontal.3") }
                    .tag(2)

                TestCanvasView()
                    .tabItem { Label("Touch Test Canvas", systemImage: "hand.draw") }
                    .tag(3)
            }
            .padding()
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct HeaderView: View {
    @EnvironmentObject var appModel: AppViewModel

    /// `targetDisplayID` is nil until the user picks one, which would leave the
    /// picker blank on first launch. Show the display the driver would actually
    /// use instead.
    private var displaySelection: Binding<UInt32> {
        Binding(
            get: { appModel.config.targetDisplayID ?? appModel.availableDisplays.first?.id ?? CGMainDisplayID() },
            set: { appModel.config.targetDisplayID = $0 }
        )
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 28))
                .foregroundStyle(.linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))

            VStack(alignment: .leading, spacing: 2) {
                Text("HIDTouch Studio")
                    .font(.title2.bold())
                Text("Universal Touch Panel Driver for macOS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                Picker("", selection: displaySelection) {
                    ForEach(appModel.availableDisplays) { disp in
                        Text(disp.name).tag(disp.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 210)
                .help("Display the touch panel is physically attached to")

                Button {
                    appModel.refreshDisplays()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rescan displays")
            }

            Picker("", selection: appModel.binding(\.outputMode)) {
                ForEach(TouchOutputMode.availableCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 210)
            .help(TouchOutputMode.virtualHID.isAvailable
                  ? "Debug / Log Only parses packets without moving the cursor"
                  : "Debug / Log Only parses packets without moving the cursor. Virtual Multi-Touch is not listed because this build lacks the required entitlement — see Report Format.")

            Button {
                appModel.startCalibration()
            } label: {
                Label("Calibrate", systemImage: "scope").bold()
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(appModel.isCalibrating)
        }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var appModel: AppViewModel

    private var uniqueProducts: [HIDDeviceInfo] {
        var seen = Set<String>()
        return appModel.connectedDevices.filter { seen.insert("\($0.vendorID):\($0.productID)").inserted }
    }

    private var driverDeviceSelection: Binding<String> {
        Binding(
            get: {
                let c = appModel.config
                return (c.selectedVendorID == 0 && c.selectedProductID == 0)
                    ? "AUTO" : "\(c.selectedVendorID):\(c.selectedProductID)"
            },
            set: { key in
                let parts = key.split(separator: ":").compactMap { Int($0) }
                if parts.count == 2 {
                    appModel.config.selectedVendorID = parts[0]
                    appModel.config.selectedProductID = parts[1]
                } else {
                    appModel.config.selectedVendorID = 0
                    appModel.config.selectedProductID = 0
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PermissionsCard()

                if let error = appModel.calibrationError {
                    BannerView(text: error, icon: "exclamationmark.triangle.fill", color: .red)
                } else if let message = appModel.calibrationMessage {
                    BannerView(text: message, icon: "checkmark.circle.fill", color: .green)
                }

                if !appModel.unseizedTouchDevices.isEmpty && appModel.config.seizeTouchDevices {
                    BannerView(
                        text: "macOS still owns \(appModel.unseizedTouchDevices.map(\.product).joined(separator: ", ")) — it will keep moving the cursor from the panel's own reports, fighting this driver. Try “Re-open HID Manager”; if it persists, another driver holds the device.",
                        icon: "exclamationmark.triangle.fill", color: .orange)
                }

                if let issue = appModel.lastParseIssue {
                    BannerView(text: "Packets are arriving but not parsing: \(issue). Adjust the byte offsets in Report Format.",
                               icon: "questionmark.circle.fill", color: .orange)
                }

                if let notice = appModel.outputModeNotice {
                    BannerView(text: notice, icon: "info.circle.fill", color: .blue)
                }

                if appModel.isFallingBackFromVirtualHID {
                    BannerView(
                        text: "Virtual Multi-Touch is selected but the virtual HID device could not be created, even though the entitlement is present. Events are going out as mouse emulation instead.",
                        icon: "exclamationmark.triangle.fill", color: .orange)
                }

                if appModel.config.outputMode == .debugOnly {
                    BannerView(text: "Output is set to Debug / Log Only — no cursor events are injected. Switch the output mode in the header once calibration looks right.",
                               icon: "info.circle.fill", color: .blue)
                }

                MultiTouchCard()

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    StatusCard(title: "Connected Devices", value: "\(appModel.connectedDevices.count)", icon: "cable.connector", color: .blue)
                    StatusCard(title: "Current Raw Point",
                               value: String(format: "(%.0f, %.0f)", appModel.currentRawPoint.x, appModel.currentRawPoint.y),
                               icon: "scope", color: .purple)
                    StatusCard(title: "Touch State", value: appModel.lastTouchState,
                               icon: "hand.point.up.fill",
                               color: appModel.lastTouchState == "TOUCH DOWN" ? .green : .gray)
                }

                // Which device actually drives the cursor
                SectionBox(title: "Driver Input Device") {
                    Picker("", selection: driverDeviceSelection) {
                        Text("Auto-detect (all touch-classified devices)").tag("AUTO")
                        ForEach(uniqueProducts) { dev in
                            Text("\(dev.product) — \(dev.shortLabel)").tag("\(dev.vendorID):\(dev.productID)")
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    Text("Auto-detect treats anything that is not a keyboard, media device or known mouse as a touch panel. Pin a specific device if that misfires.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SectionBox(title: "Detected USB Devices") {
                    if appModel.connectedDevices.isEmpty {
                        Text("No USB HID devices detected. Grant Input Monitoring permission in System Settings > Privacy & Security if this stays empty.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else {
                        ForEach(appModel.connectedDevices) { dev in
                            HStack {
                                Image(systemName: dev.isDigitizer ? "hand.tap" : "cpu")
                                    .font(.title2)
                                    .foregroundStyle(appModel.config.matches(device: dev) ? .blue : .secondary)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dev.product).bold()
                                    Text("\(dev.manufacturer) | \(dev.shortLabel)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if appModel.config.matches(device: dev) {
                                    Text("DRIVING")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Capsule().fill(.blue.opacity(0.18)))
                                }
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
                        }
                    }
                }

                SectionBox(title: "Calibration") {
                    let display = appModel.availableDisplays.first { $0.id == appModel.config.targetDisplayID }
                        ?? appModel.availableDisplays.first

                    HStack {
                        Image(systemName: "display").font(.title2).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(display?.name ?? "No display").bold()
                            if let d = display {
                                Text(String(format: "Global origin (%.0f, %.0f) · %.0f x %.0f", d.originX, d.originY, d.width, d.height))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Divider().padding(.vertical, 4)

                    let m = appModel.config.affineMatrix
                    Text(String(format: "X = %.5f · rx + %.5f · ry + %.1f", m.a, m.b, m.c))
                        .font(.system(.body, design: .monospaced))
                    Text(String(format: "Y = %.5f · rx + %.5f · ry + %.1f", m.d, m.e, m.f))
                        .font(.system(.body, design: .monospaced))

                    if appModel.config.calibrationPoints.isEmpty {
                        Text("Not calibrated yet — the identity matrix maps raw sensor values straight to screen pixels.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        let err = appModel.calibrationErrorPixels
                        Text(String(format: "%d reference points · mean residual %.1f px",
                                    appModel.config.calibrationPoints.count, err))
                            .font(.caption)
                            .foregroundStyle(err < 10 ? Color.secondary : Color.orange)
                    }
                }
            }
            .padding()
        }
    }
}

/// macOS ties Input Monitoring and Accessibility to the binary's code
/// signature. An ad-hoc signed build gets a new signature on every rebuild, at
/// which point a previously granted permission stops applying — and the only
/// visible symptom is a driver that quietly receives nothing. Show the state.
struct PermissionsCard: View {
    @EnvironmentObject var appModel: AppViewModel

    private var needsAttention: Bool {
        appModel.inputMonitoring != .granted
            || (appModel.needsAccessibility && !appModel.hasAccessibility)
    }

    var body: some View {
        SectionBox(title: "Permissions") {
            HStack(spacing: 20) {
                PermissionRow(
                    name: "Input Monitoring",
                    detail: "Required to receive touch reports",
                    state: appModel.inputMonitoring == .granted ? .ok : .missing,
                    stateText: appModel.inputMonitoring.label
                )
                PermissionRow(
                    name: "Accessibility",
                    detail: "Required to move the cursor",
                    state: appModel.hasAccessibility ? .ok
                        : (appModel.needsAccessibility ? .missing : .optional),
                    stateText: appModel.hasAccessibility ? "granted" : "not granted"
                )
            }

            if needsAttention {
                HStack {
                    if appModel.inputMonitoring != .granted {
                        Button("Grant Input Monitoring…") { appModel.requestInputMonitoring() }
                            .buttonStyle(.borderedProminent)
                    }
                    if appModel.needsAccessibility && !appModel.hasAccessibility {
                        Button("Grant Accessibility…") { appModel.requestAccessibility() }
                    }
                    Button("Re-open HID Manager") { appModel.restartMonitoring() }
                        .help("Reconnect after granting a permission, without restarting the app")
                }
            }

            if appModel.inputMonitoring == .granted && !appModel.hasReceivedReport {
                Text("Permission is granted but no report has arrived yet. Touch the panel — if nothing appears, use “Re-open HID Manager”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 2)

            let signature = appModel.signature
            Text("Code signature: \(signature.summary)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(signature.isAdHoc
                 ? "Permissions are bound to this signature. This build is ad-hoc signed, so it gets a new signature on every rebuild and a previously granted permission stops applying — it has to be re-granted each time."
                 : "Permissions are bound to the signing certificate rather than the binary hash, so they survive rebuilds. If a permission stops working, the certificate changed.")
                .font(.caption)
                .foregroundStyle(signature.isAdHoc ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PermissionRow: View {
    enum State { case ok, missing, optional }

    let name: String
    let detail: String
    let state: State
    let stateText: String

    private var color: Color {
        switch state {
        case .ok: return .green
        case .missing: return .red
        case .optional: return .secondary
        }
    }

    private var icon: String {
        switch state {
        case .ok: return "checkmark.circle.fill"
        case .missing: return "xmark.circle.fill"
        case .optional: return "minus.circle"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(name) — \(stateText)").bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Start-at-login switch.
///
/// The state lives in `SMAppService`, not in the config file, so it is read back
/// from the system rather than stored: a user who turns the entry off under
/// System Settings › General › Login Items must not find this still claiming to
/// be on.
struct LoginItemToggle: View {
    @State private var isOn = LoginItem.isEnabled
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Open at login", isOn: Binding(
                get: { isOn },
                set: { newValue in
                    do {
                        try LoginItem.set(newValue)
                        failure = nil
                    } catch {
                        failure = error.localizedDescription
                    }
                    // Re-read rather than trust the write: registration can be
                    // refused, and the switch must show what is actually set.
                    isOn = LoginItem.isEnabled
                }
            ))

            Text("HIDTouch runs in the menu bar with no Dock icon. Closing this window leaves the driver running; quit it from the menu bar item.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let failure = failure {
                Text(failure)
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { isOn = LoginItem.isEnabled }
    }
}

/// Multi-touch status: whether the panel was switched out of mouse emulation,
/// what its report descriptor says it can do, and what is on it right now.
struct MultiTouchCard: View {
    @EnvironmentObject var appModel: AppViewModel

    private var gestureLabel: String {
        switch appModel.lastGesture {
        case .pointer: return "pointer"
        case .scroll(let dx, let dy): return String(format: "scroll (%.0f, %.0f)", dx, dy)
        case .magnify(let delta): return String(format: "pinch %+.3f", delta)
        case .none: return appModel.contacts.isEmpty ? "idle" : "tracking"
        }
    }

    var body: some View {
        SectionBox(title: "Multi-Touch") {
            if let layout = appModel.multiTouchLayout {
                HStack(spacing: 10) {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.title2)
                        .foregroundStyle(appModel.config.multiTouchEnabled ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Up to \(layout.maxContacts) contacts · report 0x\(String(format: "%02X", layout.reportID)) · \(layout.reportLengthBytes) bytes")
                            .bold()
                        Text("Layout derived from the panel's own report descriptor. Raw range X 0–\(layout.logicalMaxX), Y 0–\(layout.logicalMaxY).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text("\(appModel.contacts.count) down")
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(appModel.contacts.isEmpty ? Color.gray.opacity(0.2) : Color.green.opacity(0.2)))
                }

                ContactStrip(contacts: appModel.contacts, maxContacts: layout.maxContacts)

                Text("Gesture: \(gestureLabel) — one finger moves the cursor, two fingers scroll, three or more are tracked but not mapped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "hand.point.up.left")
                        .font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No multi-touch collection detected").bold()
                        Text("The panel exposes no digitizer report descriptor with per-finger contacts, so only single-contact input is available.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// Colour per contact id, shared between the dashboard strip and the canvas so
/// the same finger reads as the same colour in both places.
enum TouchPalette {
    static let colours: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .yellow, .red, .mint, .indigo]
    static func colour(for id: Int) -> Color { colours[abs(id) % colours.count] }
}

/// One slot per supported contact, lit when that finger is down.
private struct ContactStrip: View {
    let contacts: [MappedContact]
    let maxContacts: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<maxContacts, id: \.self) { slot in
                let contact = contacts.first { $0.id == slot } ?? (slot < contacts.count ? contacts[slot] : nil)
                Circle()
                    .fill(contact != nil ? TouchPalette.colour(for: slot) : Color.secondary.opacity(0.15))
                    .frame(width: 16, height: 16)
                    .overlay(
                        Text("\(slot)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(contact != nil ? .white : .secondary)
                    )
            }
            Spacer(minLength: 0)
        }
    }
}

struct BannerView: View {
    let text: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }
}

struct StatusCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(Circle().fill(color.opacity(0.15)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title3.bold())
            }
            Spacer()
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
    }
}

// MARK: - Inspect

struct InspectView: View {
    @EnvironmentObject var appModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("USB HID Raw Packet Hex Stream").font(.headline)

                Spacer()

                Picker("", selection: $appModel.selectedDeviceFilterID) {
                    Text("Auto (Touch Devices Only)").tag("AUTO_TOUCH")
                    Text("All Devices (No Filter)").tag("ALL")
                    Divider()
                    ForEach(appModel.connectedDevices) { dev in
                        Text("\(dev.product) — \(dev.shortLabel)").tag(dev.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 280)

                Toggle("Pause", isOn: $appModel.isInspectPaused)
                    .toggleStyle(.button)

                Button("Clear") { appModel.inspectLogs.removeAll() }
            }

            Text("Count the bytes to find X, Y and the touch-state bit, then enter the offsets in the Report Format tab.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if appModel.inspectLogs.isEmpty {
                            Text("No HID packets matching the filter.")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.gray)
                        } else {
                            ForEach(Array(appModel.inspectLogs.enumerated()), id: \.offset) { idx, log in
                                Text(log)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.green)
                                    .textSelection(.enabled)
                                    .id(idx)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.black.opacity(0.9).cornerRadius(10))
                .onChange(of: appModel.inspectLogs.count) { _ in
                    guard !appModel.isInspectPaused, let last = appModel.inspectLogs.indices.last else { return }
                    proxy.scrollTo(last)
                }
            }
        }
    }
}

// MARK: - Report format & tuning

struct SettingsView: View {
    @EnvironmentObject var appModel: AppViewModel

    private var reportIDEnabled: Binding<Bool> {
        Binding(
            get: { appModel.config.reportFormat.reportID != nil },
            set: { on in
                appModel.config.reportFormat.reportID = on ? (appModel.config.reportFormat.reportID ?? 1) : nil
            }
        )
    }

    private var reportIDValue: Binding<Int> {
        Binding(
            get: { Int(appModel.config.reportFormat.reportID ?? 1) },
            set: { appModel.config.reportFormat.reportID = UInt8(clamping: $0) }
        )
    }

    private var bitMaskHex: Binding<String> {
        Binding(
            get: { String(format: "%02X", appModel.config.reportFormat.touchStateBitMask) },
            set: { text in
                let cleaned = text.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: "0X", with: "")
                if let value = UInt8(cleaned, radix: 16) {
                    appModel.config.reportFormat.touchStateBitMask = value
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionBox(title: "General") {
                    LoginItemToggle()
                }

                SectionBox(title: "HID Report Layout") {
                    Text("Offsets index into the packet exactly as shown in HID Inspect. Changes apply immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                        GridRow {
                            Text("X byte offset")
                            Stepper(value: appModel.binding(\.reportFormat.xByteOffset), in: 0...63) {
                                Text("\(appModel.config.reportFormat.xByteOffset)")
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                        GridRow {
                            Text("Y byte offset")
                            Stepper(value: appModel.binding(\.reportFormat.yByteOffset), in: 0...63) {
                                Text("\(appModel.config.reportFormat.yByteOffset)")
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                        GridRow {
                            Text("Byte order")
                            Picker("", selection: appModel.binding(\.reportFormat.isLittleEndian)) {
                                Text("Little endian").tag(true)
                                Text("Big endian").tag(false)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                        }
                        GridRow {
                            Text("Touch-state byte")
                            Stepper(value: appModel.binding(\.reportFormat.touchStateByteOffset), in: 0...63) {
                                Text("\(appModel.config.reportFormat.touchStateByteOffset)")
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                        GridRow {
                            Text("Touch-state bit mask")
                            HStack(spacing: 4) {
                                Text("0x")
                                TextField("01", text: bitMaskHex)
                                    .frame(width: 60)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                        GridRow {
                            Text("Report ID filter")
                            HStack(spacing: 8) {
                                Toggle("Only accept ID", isOn: reportIDEnabled)
                                TextField("", value: reportIDValue, format: .number)
                                    .frame(width: 60)
                                    .disabled(!reportIDEnabled.wrappedValue)
                            }
                        }
                        GridRow {
                            Text("Raw max X / Y")
                            HStack(spacing: 8) {
                                TextField("", value: appModel.binding(\.reportFormat.rawMaxX), format: .number)
                                    .frame(width: 90)
                                TextField("", value: appModel.binding(\.reportFormat.rawMaxY), format: .number)
                                    .frame(width: 90)
                                Text("validity gate — larger samples are discarded")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                SectionBox(title: "Jitter Filter") {
                    HStack {
                        Text("Smoothing").frame(width: 120, alignment: .leading)
                        Slider(value: appModel.binding(\.smoothingFactor), in: 0.01...1.0)
                        Text(String(format: "%.2f", appModel.config.smoothingFactor))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 50)
                    }
                    Text("Lower is smoother but laggier; 1.0 disables smoothing.")
                        .font(.caption).foregroundStyle(.secondary)

                    HStack {
                        Text("Deadband (px)").frame(width: 120, alignment: .leading)
                        Slider(value: appModel.binding(\.deadbandPixels), in: 0...20)
                        Text(String(format: "%.1f", appModel.config.deadbandPixels))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 50)
                    }
                    Text("Movements below this distance are ignored.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                SectionBox(title: "Multi-Touch & Gestures") {
                    Toggle("Enable multi-touch", isOn: appModel.binding(\.multiTouchEnabled))
                    Text("Writes the Device Configuration feature report that takes Win8-style panels out of single-contact mouse emulation. Takes effect after “Re-open HID Manager” or a restart.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().padding(.vertical, 4)

                    Text("macOS has no public API for injecting real multi-touch. Two-finger panning is delivered as a scroll wheel event, which is public API and behaves correctly everywhere. Pinch uses undocumented CGEvent fields — see below. Rotation is tracked but not forwarded.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !TouchOutputMode.virtualHID.isAvailable {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            Text("“\(TouchOutputMode.virtualHID.rawValue)” is not offered as an output mode: creating an IOHIDUserDevice needs the restricted com.apple.developer.hid.virtual.device entitlement, which Apple grants per developer team and which must be embedded via a provisioning profile. It would silently behave as mouse emulation, so it is hidden rather than shown as a choice that does nothing. It reappears automatically once a build carries the entitlement.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack {
                        Text("Scroll speed").frame(width: 150, alignment: .leading)
                        Slider(value: appModel.binding(\.scrollSensitivity), in: 0.1...4.0)
                        Text(String(format: "%.2f", appModel.config.scrollSensitivity))
                            .font(.system(.body, design: .monospaced)).frame(width: 50)
                    }

                    HStack {
                        Text("Start threshold (px)").frame(width: 150, alignment: .leading)
                        Slider(value: appModel.binding(\.scrollActivationPixels), in: 0...30)
                        Text(String(format: "%.0f", appModel.config.scrollActivationPixels))
                            .font(.system(.body, design: .monospaced)).frame(width: 50)
                    }
                    Text("How far two fingers must travel together before scrolling begins, so a two-finger tap does not nudge the view.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Natural scrolling (content follows fingers)", isOn: appModel.binding(\.naturalScrolling))

                    Divider().padding(.vertical, 4)

                    Toggle("Pinch to zoom", isOn: appModel.binding(\.pinchEnabled))
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                        Text("Off by default. There is no public API for synthesising a pinch, so this posts a CGEvent whose type and fields are undocumented. It works today, but Apple guarantees nothing across macOS releases and a change would break it silently. Everything else in this app uses public API only.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Text("Pinch speed").frame(width: 150, alignment: .leading)
                        Slider(value: appModel.binding(\.pinchSensitivity), in: 0.1...4.0)
                        Text(String(format: "%.2f", appModel.config.pinchSensitivity))
                            .font(.system(.body, design: .monospaced)).frame(width: 50)
                    }
                    .disabled(!appModel.config.pinchEnabled)

                    HStack {
                        Text("Pinch threshold (px)").frame(width: 150, alignment: .leading)
                        Slider(value: appModel.binding(\.pinchActivationPixels), in: 2...60)
                        Text(String(format: "%.0f", appModel.config.pinchActivationPixels))
                            .font(.system(.body, design: .monospaced)).frame(width: 50)
                    }
                    .disabled(!appModel.config.pinchEnabled)
                    Text("How much the gap between two fingers must change before the gesture counts as a pinch instead of a pan. Raise it if scrolling turns into zooming; lower it if pinching is hard to start.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SectionBox(title: "Device Handling") {
                    Toggle("Take exclusive ownership of touch devices (seize)", isOn: appModel.binding(\.seizeTouchDevices))
                    Text("Stops the built-in macOS driver from also moving the cursor from the same reports. Only ever applied to devices classified as touch panels — never to keyboards or mice. Turn it off if a device stops responding.")
                        .font(.caption).foregroundStyle(.secondary)

                    Divider().padding(.vertical, 4)

                    Text("Config file: \(ConfigManager.shared.fileURL.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
    }
}

// MARK: - Test canvas

struct TestCanvasView: View {
    @EnvironmentObject var appModel: AppViewModel
    /// Strokes stored normalized (0...1) against the target display so the
    /// drawing survives window resizing. Keyed by contact id so each finger
    /// draws its own line instead of all of them being joined together.
    @State private var strokes: [Int: [[CGPoint]]] = [:]
    @State private var activeContacts: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Touch Test — scaled map of the target display").font(.headline)
                Spacer()
                Button("Clear Canvas") { strokes.removeAll() }
                    .help("Each finger draws in its own colour")
            }

            Text("Drag on the panel. This canvas is a miniature of the target display, so a stroke drawn in a corner of the panel should appear in the same corner here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(NSColor.controlBackgroundColor))

                    Canvas { context, canvasSize in
                        for (id, lines) in strokes {
                            let colour = TouchPalette.colour(for: id)
                            for stroke in lines where stroke.count > 1 {
                                var path = Path()
                                path.move(to: denormalize(stroke[0], in: canvasSize))
                                for pt in stroke.dropFirst() {
                                    path.addLine(to: denormalize(pt, in: canvasSize))
                                }
                                context.stroke(path, with: .color(colour), lineWidth: 3)
                            }
                        }

                        for contact in normalizedContacts {
                            let p = denormalize(contact.point, in: canvasSize)
                            let radius: CGFloat = 14
                            let circle = Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius,
                                                               width: radius * 2, height: radius * 2))
                            context.fill(circle, with: .color(TouchPalette.colour(for: contact.id).opacity(0.85)))
                            context.draw(Text("\(contact.id)").font(.caption2.bold()).foregroundColor(.white),
                                         at: p)
                        }
                    }

                    if strokes.isEmpty {
                        Text("Touch or drag on the panel — each finger draws in its own colour")
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .onChange(of: appModel.contacts) { _ in appendSample() }
        }
    }

    /// Every contact expressed as a 0...1 fraction of the target display.
    private var normalizedContacts: [(id: Int, point: CGPoint)] {
        guard let bounds = targetBounds else { return [] }
        return appModel.contacts.map { contact in
            (contact.id, CGPoint(x: (contact.screen.x - bounds.origin.x) / bounds.width,
                                 y: (contact.screen.y - bounds.origin.y) / bounds.height))
        }
    }

    private var targetBounds: CGRect? {
        let bounds = (appModel.availableDisplays.first { $0.id == appModel.config.targetDisplayID }
                      ?? appModel.availableDisplays.first)?.bounds
        guard let bounds = bounds, bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }

    /// Current point expressed as a 0...1 fraction of the target display.
    private var normalizedCursor: CGPoint? {
        let bounds = (appModel.availableDisplays.first { $0.id == appModel.config.targetDisplayID }
                      ?? appModel.availableDisplays.first)?.bounds
        guard let bounds = bounds, bounds.width > 0, bounds.height > 0 else { return nil }
        let p = appModel.currentScreenPoint
        guard p != .zero else { return nil }
        return CGPoint(x: (p.x - bounds.origin.x) / bounds.width,
                       y: (p.y - bounds.origin.y) / bounds.height)
    }

    private func denormalize(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private func appendSample() {
        let current = normalizedContacts
        let currentIDs = Set(current.map(\.id))

        for contact in current {
            // A finger that was not down on the previous frame starts a new
            // stroke; otherwise the line would jump from wherever it last was.
            if !activeContacts.contains(contact.id) || strokes[contact.id]?.isEmpty != false {
                strokes[contact.id, default: []].append([contact.point])
            } else {
                strokes[contact.id]![strokes[contact.id]!.count - 1].append(contact.point)
            }
            // Bound the history so a long session cannot grow without limit.
            if var lines = strokes[contact.id], lines.count > 32 {
                lines.removeFirst(lines.count - 32)
                strokes[contact.id] = lines
            }
        }

        activeContacts = currentIDs
    }
}

// MARK: - Calibration overlay

/// Rendered inside a borderless window that covers exactly the target display,
/// so a crosshair at (width * ratio.x, height * ratio.y) is at the same global
/// coordinate the view model records for that step.
struct CalibrationOverlayView: View {
    @EnvironmentObject var appModel: AppViewModel

    var body: some View {
        GeometryReader { geo in
            let step = min(appModel.calibrationStep, appModel.targetScreenRatios.count - 1)
            let ratio = appModel.targetScreenRatios[step]

            ZStack {
                Color.black.opacity(0.88).ignoresSafeArea()

                VStack(spacing: 10) {
                    Text("TOUCH CALIBRATION (\(min(appModel.calibrationStep + 1, appModel.targetScreenRatios.count)) / \(appModel.targetScreenRatios.count))")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Firmly touch the centre of the crosshair, then lift your finger")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.75))

                    Text(String(format: "Raw: (%.0f, %.0f) · %@",
                                appModel.currentRawPoint.x, appModel.currentRawPoint.y, appModel.lastTouchState))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))

                    if let issue = appModel.lastParseIssue {
                        Text(issue)
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                .position(x: geo.size.width / 2, y: 90)

                ZStack {
                    Circle().stroke(Color.red, lineWidth: 3).frame(width: 50, height: 50)
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Rectangle().fill(Color.red).frame(width: 60, height: 2)
                    Rectangle().fill(Color.red).frame(width: 2, height: 60)
                }
                .position(x: geo.size.width * ratio.x, y: geo.size.height * ratio.y)

                VStack(spacing: 6) {
                    Button("Cancel Calibration (esc)") { appModel.cancelCalibration() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
                .position(x: geo.size.width / 2, y: geo.size.height - 60)
            }
        }
        .onExitCommand { appModel.cancelCalibration() }
    }
}
