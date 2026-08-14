import AppKit

/// One raw-feature training sample and its target point in global CG
/// coordinates. Field names are terse because thousands of these persist.
struct TrainingSample: Codable {
    var f: [Double]
    var x: Double
    var y: Double
}

/// Everything known about one screen's calibration: the fitted model plus the
/// samples behind it, kept so cursor refinement can refit with more data.
struct ScreenCalibration: Codable {
    var model: GazeModel
    /// Samples from the dot-grid calibration. Nil for calibrations saved
    /// before samples were persisted — those cannot be cursor-refined.
    var gridSamples: [TrainingSample]?
    /// Samples harvested while the user followed their own cursor.
    var pursuitSamples: [TrainingSample]?
}

/// Per-screen gaze calibrations, keyed by NSScreen.localizedName.
/// Whichever screen's model claims the current gaze owns the pointer.
struct ModelStore: Codable {
    var screens: [String: ScreenCalibration] = [:]

    static var url: URL { Config.directory.appendingPathComponent("calibrations.json") }

    static func load() -> ModelStore {
        var store = ModelStore()
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode(ModelStore.self, from: data) {
                store = decoded
            } else if let v1 = try? JSONDecoder().decode(LegacyStore.self, from: data) {
                store.screens = v1.screens.mapValues {
                    ScreenCalibration(model: $0, gridSamples: nil, pursuitSamples: nil)
                }
            }
        }
        // Drop models whose feature layout no longer matches the estimator.
        store.screens = store.screens.filter {
            $0.value.model.weightsX.count == GazeModel.expectedTermCount &&
                $0.value.model.weightsY.count == GazeModel.expectedTermCount
        }
        // Migrate the legacy single-screen calibration file.
        if store.screens.isEmpty, let legacy = GazeModel.loadFromDisk(),
           let screen = Coordinates.screen(matchingCGFrame: legacy.screenFrame) {
            store.screens[screen.localizedName] =
                ScreenCalibration(model: legacy, gridSamples: nil, pursuitSamples: nil)
            store.save()
        }
        return store
    }

    func save() {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: ModelStore.url)
        }
    }

    static func samples(fromTuples tuples: [(raw: [Double], target: CGPoint)]) -> [TrainingSample] {
        tuples.map { TrainingSample(f: $0.raw, x: Double($0.target.x), y: Double($0.target.y)) }
    }

    static func tuples(_ samples: [TrainingSample]) -> [(raw: [Double], target: CGPoint)] {
        samples.map { (raw: $0.f, target: CGPoint(x: $0.x, y: $0.y)) }
    }

    /// Pre-sample multi-screen schema: screens mapped straight to models.
    private struct LegacyStore: Codable {
        var screens: [String: GazeModel] = [:]
    }
}
