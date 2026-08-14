import AppKit

/// Global CG coordinates (CGWindowList, CGEvent) have their origin at the
/// top-left of the primary display with y growing downward. AppKit global
/// coordinates have their origin at the bottom-left of the primary display
/// with y growing upward. These helpers convert between the two.
enum Coordinates {
    private static var primaryScreenHeight: CGFloat {
        // NSScreen.screens.first is the primary screen (its AppKit frame origin is 0,0).
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    static func cgToAppKit(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    static func appKitToCG(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    static func cgToAppKit(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func appKitToCG(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// The screen's frame in global CG coordinates.
    static func cgFrame(of screen: NSScreen) -> CGRect {
        appKitToCG(screen.frame)
    }

    /// Finds the NSScreen whose CG frame matches (used to place the overlay
    /// on the calibrated screen after relaunch).
    static func screen(matchingCGFrame frame: CGRect) -> NSScreen? {
        NSScreen.screens.first { cgFrame(of: $0).insetBy(dx: -2, dy: -2).contains(
            CGPoint(x: frame.midX, y: frame.midY)
        ) }
    }
}
