import AppKit
import CoreGraphics

/// Finds the frontmost window under a given screen coordinate.
struct WindowDetector {

    struct WindowInfo {
        let windowID: CGWindowID
        let bounds: CGRect
        let ownerName: String
        let name: String?
    }

    /// Returns the topmost user-visible window at the given screen point,
    /// excluding the QuickSnap overlay windows.
    static func windowAt(point: CGPoint) -> WindowInfo? {
        let ownPID = ProcessInfo.processInfo.processIdentifier

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for entry in windowList {
            guard
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                pid != ownPID,
                let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                let layer = entry[kCGWindowLayer as String] as? Int,
                layer == 0 // Normal window layer
            else { continue }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            if bounds.contains(point) {
                let ownerName = entry[kCGWindowOwnerName as String] as? String ?? "Unknown"
                let name = entry[kCGWindowName as String] as? String
                return WindowInfo(windowID: windowID, bounds: bounds, ownerName: ownerName, name: name)
            }
        }

        return nil
    }
}
