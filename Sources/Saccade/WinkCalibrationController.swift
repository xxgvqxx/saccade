import AppKit

/// Guided wink calibration: four short captures that learn this user's eyes.
///   1. Both eyes open (baseline)
///   2. Normal blinks (closed baseline — and proof of what a blink looks like)
///   3. Three LEFT winks
///   4. Three RIGHT winks
/// From these it derives per-eye open/closed openness, which Vision landmark
/// region is the user's left eye (whichever region actually closed — immune
/// to camera mirroring), and how far the companion eye droops during a
/// deliberate wink (that sets the blink-rejection guard).
///
/// Space starts each capture; Esc cancels. Memory: each phase's buffer is
/// hard-capped, and the window/view/timer are all torn down on finish.
final class WinkCalibrationController {
    private enum Phase: Int, CaseIterable {
        case open
        case blink
        case leftWink
        case rightWink

        var title: String {
            switch self {
            case .open: return "Step 1 of 4 — Eyes Open"
            case .blink: return "Step 2 of 4 — Blinks"
            case .leftWink: return "Step 3 of 4 — Left Winks"
            case .rightWink: return "Step 4 of 4 — Right Winks"
            }
        }

        var instruction: String {
            switch self {
            case .open:
                return "Look at this screen with both eyes open, relaxed.\nDon't fight blinks — just sit naturally."
            case .blink:
                return "Blink normally a few times while looking at the screen.\nNormal, quick blinks — both eyes."
            case .leftWink:
                return "Wink your LEFT eye 3 times.\nHold each wink about half a second, then open."
            case .rightWink:
                return "Wink your RIGHT eye 3 times.\nHold each wink about half a second, then open."
            }
        }

        /// Frames to capture (~30 fps).
        var frameTarget: Int {
            switch self {
            case .open: return 45      // ~1.5 s
            case .blink: return 105    // ~3.5 s
            case .leftWink, .rightWink: return 165  // ~5.5 s
            }
        }
    }

    private enum State {
        case idle
        case interstitial
        case collecting
    }

    private var window: KeyableWindow?
    private var view: WinkCalibrationView?
    private var state: State = .idle
    private var phase: Phase = .open
    /// (visionLeft, visionRight) openness + head yaw per frame, per phase.
    private var captured: [Phase: [(l: Double, r: Double, yaw: Double)]] = [:]
    private var retryNote: String?

    /// (result, failureMessage) — both nil on user cancel; failureMessage set
    /// when all four captures ran but no usable calibration came out.
    var onComplete: ((WinkCalibrationData?, String?) -> Void)?
    var isActive: Bool { window != nil }

    func begin(on screen: NSScreen) {
        guard window == nil else { return }
        captured = [:]
        phase = .open
        retryNote = nil

        let calibrationWindow = KeyableWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        calibrationWindow.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        calibrationWindow.backgroundColor = NSColor.black.withAlphaComponent(0.96)
        calibrationWindow.isOpaque = false
        calibrationWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let calibrationView = WinkCalibrationView(frame: NSRect(origin: .zero, size: screen.frame.size))
        calibrationView.onCancel = { [weak self] in self?.finish(nil, failure: nil) }
        calibrationView.onSpace = { [weak self] in self?.handleSpace() }
        calibrationWindow.contentView = calibrationView
        calibrationWindow.makeKeyAndOrderFront(nil)
        calibrationWindow.makeFirstResponder(calibrationView)
        NSApp.activate(ignoringOtherApps: true)

        window = calibrationWindow
        view = calibrationView
        enterInterstitial()
    }

    /// Feed one frame's openness (Vision labeling) and head yaw. Main thread.
    func ingest(visionLeft: Double, visionRight: Double, yaw: Double) {
        guard isActive else { return }
        view?.faceVisible = true
        guard state == .collecting else { return }
        var frames = captured[phase] ?? []
        // Hard cap — ingest can race the phase transition by a frame or two.
        guard frames.count < phase.frameTarget else { return }
        frames.append((l: visionLeft, r: visionRight, yaw: yaw))
        captured[phase] = frames
        view?.progress = Double(frames.count) / Double(phase.frameTarget)
        view?.needsDisplay = true
        if frames.count >= phase.frameTarget {
            advancePhase()
        }
    }

    func ingestNoFace() {
        guard isActive else { return }
        view?.faceVisible = false
        view?.needsDisplay = true
    }

    private func handleSpace() {
        guard state == .interstitial else { return }
        captured[phase] = []
        state = .collecting
        view?.mode = .collecting(title: phase.title, instruction: phase.instruction)
        view?.progress = 0
        view?.needsDisplay = true
    }

    private func enterInterstitial() {
        state = .interstitial
        var instruction = phase.instruction
        if let retryNote {
            instruction = "⚠ \(retryNote)\n\n\(instruction)"
        }
        view?.mode = .interstitial(
            title: phase.title,
            instruction: instruction + "\n\nPress Space to begin."
        )
        view?.progress = 0
        view?.needsDisplay = true
    }

