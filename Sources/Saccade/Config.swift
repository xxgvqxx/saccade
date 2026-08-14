import Foundation

/// One Euro filter parameters. These operate on normalized screen
/// coordinates (0..1), NOT pixels — beta would need to be ~1000x smaller in
/// pixel units.
struct SmoothingConfig: Codable {
    var minCutoff: Double = 0.35
    var beta: Double = 0.05
    var dCutoff: Double = 1.0
    /// Fixation stabilizer: within this many pixels of the anchor the output
    /// only drifts slowly, pinning the dot while you fixate. 0 disables.
    /// Optional so configs written before this field existed still decode.
    var fixationRadius: Double? = nil
}

struct Config: Codable {
    /// Bumped when field semantics change; old configs fail decode and reset.
    var configVersion: Int = 2
    /// Substring match against the camera's localized name (case-insensitive).
    /// Empty = no name preference (external cameras are then preferred over
    /// built-in). Note: NexiGo cameras advertise as "Full HD webcam".
    var cameraName: String = ""
    /// Exact device match, set when a camera is picked in the menu. Wins over cameraName.
    var cameraUniqueID: String? = nil
    /// localizedName of the tracked display. Nil = the widest screen.
    var trackedScreenName: String? = nil
    /// Apps that receive a synthesized click at the gaze point on jump,
    /// so the correct split/pane gets focus. Everything else gets focus + cursor warp only.
    var clickBundleIDs: [String] = ["com.mitchellh.ghostty"]
    var showGazeDot: Bool = true
    /// A new window must be under the gaze for this many consecutive frames
    /// before the highlight (and jump target) switches to it.
    var targetSwitchFrames: Int = 3
    var calibrationColumns: Int = 5
    var calibrationRows: Int = 3
    /// Grid for the head-pointing calibration pass (phase 2).
    /// Optional so configs written before this field existed still decode.
    var headPassColumns: Int? = nil
    var headPassRows: Int? = nil
    var samplesPerPoint: Int = 25
    var smoothing: SmoothingConfig = SmoothingConfig()
    // Wink control. All optional so configs written before the feature
    // existed still decode. winksEnabled defaults to false until calibrated.
    var winksEnabled: Bool? = nil
    var winkCalibration: WinkCalibrationData? = nil
    var winkLeftAction: WinkAction? = nil
    var winkRightAction: WinkAction? = nil
    /// Nil = true. Off lets a wink fully replace the Right Option key as the
    /// select trigger (⌘+Right Option pause toggle keeps working regardless).
    var optionKeySelects: Bool? = nil

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Saccade", isDirectory: true)
    }
    static var configURL: URL { directory.appendingPathComponent("config.json") }
    static var modelURL: URL { directory.appendingPathComponent("calibration.json") }

    static func load() -> Config {
        if let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(Config.self, from: data) {
            return config
        }
        let config = Config()
        config.save()
        return config
    }

    func save() {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Config.configURL)
        }
    }
}
