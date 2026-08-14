import AppKit
import ApplicationServices

/// Private but long-stable accessor mapping an AX window element to its
/// CGWindowID (the same ID CGWindowList reports). Used by every window
/// manager (Rectangle, yabai, …); the public API has no equivalent.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
    _ element: AXUIElement, _ out: UnsafeMutablePointer<CGWindowID>
) -> AXError

/// Raises the target window, warps the cursor to the gaze point, and (for
/// configured apps such as Ghostty) synthesizes a single click so that the
/// correct split/pane receives keyboard focus.
final class FocusController {
    var clickBundleIDs: Set<String>
    /// One-line outcome of each jump, for diagnostics.
    var onReport: ((String) -> Void)?

    init(clickBundleIDs: [String]) {
        self.clickBundleIDs = Set(clickBundleIDs)
    }

    func jump(to target: TargetWindow, gaze: CGPoint) {
        // Keep the click point inside the window even if the gaze estimate
        // sits right on the border.
        let point = CGPoint(
            x: min(max(gaze.x, target.bounds.minX + 4), target.bounds.maxX - 4),
            y: min(max(gaze.y, target.bounds.minY + 4), target.bounds.maxY - 4)
        )

        let app = NSRunningApplication(processIdentifier: target.pid)
        app?.activate()
        let raiseOutcome = raiseWindow(target: target)
        let shouldClick = clickBundleIDs.contains(app?.bundleIdentifier ?? "")

        // Warp early so the jump feels immediate; the click waits for proof.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Self.moveCursor(to: point)
        }
        confirmFrontmost(
            target: target, point: point, shouldClick: shouldClick,
            raiseOutcome: raiseOutcome, attempt: 0
        )
    }

    /// The click must not fire until the target really is the window under
    /// the click point — a fixed delay races app activation, and a click that
    /// lands before the raise completes goes to whatever was frontmost before
    /// the jump.
    private func confirmFrontmost(
        target: TargetWindow, point: CGPoint, shouldClick: Bool,
        raiseOutcome: String, attempt: Int
    ) {
        let top = WindowTargeting.window(at: point)
        if top?.windowID == target.windowID {
            Self.moveCursor(to: point)
            if shouldClick { Self.click(at: point) }
            let clickNote = shouldClick ? "; clicked" : ""
            onReport?("\(target.ownerName): \(raiseOutcome); frontmost after \(attempt * 50)ms\(clickNote)")
            return
        }
        if attempt < 9 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.confirmFrontmost(
                    target: target, point: point, shouldClick: shouldClick,
                    raiseOutcome: raiseOutcome, attempt: attempt + 1
                )
            }
            return
        }
        let topName = top.map { "\($0.ownerName) #\($0.windowID)" } ?? "none"
        onReport?("\(target.ownerName): \(raiseOutcome); NEVER frontmost (top: \(topName)) — click skipped")
    }

    private func raiseWindow(target: TargetWindow) -> String {
        let appElement = AXUIElementCreateApplication(target.pid)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let windows = value as? [AXUIElement] else {
            return "AX window list failed (err \(err.rawValue))"
        }

        // Exact match by window ID.
        for window in windows {
            var windowID: CGWindowID = 0
            if _AXUIElementGetWindow(window, &windowID) == .success, windowID == target.windowID {
                raise(window)
                return "raised by id"
            }
        }

        // Fallback: the window whose frame is nearest the target's bounds.
        var best: (window: AXUIElement, delta: CGFloat)?
        for window in windows {
            guard let position = axPoint(window, kAXPositionAttribute),
                  let size = axSize(window, kAXSizeAttribute)
            else { continue }
            let delta = max(
                abs(position.x - target.bounds.minX),
                abs(position.y - target.bounds.minY),
                abs(size.width - target.bounds.width),
                abs(size.height - target.bounds.height)
            )
            if best == nil || delta < best!.delta {
                best = (window, delta)
            }
        }
        if let best, best.delta < 40 {
            raise(best.window)
            return String(format: "raised by frame (Δ%.0fpx)", best.delta)
        }
        return "no AX match among \(windows.count) windows"
    }

    private func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    private func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(ref as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    static func moveCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // Also post a move event so apps tracking the cursor stay in sync.
        CGEvent(
            mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    static func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(
            mouseEventSource: source, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left
        )
        down?.setIntegerValueField(.mouseEventClickState, value: 1)
        down?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            let up = CGEvent(
                mouseEventSource: source, mouseType: .leftMouseUp,
                mouseCursorPosition: point, mouseButton: .left
            )
            up?.setIntegerValueField(.mouseEventClickState, value: 1)
            up?.post(tap: .cghidEventTap)
        }
    }
}