    private func advancePhase() {
        state = .interstitial
        retryNote = nil
        // Wink phases must actually contain distinguishable winks before we
        // move on — re-run the phase with coaching if not.
        if phase == .leftWink || phase == .rightWink {
            if let problem = Self.winkPhaseProblem(
                frames: captured[phase] ?? [],
                openStats: openStats(),
                closedStats: closedStats()
            ) {
                retryNote = problem
                enterInterstitial()
                return
            }
        }
        if let next = Phase(rawValue: phase.rawValue + 1) {
            phase = next
            enterInterstitial()
        } else {
            let (data, failure) = buildCalibration()
            finish(data, failure: failure)
        }
    }

    // MARK: - Analysis

    private func openStats() -> (l: Double, r: Double) {
        let frames = captured[.open] ?? []
        return (
            l: Self.median(frames.map { $0.l }),
            r: Self.median(frames.map { $0.r })
        )
    }

    /// Closed baseline = the bottom of the blink-phase excursions.
    private func closedStats() -> (l: Double, r: Double) {
        let frames = captured[.blink] ?? []
        return (
            l: Self.percentile(frames.map { $0.l }, 0.05),
            r: Self.percentile(frames.map { $0.r }, 0.05)
        )
    }

    /// Frames within a wink phase where exactly one eye is well down and the
    /// other clearly up, in normalized openness.
    private static func winkFrames(
        frames: [(l: Double, r: Double, yaw: Double)],
        openStats: (l: Double, r: Double), closedStats: (l: Double, r: Double)
    ) -> (leftRegionClosed: [(l: Double, r: Double)], rightRegionClosed: [(l: Double, r: Double)]) {
        var leftClosed: [(l: Double, r: Double)] = []
        var rightClosed: [(l: Double, r: Double)] = []
        for frame in frames {
            let ln = normalize(frame.l, open: openStats.l, closed: closedStats.l)
            let rn = normalize(frame.r, open: openStats.r, closed: closedStats.r)
            if ln < 0.4, rn > 0.55 { leftClosed.append((l: ln, r: rn)) }
            if rn < 0.4, ln > 0.55 { rightClosed.append((l: ln, r: rn)) }
        }
        return (leftClosed, rightClosed)
    }

    /// nil = phase is usable; otherwise the message to show before retrying.
    private static func winkPhaseProblem(
        frames: [(l: Double, r: Double, yaw: Double)],
        openStats: (l: Double, r: Double), closedStats: (l: Double, r: Double)
    ) -> String? {
        let (leftClosed, rightClosed) = winkFrames(
            frames: frames, openStats: openStats, closedStats: closedStats
        )
        let winner = max(leftClosed.count, rightClosed.count)
        if winner < 8 {
            return "Couldn't see clear winks — one eye needs to close while the OTHER stays open. Hold each wink about half a second. If your other eye squeezes shut too, try raising that eyebrow."
        }
        return nil
    }

