import Foundation
import IOKit
import IOKit.hid
import ApplicationServices
import AppKit

public enum PermissionState: Equatable {
    case granted
    case denied
    case unknown

    public var label: String {
        switch self {
        case .granted: return "granted"
        case .denied: return "denied"
        case .unknown: return "not yet requested"
        }
    }
}

/// macOS gates raw HID reports behind Input Monitoring and synthetic cursor
/// events behind Accessibility. Both are keyed to the binary's *code
/// signature*, not its path, so this is worth surfacing in the UI rather than
/// leaving the user to infer it from a driver that silently does nothing.
public enum Permissions {

    /// Required to receive input reports. Without it the device list still
    /// populates, which makes the failure look like a parsing problem.
    public static var inputMonitoring: PermissionState {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }

    /// Required to post cursor events in `mouseEmulation` mode.
    public static var accessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt the first time; afterwards macOS stays silent and
    /// the user has to toggle it in System Settings.
    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    @discardableResult
    public static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    public static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    public struct SignatureInfo {
        /// Code directory hash of the running binary.
        public var cdHash: String
        /// True when there is no certificate chain, i.e. an ad-hoc signature.
        ///
        /// This matters because an ad-hoc signature's designated requirement is
        /// `cdhash H"…"`, which changes on every rebuild and silently
        /// invalidates permissions the user granted. A certificate-backed
        /// signature's requirement references the certificate instead and
        /// survives rebuilds.
        public var isAdHoc: Bool
        /// Name of the signing authority, when there is one.
        public var authority: String?

        public var summary: String {
            if let authority = authority { return "\(cdHash) — signed by \(authority)" }
            return "\(cdHash) — ad-hoc"
        }
    }

    /// The running binary's own static code object.
    private static func selfStaticCode() -> SecStaticCode? {
        var codeRef: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &codeRef) == errSecSuccess,
              let codeRef = codeRef else { return nil }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(codeRef, SecCSFlags(rawValue: 0), &staticRef) == errSecSuccess else { return nil }
        return staticRef
    }

    /// Entitlements actually embedded in this binary's signature.
    public static var entitlements: [String: Any] {
        guard let staticRef = selfStaticCode() else { return [:] }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(staticRef, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let granted = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
            return [:]
        }
        return granted
    }

    /// Whether this build may create an `IOHIDUserDevice`.
    ///
    /// Checking the entitlement is side-effect free, unlike probing by actually
    /// trying to create a virtual device — which would either fail or leave a
    /// phantom device attached while the user is in a mode that does not want one.
    public static var hasVirtualHIDEntitlement: Bool {
        entitlements["com.apple.developer.hid.virtual.device"] as? Bool == true
    }

    public static var signature: SignatureInfo {
        guard let staticRef = selfStaticCode() else {
            return SignatureInfo(cdHash: "unavailable", isAdHoc: true, authority: nil)
        }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticRef, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else {
            return SignatureInfo(cdHash: "unsigned", isAdHoc: true, authority: nil)
        }

        let hash = (dict[kSecCodeInfoUnique as String] as? Data)
            .map { $0.prefix(10).map { String(format: "%02x", $0) }.joined() } ?? "unsigned"

        // An ad-hoc signature carries no certificates.
        let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        var authority: String?
        if let leaf = certificates.first {
            authority = SecCertificateCopySubjectSummary(leaf) as String?
        }

        return SignatureInfo(cdHash: hash, isAdHoc: certificates.isEmpty, authority: authority)
    }

    public static var codeSignatureID: String { signature.cdHash }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
