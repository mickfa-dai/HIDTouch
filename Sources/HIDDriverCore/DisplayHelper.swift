import Foundation
import CoreGraphics
import AppKit

public struct DisplayInfo: Identifiable, Codable, Equatable, Hashable {
    public var id: UInt32
    public var name: String
    public var originX: Double
    public var originY: Double
    public var width: Double
    public var height: Double

    /// Global CoreGraphics bounds (top-left origin, y-down) — the coordinate
    /// space used by CGEvent / CGWarpMouseCursorPosition.
    public var bounds: CGRect {
        CGRect(x: originX, y: originY, width: width, height: height)
    }

    public init(id: UInt32, name: String, bounds: CGRect) {
        self.id = id
        self.name = name
        self.originX = bounds.origin.x
        self.originY = bounds.origin.y
        self.width = bounds.size.width
        self.height = bounds.size.height
    }
}

public class DisplayHelper {
    private static let lock = NSLock()
    private static var cache: [DisplayInfo]?
    private static var observerInstalled = false

    /// Active displays. The result is cached and invalidated automatically when
    /// the display configuration changes — this is called on the per-packet hot
    /// path, so re-enumerating every time would be wasteful.
    public static func getAllDisplays() -> [DisplayInfo] {
        lock.lock()
        installReconfigurationObserverLocked()
        if let cached = cache {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let list = enumerateDisplays()

        lock.lock()
        cache = list
        lock.unlock()
        return list
    }

    public static func invalidateCache() {
        lock.lock()
        cache = nil
        lock.unlock()
    }

    /// Resolve the configured target display, falling back to the first active
    /// display and finally to the main display.
    public static func display(withID id: UInt32?) -> DisplayInfo {
        let displays = getAllDisplays()
        if let id = id, let match = displays.first(where: { $0.id == id }) {
            return match
        }
        if let first = displays.first {
            return first
        }
        let main = CGMainDisplayID()
        return DisplayInfo(id: main, name: "Main Display", bounds: CGDisplayBounds(main))
    }

    /// Convert a global CoreGraphics rect (top-left origin, y-down) into the
    /// AppKit screen coordinate space (bottom-left origin, y-up) used by NSWindow.
    public static func nsFrame(forCGRect rect: CGRect) -> CGRect {
        // The primary screen is the one whose AppKit origin is (0, 0); both
        // coordinate systems share that screen's top-left corner as reference.
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
                ?? NSScreen.screens.first else {
            return rect
        }
        let flippedY = primary.frame.height - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
    }

    private static func installReconfigurationObserverLocked() {
        guard !observerInstalled else { return }
        observerInstalled = true
        CGDisplayRegisterReconfigurationCallback({ _, _, _ in
            DisplayHelper.invalidateCache()
        }, nil)
    }

    private static func enumerateDisplays() -> [DisplayInfo] {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return [] }

        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &activeDisplays, &displayCount)
        activeDisplays = Array(activeDisplays.prefix(Int(displayCount)))

        // NSScreen is only safe to touch from the main thread; when called from a
        // background thread we fall back to generated names.
        let screens = Thread.isMainThread ? NSScreen.screens : []

        var list: [DisplayInfo] = []
        for (idx, displayID) in activeDisplays.enumerated() {
            let bounds = CGDisplayBounds(displayID)
            let isMain = CGDisplayIsMain(displayID) != 0
            let size = "\(Int(bounds.width))x\(Int(bounds.height))"

            var name = isMain ? "Main Display (\(size))" : "Display #\(idx + 1) (\(size))"

            for screen in screens {
                if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                   screenNumber == displayID {
                    name = "\(screen.localizedName) (\(size))"
                    break
                }
            }

            list.append(DisplayInfo(id: displayID, name: name, bounds: bounds))
        }
        return list
    }
}
