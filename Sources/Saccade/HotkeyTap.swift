import Foundation
import CoreGraphics
import AppKit

/// Listens for a solo Right Option press via a listen-only CGEvent tap.
/// Fires on key-down for minimum latency.
final class HotkeyTap {
    private static let rightOptionKeycode: Int64 = 61

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rightOptionDown = false

    var onTrigger: (() -> Void)?
    /// Fired for Command + Right Option (pause/resume tracking).
    var onToggle: (() -> Void)?

    @discardableResult
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
                tap.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == Self.rightOptionKeycode
        else { return }

        let pressed = event.flags.contains(.maskAlternate)
        if pressed && !rightOptionDown {
            rightOptionDown = true
            let withCommand = event.flags.contains(.maskCommand)
            DispatchQueue.main.async {
                withCommand ? self.onToggle?() : self.onTrigger?()
            }
        } else if !pressed {
            rightOptionDown = false
        }
    }
}
