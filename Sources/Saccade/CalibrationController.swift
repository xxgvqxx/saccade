import AppKit

/// Full-screen, two-phase calibration:
///   Phase 1 — head still, eyes follow the dot (dense grid).
///   Phase 2 — head turns to point the nose at the dot (coarse grid).
/// Phase 2 teaches the model how head pose and eye position combine, so a
/// turned head with counter-rotated eyes doesn't read as a gaze shift.
/// Space starts each phase; Esc cancels.
final class CalibrationController {
    private enum State {
        case idle
        case interstitial
        case settling
        case collecting
    }

    private struct PhaseSpec {
        let cols: Int
        let rows: Int
        let title: String
        let instruction: String
    }

    private var window: KeyableWindow?
    private var view: CalibrationView?
    private var screen: NSScreen?
    private var config: Config

    private var phases: [PhaseSpec] = []
    private var phaseIndex = 0
    private var points: [CGPoint] = []  // view coordinates
    private var pointIndex = 0
    private var state: State = .idle
    private var collected: [[Double]] = []
    private var samples: [(raw: [Double], target: CGPoint)] = []
    private var settleTimer: Timer?

    /// Called with the fitted model and the samples that produced it (empty
    /// on cancel). The samples persist so cursor refinement can refit later.
    var onComplete: ((GazeModel?, [(raw: [Double], target: CGPoint)]) -> Void)?
    var isActive: Bool { window != nil }

    init(config: Config) {
        self.config = config
    }

    func begin(on screen: NSScreen) {
        guard window == nil else { return }
        self.screen = screen
        samples = []
        phaseIndex = 0
        // Portrait screens get the grid transposed so the dense axis follows
        // the screen's long dimension.
        let portrait = screen.frame.height > screen.frame.width
        let eyeCols = max(2, config.calibrationColumns)
        let eyeRows = max(2, config.calibrationRows)
        let headCols = max(2, config.headPassColumns ?? 3)
        let headRows = max(2, config.headPassRows ?? 3)
        phases = [
            PhaseSpec(
                cols: portrait ? eyeRows : eyeCols,
                rows: portrait ? eyeCols : eyeRows,
                title: "Phase 1 of 2 — Eyes",
                instruction: "Keep your head still. Follow the dot with your EYES only."
            ),
            PhaseSpec(
                cols: portrait ? headRows : headCols,
                rows: portrait ? headCols : headRows,
                title: "Phase 2 of 2 — Head",
                instruction: "TURN YOUR HEAD to point your nose at each dot. Let your eyes follow naturally."
            ),
        ]

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

        let calibrationView = CalibrationView(frame: NSRect(origin: .zero, size: screen.frame.size))
        calibrationView.onCancel = { [weak self] in self?.finish(model: nil) }
        calibrationView.onSpace = { [weak self] in self?.handleSpace() }
        calibrationWindow.contentView = calibrationView
        calibrationWindow.makeKeyAndOrderFront(nil)
        calibrationWindow.makeFirstResponder(calibrationView)
        NSApp.activate(ignoringOtherApps: true)

        window = calibrationWindow
        view = calibrationView
        enterInterstitial()
    }

    private func enterInterstitial() {
        state = .interstitial
        let phase = phases[phaseIndex]
        view?.mode = .interstitial(
            title: phase.title,
            instruction: phase.instruction + "\n\nPress Space to begin."
        )
        view?.needsDisplay = true
    }

    private func handleSpace() {
        guard state == .interstitial else { return }
        startPhasePoints()
    }

    private func startPhasePoints() {
        guard let screen else { return }
        let phase = phases[phaseIndex]
        let size = screen.frame.size
        let insetX = size.width * 0.05
        let insetY = size.height * 0.07
        points = []
        for row in 0..<phase.rows {
            for col in 0..<phase.cols {
                let x = insetX + (size.width - 2 * insetX) * CGFloat(col) / CGFloat(phase.cols - 1)
                let y = insetY + (size.height - 2 * insetY) * CGFloat(row) / CGFloat(phase.rows - 1)
                points.append(CGPoint(x: x, y: y))
            }
        }
        pointIndex = 0
        advanceToCurrentPoint()
    }

    /// Feed one raw feature sample (call on the main thread).
    func ingest(raw: [Double]) {
        guard isActive else { return }
        view?.faceVisible = true
        guard state == .collecting else { return }
        collected.append(raw)
        view?.progress = Double(collected.count) / Double(max(1, config.samplesPerPoint))
        view?.needsDisplay = true
        if collected.count >= config.samplesPerPoint {
            commitCurrentPoint()
        }
    }

