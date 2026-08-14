import Foundation
import CoreGraphics

struct TargetWindow: Equatable {
    let windowID: CGWindowID
    let pid: pid_t
    /// Global CG coordinates.
    let bounds: CGRect
    let ownerName: String
}

enum WindowTargeting {
    /// Topmost normal window under the point. CGWindowList returns windows
    /// front-to-back, so the first hit is the visible one.
    static func window(at point: CGPoint) -> TargetWindow? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let ownPID = getpid()
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 40, bounds.height > 40,
                  bounds.contains(point)
            else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 {
                continue
            }
            let windowID = (info[kCGWindowNumber as String] as? CGWindowID) ?? 0
            let ownerName = (info[kCGWindowOwnerName as String] as? String) ?? "?"
            return TargetWindow(windowID: windowID, pid: pid, bounds: bounds, ownerName: ownerName)
        }
        return nil
    }
}
