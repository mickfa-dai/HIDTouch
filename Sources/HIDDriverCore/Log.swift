import Foundation
import os

/// Diagnostics for a driver need to be readable no matter how the process was
/// started. A GUI app's `print` output goes to a fully-buffered stdout that
/// nothing ever drains, so the messages that matter most — why a device could
/// not be seized, why no reports arrive — are exactly the ones you cannot see.
///
/// Everything goes through `os.Logger`, readable live with:
///
///     log stream --predicate 'subsystem == "com.reo.hidtouch"' --style compact
///
/// and still echoes to stdout so the CLI daemon stays usable in a terminal.
public enum Log {
    public static let subsystem = "com.reo.hidtouch"

    /// Per-event tracing, off unless `HIDTOUCH_EVENT_TRACE=1` is set.
    ///
    /// Comparing what the driver posted against what it received is the only
    /// way some of these faults become visible, but it logs on every click and
    /// the receiving half observes other applications' events — not something
    /// to leave running.
    public static let isEventTraceEnabled: Bool =
        ProcessInfo.processInfo.environment["HIDTOUCH_EVENT_TRACE"] == "1"

    public static func event(_ message: @autoclosure () -> String) {
        guard isEventTraceEnabled else { return }
        driverInfo(message())
    }

    private static let hid = Logger(subsystem: subsystem, category: "hid")
    private static let driver = Logger(subsystem: subsystem, category: "driver")

    public static func hidInfo(_ message: String) {
        hid.info("\(message, privacy: .public)")
        echo(message)
    }

    public static func hidError(_ message: String) {
        hid.error("\(message, privacy: .public)")
        echo(message)
    }

    public static func driverInfo(_ message: String) {
        driver.info("\(message, privacy: .public)")
        echo(message)
    }

    public static func driverError(_ message: String) {
        driver.error("\(message, privacy: .public)")
        echo(message)
    }

    /// IOKit returns are far easier to recognise in hex than in decimal.
    public static func kr(_ value: Int32) -> String {
        switch value {
        case 0: return "success"
        case Int32(bitPattern: 0xE00002C5): return "kIOReturnExclusiveAccess (0xE00002C5)"
        case Int32(bitPattern: 0xE00002E2): return "kIOReturnNotPermitted (0xE00002E2)"
        case Int32(bitPattern: 0xE00002BC): return "kIOReturnNotOpen (0xE00002BC)"
        case Int32(bitPattern: 0xE00002C2): return "kIOReturnBadArgument (0xE00002C2)"
        default: return String(format: "0x%08X", value)
        }
    }

    private static func echo(_ message: String) {
        print(message)
        fflush(stdout)
    }
}