    func ingestNoFace() {
        guard isActive else { return }
        view?.faceVisible = false
        view?.needsDisplay = true
    }

    private func advanceToCurrentPoint() {
        guard pointIndex < points.count else {
            phaseIndex += 1
            if phaseIndex < phases.count {
                enterInterstitial()
            } else {
                fitAndFinish()
            }
            return
        }
        collected = []
        state = .settling
        let phase = phases[phaseIndex]
        view?.mode = .point(
            position: points[pointIndex],
            status: "\(phase.title) — point \(pointIndex + 1) of \(points.count)",
            hint: phase.instruction
        )
        view?.progress = 0
        view?.needsDisplay = true

        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            self?.state = .collecting
        }
    }

    private func commitCurrentPoint() {
        state = .settling
        guard let window else { return }
        let viewPoint = points[pointIndex]

        // Median over collected frames rejects outlier frames (micro-saccades, blinks).
        let medianRaw = Self.median(of: collected)

        let globalAppKit = CGPoint(
            x: viewPoint.x + window.frame.minX,
            y: viewPoint.y + window.frame.minY
        )
        let targetCG = Coordinates.appKitToCG(globalAppKit)

        // Every collected frame becomes a sample; the median becomes one extra
        // strongly representative sample.
        for raw in collected {
            samples.append((raw: raw, target: targetCG))
        }
        samples.append((raw: medianRaw, target: targetCG))

        pointIndex += 1
        advanceToCurrentPoint()
    }

    private func fitAndFinish() {
        guard let screen else {
            finish(model: nil)
            return
        }
        let model = GazeModel.fit(samples: samples, screenFrame: Coordinates.cgFrame(of: screen))
        finish(model: model)
    }

    private func finish(model: GazeModel?) {
        settleTimer?.invalidate()
        settleTimer = nil
        window?.orderOut(nil)
        window = nil
        view = nil
        state = .idle
        onComplete?(model, model != nil ? samples : [])
    }

    private static func median(of samples: [[Double]]) -> [Double] {
        guard let first = samples.first else { return [] }
        var result = [Double](repeating: 0, count: first.count)
        for i in 0..<first.count {
            let sorted = samples.map { $0[i] }.sorted()
            result[i] = sorted[sorted.count / 2]
        }
        return result
    }
}

final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class CalibrationView: NSView {
    enum Mode {
        case interstitial(title: String, instruction: String)
        case point(position: CGPoint, status: String, hint: String)
    }

    var mode: Mode = .interstitial(title: "", instruction: "")
    var progress: Double = 0
    var faceVisible: Bool = true
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
            drawCenteredText(title, size: 30, weight: .bold, color: .white, yOffset: 60)
            drawMultilineCentered(instruction, size: 18, color: .lightGray, yOffset: -20)
            drawCenteredText("Esc to cancel", size: 13, weight: .regular, color: .darkGray, yOffset: -120)

        case .point(let position, let status, let hint):
            drawDot(at: position)
            let statusLine = faceVisible ? status : "\(status)   ⚠ no face detected"
            drawCenteredText(
                statusLine, size: 18, weight: .medium,
                color: faceVisible ? .lightGray : .systemYellow, yOffset: 0
            )
            drawCenteredText("\(hint) · Esc to cancel", size: 13, weight: .regular, color: .darkGray, yOffset: -28)
        }
    }

    private func drawDot(at center: CGPoint) {
        let ringRadius: CGFloat = 16
        let ring = NSBezierPath()
        ring.appendArc(
            withCenter: center, radius: ringRadius,
            startAngle: 90, endAngle: 90 - 360 * CGFloat(min(1, progress)),
            clockwise: true
        )
        ring.lineWidth = 4
        NSColor.systemTeal.setStroke()
        ring.stroke()

        let dotRadius: CGFloat = 8
        let dotRect = CGRect(
            x: center.x - dotRadius, y: center.y - dotRadius,
            width: dotRadius * 2, height: dotRadius * 2
        )
        NSColor.white.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    }

    private func drawCenteredText(
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

    private func drawMultilineCentered(_ text: String, size: CGFloat, color: NSColor, yOffset: CGFloat) {
        var y = yOffset
        for line in text.components(separatedBy: "\n") {
            drawCenteredText(line, size: size, weight: .regular, color: color, yOffset: y)
            y -= size + 10
        }
    }
}