    private func buildCalibration() -> (WinkCalibrationData?, String?) {
        let open = openStats()
        let closed = closedStats()
        // The eyes must have a usable dynamic range at all.
        guard open.l - closed.l > 0.04, open.r - closed.r > 0.04 else {
            return (nil, "The blink step didn't show a usable open-to-closed range. Make sure your eyes are well lit and visible to the camera, then recalibrate.")
        }

        let (leftPhaseLeftClosed, leftPhaseRightClosed) = Self.winkFrames(
            frames: captured[.leftWink] ?? [], openStats: open, closedStats: closed
        )
        let (rightPhaseLeftClosed, rightPhaseRightClosed) = Self.winkFrames(
            frames: captured[.rightWink] ?? [], openStats: open, closedStats: closed
        )

        // Which Vision region closed during "wink your LEFT eye"? The two
        // phases must disagree, or we never actually saw two different eyes.
        let userLeftIsVisionLeft = leftPhaseLeftClosed.count >= leftPhaseRightClosed.count
        let userRightIsVisionLeft = rightPhaseLeftClosed.count >= rightPhaseRightClosed.count
        guard userLeftIsVisionLeft != userRightIsVisionLeft else {
            return (nil, "Both wink steps closed the SAME eye, so left and right can't be told apart. Recalibrate and make sure each step winks a different eye.")
        }

        // Companion droop: how low the open eye got across ALL wink frames.
        // The guard sits below that with margin, but never below 0.42 — under
        // that a wink is not reliably distinguishable from a blink.
        var companionValues: [Double] = []
        companionValues += (userLeftIsVisionLeft ? leftPhaseLeftClosed : leftPhaseRightClosed)
            .map { userLeftIsVisionLeft ? $0.r : $0.l }
        companionValues += (userRightIsVisionLeft ? rightPhaseLeftClosed : rightPhaseRightClosed)
            .map { userRightIsVisionLeft ? $0.r : $0.l }
        let droopFloor = Self.percentile(companionValues, 0.10)
        let companionGuard = max(0.42, droopFloor - 0.12)
        guard droopFloor >= 0.42 else {
            return (nil, "Your open eye droops almost shut when you wink, which reads as a blink. Try softer winks — or raise the eyebrow over the open eye — and recalibrate.")
        }

        // Head pose to gate detection around: winks only count near the pose
        // they were calibrated in — far-eye landmarks lie under big yaw.
        let allYaw = Phase.allCases.flatMap { (captured[$0] ?? []).map { $0.yaw } }
        let referenceYaw = Self.median(allYaw)

        // This user's wink asymmetry: how far apart the eyes' normalized
        // openness actually sits mid-wink. Detection requires 60% of the
        // 25th-percentile gap, floored — blinks (both eyes down together)
        // never open a gap like this even when pose skews the levels.
        var asymValues: [Double] = []
        asymValues += (userLeftIsVisionLeft ? leftPhaseLeftClosed : leftPhaseRightClosed)
            .map { abs($0.r - $0.l) }
        asymValues += (userRightIsVisionLeft ? rightPhaseLeftClosed : rightPhaseRightClosed)
            .map { abs($0.r - $0.l) }
        let asymEntry = min(0.55, max(0.30, Self.percentile(asymValues, 0.25) * 0.6))

        let data = WinkCalibrationData(
            visionLeftOpen: open.l,
            visionLeftClosed: closed.l,
            visionRightOpen: open.r,
            visionRightClosed: closed.r,
            userLeftIsVisionLeft: userLeftIsVisionLeft,
            companionGuard: companionGuard,
            referenceYaw: referenceYaw,
            asymEntry: asymEntry
        )
        return (data, nil)
    }

    private func finish(_ result: WinkCalibrationData?, failure: String?) {
        window?.orderOut(nil)
        window = nil
        view = nil
        state = .idle
        captured = [:]
        onComplete?(result, failure)
    }

    private static func normalize(_ value: Double, open: Double, closed: Double) -> Double {
        let range = open - closed
        guard range > 0.001 else { return 1 }
        return min(max((value - closed) / range, 0), 1)
    }

    private static func median(_ values: [Double]) -> Double {
        percentile(values, 0.5)
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count) * p)))
        return sorted[index]
    }
}

final class WinkCalibrationView: NSView {
    enum Mode {
        case interstitial(title: String, instruction: String)
        case collecting(title: String, instruction: String)
    }

    var mode: Mode = .interstitial(title: "", instruction: "")
    var progress: Double = 0
    var faceVisible = true
    var onCancel: (() -> Void)?
    var onSpace: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()  // Esc
        case 49: onSpace?()   // Space
        default: break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        switch mode {
        case .interstitial(let title, let instruction):
            drawCentered(title, size: 30, weight: .bold, color: .white, yOffset: 80)
            drawMultiline(instruction, size: 18, color: .lightGray, yOffset: 0)
            drawCentered("Esc to cancel", size: 13, weight: .regular, color: .darkGray, yOffset: -140)

        case .collecting(let title, let instruction):
            drawCentered(title, size: 30, weight: .bold, color: .white, yOffset: 80)
            drawMultiline(instruction, size: 18, color: .lightGray, yOffset: 0)
            let status = faceVisible
                ? String(format: "Capturing…  %.0f%%", progress * 100)
                : "⚠ no face detected"
            drawCentered(
                status, size: 18, weight: .medium,
                color: faceVisible ? .systemTeal : .systemYellow, yOffset: -100
            )
            // Progress bar.
            let barWidth = bounds.width * 0.3
            let barRect = NSRect(
                x: (bounds.width - barWidth) / 2, y: bounds.height * 0.5 - 140,
                width: barWidth, height: 6
            )
            NSColor.darkGray.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 3, yRadius: 3).fill()
            var fillRect = barRect
            fillRect.size.width = barWidth * CGFloat(min(1, progress))
            NSColor.systemTeal.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3).fill()
        }
    }

    private func drawCentered(
        _ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, yOffset: CGFloat
    ) {
        let attributed = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: size, weight: weight),
        ])
        let textSize = attributed.size()
        attributed.draw(at: CGPoint(
            x: (bounds.width - textSize.width) / 2,
            y: bounds.height * 0.5 - textSize.height / 2 + yOffset
        ))
    }

    private func drawMultiline(_ text: String, size: CGFloat, color: NSColor, yOffset: CGFloat) {
        var y = yOffset
        for line in text.components(separatedBy: "\n") {
            drawCentered(line, size: size, weight: .regular, color: color, yOffset: y)
            y -= size + 10
        }
    }
}
