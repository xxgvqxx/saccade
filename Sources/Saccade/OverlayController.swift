import AppKit

/// Transparent, click-through overlay windows — one per calibrated screen.
/// The target border and gaze dot draw on whichever screen currently holds
/// the gaze; the others stay clear.
final class OverlayController {
    private struct Entry {
        let window: NSWindow
        let view: OverlayView
        let cgFrame: CGRect
    }

    private var entries: [Entry] = []

    /// Frames of calibrated screens in global CG coordinates.
    func setup(cgFrames: [CGRect]) {
        for entry in entries { entry.window.orderOut(nil) }
        entries = []
        for cgFrame in cgFrames {
            guard let screen = Coordinates.screen(matchingCGFrame: cgFrame) else { continue }
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.contentView = view
            window.orderFrontRegardless()
            entries.append(Entry(window: window, view: view, cgFrame: Coordinates.cgFrame(of: screen)))
        }
    }

    func hide() {
        for entry in entries { entry.window.orderOut(nil) }
    }

    func show() {
        for entry in entries { entry.window.orderFrontRegardless() }
    }

    /// Both arguments in global CG coordinates.
    func update(gazePoint: CGPoint?, highlight: CGRect?) {
        for entry in entries {
            let ownsGaze = gazePoint.map { entry.cgFrame.contains($0) } ?? false
            let origin = entry.window.frame.origin
            var newDot: CGPoint?
            var newHighlight: CGRect?
            if ownsGaze, let gazePoint {
                let global = Coordinates.cgToAppKit(gazePoint)
                newDot = CGPoint(x: global.x - origin.x, y: global.y - origin.y)
            }
            if ownsGaze, let highlight {
                let global = Coordinates.cgToAppKit(highlight)
                newHighlight = global.offsetBy(dx: -origin.x, dy: -origin.y)
            }
            entry.view.setContent(gazePoint: newDot, highlight: newHighlight)
        }
    }
}

final class OverlayView: NSView {
    private(set) var gazePoint: CGPoint?
    private(set) var highlightRect: CGRect?

    /// Invalidates only the regions that actually changed. These windows
    /// cover entire screens, and blanket needsDisplay at 30 fps across every
    /// display made WindowServer re-composite ~11M transparent pixels per
    /// frame, continuously.
    func setContent(gazePoint newPoint: CGPoint?, highlight newRect: CGRect?) {
        if newPoint != gazePoint {
            if let old = gazePoint { setNeedsDisplay(Self.dotRect(at: old).insetBy(dx: -2, dy: -2)) }
            if let new = newPoint { setNeedsDisplay(Self.dotRect(at: new).insetBy(dx: -2, dy: -2)) }
            gazePoint = newPoint
        }
        if newRect != highlightRect {
            if let old = highlightRect { setNeedsDisplay(old.insetBy(dx: -4, dy: -4)) }
            if let new = newRect { setNeedsDisplay(new.insetBy(dx: -4, dy: -4)) }
            highlightRect = newRect
        }
    }

    private static func dotRect(at point: CGPoint) -> CGRect {
        let radius: CGFloat = 7
        return CGRect(
            x: point.x - radius, y: point.y - radius,
            width: radius * 2, height: radius * 2
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        if let rect = highlightRect {
            let path = NSBezierPath(
                roundedRect: rect.insetBy(dx: 2, dy: 2),
                xRadius: 8, yRadius: 8
            )
            path.lineWidth = 3
            NSColor.systemTeal.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
        if let point = gazePoint {
            NSColor.systemOrange.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: Self.dotRect(at: point)).fill()
        }
    }
}
