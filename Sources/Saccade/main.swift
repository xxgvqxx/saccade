import AppKit
import AVFoundation
import QuartzCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config.load()
    private var store = ModelStore()

    private let camera = CameraCapture()
    private let overlay = OverlayController()
    private let hotkey = HotkeyTap()
    private let pursuit = PursuitCalibrator()
    private var focus: FocusController!
    private var calibration: CalibrationController!

    private var filterX: OneEuroFilter!
    private var filterY: OneEuroFilter!

    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var trackingMenuItem: NSMenuItem!
    private var gazeDotMenuItem: NSMenuItem!
    private var refineMenuItem: NSMenuItem!
    private var cameraPowerMenuItem: NSMenuItem!
    private var cameraSubmenu: NSMenu!
    private var calibrateSubmenu: NSMenu!
    private var smoothingSubmenu: NSMenu!
    private var calibratingScreenName: String?
    private var recentJumps: [String] = []
    /// Anchor for the fixation stabilizer (global CG coords).
    private var fixationAnchor: CGPoint?

    // Cursor-refinement session state (main thread only).
    private static let pursuitSampleCap = 2400
    private var pursuitBaselineRMS: [String: Double] = [:]
    private var pursuitCollected: [String: Int] = [:]
    private var pursuitSkipped: Set<String> = []
    private var pursuitPendingRefit: [String: Int] = [:]
    private var refitInFlight = false

    private var trackingEnabled = true
    private var accessibilityOK = false
    private var hotkeyOK = false
    private var cameraStatus = "starting…"

    // Gaze state (main thread only).
    private var gazePoint: CGPoint?
    private var currentTarget: TargetWindow?
    private var pendingTarget: TargetWindow?
    private var pendingCount = 0
    private var lastFaceTime: Double = 0
    /// Recent normalized predictions; a median over these rejects single-frame
    /// landmark spikes before smoothing.
    private var recentNormalized: [(x: Double, y: Double)] = []
    /// Which calibrated screen currently owns the gaze, with hysteresis.
    private var currentScreenKey: String?
    private var pendingScreenKey: String?
    private var pendingScreenCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        focus = FocusController(clickBundleIDs: config.clickBundleIDs)
        focus.onReport = { [weak self] line in
            DispatchQueue.main.async { self?.recordJump(line) }
        }
        calibration = CalibrationController(config: config)
        rebuildFilters()
        store = ModelStore.load()

        setupStatusItem()
        checkAccessibility()
        setupOverlay()
        setupCalibrationCompletion()
        setupCamera()
        setupHotkey()
        setupHousekeeping()
    }

    // MARK: - Setup

    private func rebuildFilters() {
        let s = config.smoothing
        filterX = OneEuroFilter(minCutoff: s.minCutoff, beta: s.beta, dCutoff: s.dCutoff)
        filterY = OneEuroFilter(minCutoff: s.minCutoff, beta: s.beta, dCutoff: s.dCutoff)
    }

    private func setupOverlay() {
        overlay.setup(cgFrames: store.screens.values.map { $0.model.screenFrame })
    }

    private func checkAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityOK = AXIsProcessTrustedWithOptions(options)
    }

    private func setupCamera() {
        camera.onFeatures = { [weak self] raw in
            DispatchQueue.main.async { self?.handleFeatures(raw) }
        }
        camera.onNoFace = { [weak self] in
            DispatchQueue.main.async { self?.handleNoFace() }
        }
        camera.start(uniqueID: config.cameraUniqueID, preferredName: config.cameraName) { [weak self] ok, message in
            DispatchQueue.main.async {
                self?.cameraStatus = ok ? message : "⚠ \(message)"
            }
        }
    }

    private func setupHotkey() {
        hotkey.onTrigger = { [weak self] in self?.jump() }
        hotkey.onToggle = { [weak self] in
            guard let self else { return }
            self.setTracking(!self.trackingEnabled)
        }
        hotkeyOK = hotkey.start()
    }

    private func setupCalibrationCompletion() {
        calibration.onComplete = { [weak self] newModel, samples in
            guard let self else { return }
            self.overlay.show()
            let name = self.calibratingScreenName
            self.calibratingScreenName = nil
            if let newModel, let name {
                // A fresh grid supersedes any cursor samples collected against
                // the old geometry.
                self.store.screens[name] = ScreenCalibration(
                    model: newModel,
                    gridSamples: ModelStore.samples(fromTuples: samples),
                    pursuitSamples: []
                )
                self.store.save()
                self.rebuildFilters()
                self.clearGaze()
                self.setupOverlay()
                self.showAlert(
                    title: "Calibration complete — \(name)",
                    text: String(
                        format: "Fit error ≈ %.0f px RMS.\nWindow-sized targets need roughly < 250 px to feel reliable. Calibrate your other screens too — the gaze follows you to whichever calibrated screen you look at.",
                        newModel.rmsErrorPixels
                    )
                )
            } else {
                self.showAlert(
                    title: "Calibration cancelled",
                    text: "Existing calibrations are unchanged."
                )
            }
        }
    }

    private func setupHousekeeping() {
        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.gazePoint != nil, CACurrentMediaTime() - self.lastFaceTime > 0.6 {
                self.clearGaze()
            }
            tick += 1
            if tick % 8 == 0 {
                // Accessibility can be granted while the app runs; pick the
                // grant up and bring the hotkey tap back without a relaunch.
                self.accessibilityOK = AXIsProcessTrusted()
                if !self.hotkeyOK, self.accessibilityOK {
                    self.hotkeyOK = self.hotkey.start()
                }
                self.writeStateFile()
            }
        }
    }

    /// Live diagnostics for debugging from outside the app.
    private func writeStateFile() {
        let state: [String: Any] = [
            "accessibilityTrusted": accessibilityOK,
            "hotkeyTapAlive": hotkeyOK,
            "camera": camera.isRunning ? cameraStatus : "OFF",
            "faceDetected": CACurrentMediaTime() - lastFaceTime < 0.6,
            "trackingEnabled": trackingEnabled,
            "gazeOnScreen": currentScreenKey ?? "none",
            "targetWindow": currentTarget.map { "\($0.ownerName) #\($0.windowID)" } ?? "none",
            "calibratedScreens": store.screens.keys.sorted(),
            "refining": pursuit.isActive,
            "smoothing": String(format: "minCutoff %.2f / beta %.3f / fixation %.0fpx",
                                config.smoothing.minCutoff, config.smoothing.beta,
                                config.smoothing.fixationRadius ?? 30),
            "recentJumps": recentJumps,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? data.write(to: Config.directory.appendingPathComponent("state.json"))
        }
    }

    // MARK: - Gaze pipeline (main thread)

    private func handleFeatures(_ raw: [Double]) {
        lastFaceTime = CACurrentMediaTime()
        if calibration.isActive {
            calibration.ingest(raw: raw)
            return
        }
        if pursuit.isActive, let cursor = pursuit.sampleCursor(now: lastFaceTime) {
            ingestPursuitSample(raw: raw, cursorCG: cursor)
        }
        guard trackingEnabled, !store.screens.isEmpty else { return }

        // Every calibrated screen's model predicts; the screen whose
        // prediction lands deepest inside its own bounds is the one being
        // looked at.
        var bestKey = ""
        var bestN = (x: 0.0, y: 0.0)
        var bestScore = -Double.greatestFiniteMagnitude
        for (key, calibrated) in store.screens {
            let n = calibrated.model.predictNormalized(raw)
            let score = min(n.x, 1 - n.x, n.y, 1 - n.y)
            if score > bestScore {
                bestScore = score
                bestKey = key
                bestN = n
            }
        }

        // Even the best candidate is clearly off its screen: looking at
        // nothing calibrated — drop the gaze instead of pinning it to an edge.
        if bestN.x < -0.08 || bestN.x > 1.08 || bestN.y < -0.12 || bestN.y > 1.12 {
            clearGaze()
            return
        }

        // A screen switch needs a few consecutive frames to confirm; the gaze
        // holds on the old screen meanwhile.
        if bestKey != currentScreenKey {
            if pendingScreenKey == bestKey {
                pendingScreenCount += 1
            } else {
                pendingScreenKey = bestKey
                pendingScreenCount = 1
            }
            guard pendingScreenCount >= 3 || currentScreenKey == nil else { return }
            currentScreenKey = bestKey
            pendingScreenKey = nil
            pendingScreenCount = 0
            recentNormalized.removeAll()
            fixationAnchor = nil
            filterX.reset()
            filterY.reset()
        } else {
            pendingScreenKey = nil
            pendingScreenCount = 0
        }
        guard let model = store.screens[bestKey]?.model else { return }

        recentNormalized.append(bestN)
        if recentNormalized.count > 5 { recentNormalized.removeFirst() }
        let mx = Self.median(recentNormalized.map { $0.x })
        let my = Self.median(recentNormalized.map { $0.y })

        let t = CACurrentMediaTime()
        let smoothX = filterX.filter(mx, timestamp: t)
        let smoothY = filterY.filter(my, timestamp: t)
        let frame = model.screenFrame
        let clamped = CGPoint(
            x: min(max(frame.minX + CGFloat(smoothX) * frame.width, frame.minX + 1), frame.maxX - 1),
            y: min(max(frame.minY + CGFloat(smoothY) * frame.height, frame.minY + 1), frame.maxY - 1)
        )
        let stabilized = stabilize(clamped)
        gazePoint = stabilized
        updateTarget(for: stabilized)
        overlay.update(
            gazePoint: config.showGazeDot ? stabilized : nil,
            highlight: currentTarget?.bounds
        )
    }

    /// Pins the output during fixation: within the radius the point only
    /// drifts slowly toward new samples, killing residual jitter without
    /// adding lag to real gaze shifts (those exceed the radius and re-anchor).
    private func stabilize(_ point: CGPoint) -> CGPoint {
        let radius = CGFloat(config.smoothing.fixationRadius ?? 30)
        guard radius > 0 else { return point }
        if let anchor = fixationAnchor,
           hypot(point.x - anchor.x, point.y - anchor.y) < radius {
            let drift: CGFloat = 0.08
            let updated = CGPoint(
                x: anchor.x + (point.x - anchor.x) * drift,
                y: anchor.y + (point.y - anchor.y) * drift
            )
            fixationAnchor = updated
            return updated
        }
        fixationAnchor = point
        return point
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func handleNoFace() {
        if calibration.isActive {
            calibration.ingestNoFace()
        }
    }

    private func clearGaze() {
        gazePoint = nil
        currentTarget = nil
        pendingTarget = nil
        pendingCount = 0
        recentNormalized.removeAll()
        currentScreenKey = nil
        pendingScreenKey = nil
        pendingScreenCount = 0
        fixationAnchor = nil
        filterX.reset()
        filterY.reset()
        overlay.update(gazePoint: nil, highlight: nil)
    }

    /// The highlight switches only after the same window sits under the gaze
    /// for a few consecutive frames — kills flicker at window borders.
    private func updateTarget(for point: CGPoint) {
        let candidate = WindowTargeting.window(at: point)
        if candidate?.windowID == currentTarget?.windowID {
            pendingTarget = nil
            pendingCount = 0
            return
        }
        if candidate?.windowID == pendingTarget?.windowID {
            pendingCount += 1
        } else {
            pendingTarget = candidate
            pendingCount = 1
        }
        if pendingCount >= config.targetSwitchFrames || currentTarget == nil {
            currentTarget = pendingTarget
            pendingTarget = nil
            pendingCount = 0
        }
    }

    // MARK: - Jump

    private func jump() {
        guard !calibration.isActive else { return }
        guard trackingEnabled, let target = currentTarget, let gaze = gazePoint else {
            NSSound.beep()
            recordJump("beep — no \(gazePoint == nil ? "gaze" : "target window") at press")
            return
        }
        focus.jump(to: target, gaze: gaze)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func recordJump(_ line: String) {
        recentJumps.append("\(Self.timeFormatter.string(from: Date())) \(line)")
        if recentJumps.count > 6 {
            recentJumps.removeFirst(recentJumps.count - 6)
        }
    }

    // MARK: - Cursor refinement

    private func ingestPursuitSample(raw: [Double], cursorCG: CGPoint) {
        guard let key = store.screens.first(where: {
            $0.value.model.screenFrame.contains(cursorCG)
        })?.key else { return }
        guard store.screens[key]?.gridSamples?.isEmpty == false else {
            // Calibrated before grid samples were persisted — nothing to
            // anchor a refit on.
            pursuitSkipped.insert(key)
            return
        }
        var calibrated = store.screens[key]!
        var pursuitList = calibrated.pursuitSamples ?? []
        pursuitList.append(TrainingSample(f: raw, x: Double(cursorCG.x), y: Double(cursorCG.y)))
        if pursuitList.count > Self.pursuitSampleCap {
            pursuitList.removeFirst(pursuitList.count - Self.pursuitSampleCap)
        }
        calibrated.pursuitSamples = pursuitList
        store.screens[key] = calibrated
        pursuitCollected[key, default: 0] += 1
        pursuitPendingRefit[key, default: 0] += 1
        if pursuitPendingRefit[key, default: 0] >= 200 {
            pursuitPendingRefit[key] = 0
            refitScreen(key, inBackground: true)
        }
    }

    /// Grid samples count double so sparse cursor coverage cannot drag the
    /// fit away from the calibrated anchor points.
    private func combinedSamples(for calibrated: ScreenCalibration) -> [(raw: [Double], target: CGPoint)] {
        guard let grid = calibrated.gridSamples, !grid.isEmpty else { return [] }
        var combined = ModelStore.tuples(grid)
        combined += ModelStore.tuples(grid)
        combined += ModelStore.tuples(calibrated.pursuitSamples ?? [])
        return combined
    }

    private func refitScreen(_ key: String, inBackground: Bool) {
        guard let calibrated = store.screens[key] else { return }
        let combined = combinedSamples(for: calibrated)
        guard !combined.isEmpty else { return }
        let frame = calibrated.model.screenFrame
        if inBackground {
            guard !refitInFlight else { return }
            refitInFlight = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let model = GazeModel.fit(samples: combined, screenFrame: frame)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.refitInFlight = false
                    // A stale background fit must not overwrite the final
                    // synchronous refit done when the session ends.
                    guard self.pursuit.isActive, let model else { return }
                    self.store.screens[key]?.model = model
                }
            }
        } else if let model = GazeModel.fit(samples: combined, screenFrame: frame) {
            store.screens[key]?.model = model
        }
    }

    private func endPursuit(showReport: Bool) {
        guard pursuit.isActive else { return }
        pursuit.stop()
        var lines: [String] = []
        for (key, count) in pursuitCollected.sorted(by: { $0.key < $1.key }) where count > 0 {
            refitScreen(key, inBackground: false)
            if let old = pursuitBaselineRMS[key],
               let new = store.screens[key]?.model.rmsErrorPixels {
                lines.append(String(
                    format: "%@: %.0f → %.0f px fit error (%d cursor samples)",
                    key, old, new, count
                ))
            }
        }
        store.save()
        guard showReport else { return }
        if lines.isEmpty {
            lines.append("No samples collected — the pointer has to move (slower than a flick) over a calibrated screen while your eyes follow it.")
        }
        for key in pursuitSkipped.sorted() {
            lines.append("\(key): skipped — its calibration predates saved grid samples. Recalibrate it once to make it refinable.")
        }
        showAlert(title: "Cursor refinement done", text: lines.joined(separator: "\n"))
    }

    // MARK: - Status item / menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "eye", accessibilityDescription: "Saccade"
        )

        let menu = NSMenu()
        menu.delegate = self

        statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        trackingMenuItem = menuItem("Tracking Enabled", action: #selector(toggleTracking))
        trackingMenuItem.state = .on
        menu.addItem(trackingMenuItem)

        gazeDotMenuItem = menuItem("Show Gaze Dot", action: #selector(toggleGazeDot))
        gazeDotMenuItem.state = config.showGazeDot ? .on : .off
        menu.addItem(gazeDotMenuItem)

        let smoothingItem = NSMenuItem(title: "Smoothing", action: nil, keyEquivalent: "")
        smoothingSubmenu = NSMenu()
        smoothingSubmenu.delegate = self
        smoothingItem.submenu = smoothingSubmenu
        menu.addItem(smoothingItem)

        menu.addItem(.separator())

        let calibrateItem = NSMenuItem(title: "Calibrate Screen", action: nil, keyEquivalent: "")
        calibrateSubmenu = NSMenu()
        calibrateSubmenu.delegate = self
        calibrateItem.submenu = calibrateSubmenu
        menu.addItem(calibrateItem)

        refineMenuItem = menuItem("Refine with Cursor", action: #selector(toggleRefinement))
        menu.addItem(refineMenuItem)

        cameraPowerMenuItem = menuItem("Turn Camera Off", action: #selector(toggleCameraPower))
        menu.addItem(cameraPowerMenuItem)

        let cameraItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        cameraSubmenu = NSMenu()
        cameraSubmenu.delegate = self
        cameraItem.submenu = cameraSubmenu
        menu.addItem(cameraItem)

        menu.addItem(menuItem("Open Config Folder", action: #selector(openConfigFolder)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Saccade", action: #selector(quit)))

        statusItem.menu = menu
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu == cameraSubmenu {
            rebuildCameraSubmenu()
            return
        }
        if menu == calibrateSubmenu {
            rebuildCalibrateSubmenu()
            return
        }
        if menu == smoothingSubmenu {
            rebuildSmoothingSubmenu()
            return
        }
        let pursuitTotal = pursuitCollected.values.reduce(0, +)
        refineMenuItem.title = pursuit.isActive
            ? "Stop Cursor Refinement (\(pursuitTotal) samples)"
            : "Refine with Cursor"
        refineMenuItem.state = pursuit.isActive ? .on : .off

        cameraPowerMenuItem.title = camera.isRunning ? "Turn Camera Off" : "Turn Camera On"

        var parts: [String] = []
        parts.append(trackingEnabled ? "Tracking" : "PAUSED (⌘+Right⌥ resumes)")
        if pursuit.isActive {
            parts.append("Refining — \(pursuitTotal) cursor samples")
        }
        parts.append(camera.isRunning ? "Camera: \(cameraStatus)" : "Camera: OFF")
        let faceRecent = CACurrentMediaTime() - lastFaceTime < 0.6
        parts.append(faceRecent ? "Face: ✓" : "Face: not detected")
        if store.screens.isEmpty {
            parts.append("Not calibrated — use Calibrate Screen")
        } else {
            let summaries = NSScreen.screens.map { screen in
                if let calibrated = store.screens[screen.localizedName] {
                    return String(format: "%@ ±%.0fpx", screen.localizedName, calibrated.model.rmsErrorPixels)
                }
                return "\(screen.localizedName): —"
            }
            parts.append(summaries.joined(separator: " · "))
        }
        if !accessibilityOK {
            parts.append("⚠ Grant Accessibility in System Settings")
        }
        if !hotkeyOK {
            parts.append("⚠ Hotkey tap failed (permissions), restart app after granting")
        }
        statusMenuItem.title = parts.joined(separator: "  ·  ")
    }

    private func rebuildCameraSubmenu() {
        cameraSubmenu.removeAllItems()
        for device in CameraCapture.availableDevices() {
            let item = NSMenuItem(
                title: device.localizedName,
                action: #selector(selectCamera(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = device
            item.state = device.localizedName == camera.currentDeviceName ? .on : .off
            cameraSubmenu.addItem(item)
        }
        if cameraSubmenu.items.isEmpty {
            let item = NSMenuItem(title: "No cameras found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            cameraSubmenu.addItem(item)
        }
    }

    private static let smoothingPresets: [(name: String, minCutoff: Double, beta: Double, fixation: Double)] = [
        ("Responsive", 0.60, 0.080, 20),
        ("Balanced", 0.35, 0.050, 28),
        ("Steady", 0.18, 0.030, 36),
        ("Very Steady", 0.10, 0.015, 46),
    ]

    private func rebuildSmoothingSubmenu() {
        smoothingSubmenu.removeAllItems()
        for (index, preset) in Self.smoothingPresets.enumerated() {
            let item = NSMenuItem(title: preset.name, action: #selector(selectSmoothing(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = abs(config.smoothing.minCutoff - preset.minCutoff) < 0.001 ? .on : .off
            smoothingSubmenu.addItem(item)
        }
    }

    private func rebuildCalibrateSubmenu() {
        calibrateSubmenu.removeAllItems()
        for screen in NSScreen.screens {
            let calibrated = store.screens[screen.localizedName] != nil
            var title = "\(screen.localizedName) — \(Int(screen.frame.width))×\(Int(screen.frame.height))"
            if calibrated { title += "  (recalibrate)" }
            let item = NSMenuItem(title: title, action: #selector(selectCalibrationScreen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = screen
            item.state = calibrated ? .on : .off
            calibrateSubmenu.addItem(item)
        }
    }

    // MARK: - Actions

    private func setTracking(_ enabled: Bool) {
        trackingEnabled = enabled
        trackingMenuItem.state = enabled ? .on : .off
        statusItem.button?.image = NSImage(
            systemSymbolName: enabled ? "eye" : "eye.slash",
            accessibilityDescription: "Saccade"
        )
        if !enabled { clearGaze() }
    }

    @objc private func toggleTracking() {
        setTracking(!trackingEnabled)
    }

    @objc private func toggleRefinement() {
        if pursuit.isActive {
            endPursuit(showReport: true)
            return
        }
        let refinable = store.screens.contains { !($0.value.gridSamples ?? []).isEmpty }
        guard refinable else {
            showAlert(
                title: "No refinable screens",
                text: "Cursor refinement refits from the dot-grid samples, and none are saved yet. Run Calibrate Screen once (grid samples now persist), then refine."
            )
            return
        }
        pursuitBaselineRMS = store.screens.mapValues { $0.model.rmsErrorPixels }
        pursuitCollected = [:]
        pursuitSkipped = []
        pursuitPendingRefit = [:]
        pursuit.start()
        showAlert(
            title: "Cursor refinement on",
            text: "Work normally, but keep your eyes on the pointer while it moves and right after it stops. Those frames become extra calibration samples and the model refits as they accumulate. Pick \u{201C}Stop Cursor Refinement\u{201D} in the menu when done."
        )
    }

    @objc private func selectCalibrationScreen(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen,
              !calibration.isActive
        else { return }
        endPursuit(showReport: false)
        checkAccessibility()
        clearGaze()
        calibratingScreenName = screen.localizedName
        overlay.hide()
        calibration.begin(on: screen)
    }

    @objc private func selectSmoothing(_ sender: NSMenuItem) {
        let preset = Self.smoothingPresets[sender.tag]
        config.smoothing = SmoothingConfig(
            minCutoff: preset.minCutoff,
            beta: preset.beta,
            dCutoff: 1.0,
            fixationRadius: preset.fixation
        )
        config.save()
        rebuildFilters()
        fixationAnchor = nil
    }

    @objc private func toggleCameraPower() {
        let turnOn = !camera.isRunning
        camera.setRunning(turnOn)
        if !turnOn { clearGaze() }
    }

    @objc private func toggleGazeDot() {
        config.showGazeDot.toggle()
        config.save()
        gazeDotMenuItem.state = config.showGazeDot ? .on : .off
    }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AVCaptureDevice else { return }
        camera.switchTo(device: device)
        cameraStatus = device.localizedName
        config.cameraName = device.localizedName
        config.cameraUniqueID = device.uniqueID
        config.save()
    }

    @objc private func openConfigFolder() {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Config.directory)
    }

    @objc private func quit() {
        endPursuit(showReport: false)
        NSApp.terminate(nil)
    }

    private func showAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
