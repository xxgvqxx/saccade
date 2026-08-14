import Foundation
import CoreGraphics

/// What a wink triggers, per eye.
enum WinkAction: String, Codable {
    case none
    case select
    case pauseTracking

    var title: String {
        switch self {
        case .none: return "Nothing"
        case .select: return "Select Window"
        case .pauseTracking: return "Pause / Resume Tracking"
        }
    }
}

/// Per-user wink thresholds, learned by the wink calibration flow.
/// Openness values are eye-region height/width ratios in VISION's left/right
/// labeling; `userLeftIsVisionLeft` maps them to the user's own eyes (learned
/// from which region actually closed during "wink your LEFT eye", so camera
/// mirroring can never swap the two).
struct WinkCalibrationData: Codable {
    var visionLeftOpen: Double
    var visionLeftClosed: Double
    var visionRightOpen: Double
    var visionRightClosed: Double
    var userLeftIsVisionLeft: Bool
    /// Normalized openness the NON-winking eye stayed above during this
    /// user's calibration winks (minus a safety margin). During detection the
    /// companion eye must hold above this the whole time, or it's a blink.
    var companionGuard: Double
    /// Median head yaw (radians) during wink calibration. Detection pauses
    /// when the head turns far from this pose — the far eye's landmarks stop
    /// being trustworthy there. Optional: pre-existing calibrations decode
    /// with nil and gate against 0 (frontal).
    var referenceYaw: Double?
    /// Minimum normalized openness gap between the eyes for a wink, learned
    /// from this user's actual winks. Both eyes droop ~40% during a real
    /// wink, so WHICH eye dropped more (and by how much) separates winks
    /// from blinks more robustly than absolute levels. Optional as above.
    var asymEntry: Double?
}

/// Separates deliberate winks from blinks using calibrated per-eye openness.
///
/// A wink fires only when ONE eye stays closed for `minHold` seconds while
/// the other eye holds above the calibrated companion guard AND the gap
/// between the two eyes exceeds the user's calibrated wink asymmetry. Blinks
/// fail all three ways: both eyes fall together within a frame or two, the
/// gap never opens, and a whole blink is over in 100–300 ms.
///
/// Pose robustness: per-eye open baselines adapt by slow EMA (head turns and
/// lighting shift the raw height/width ratio), and detection pauses entirely
/// beyond ~20° of yaw from the calibration pose — landmark data on a
/// half-occluded far eye is unreliable enough there that no thresholding on
/// it is safe. The gaze pipeline is only ever held during an actual
/// candidate/fired episode, and the blink-suppression state has a timeout,
/// so the detector can never wedge tracking.
///
/// All state is O(1) and main-thread-only. Buffers are fixed size (3 frames
/// of smoothing per eye) — nothing here grows with runtime.
final class WinkDetector {
    enum Eye: String {
        case left, right
    }

    private enum State {
        case idle
        /// One eye closed; watching hold time, asymmetry, and the companion.
        case candidate(eye: Eye, onset: Double)
        /// Fired; waiting for the winking eye to reopen.
        case fired(eye: Eye)
        /// Blink (or failed wink) in progress; waiting for both eyes open.
        case suppressed(since: Double)
        /// Both eyes open after an event; brief dead time.
        case refractory(until: Double)
    }

    /// Normalized openness below this = closed.
    private static let closeThreshold = 0.35
    /// Normalized openness above this = open again (hysteresis gap).
    private static let reopenThreshold = 0.55
    /// One eye must stay closed this long (other eye open) to be a wink.
    private static let minHold = 0.18
    /// A candidate this old is stale (ingestion was paused mid-episode, or
    /// the eye is just resting closed) — discard rather than fire late.
    private static let maxHold = 2.0
    /// Dead time after any completed event before a new one can start.
    private static let refractoryInterval = 0.35
    /// Suppression that can't resolve (skewed baselines can keep one eye
    /// reading half-closed) exits by timeout instead of wedging.
    private static let suppressedTimeout = 1.0
    /// Asymmetry requirement when the calibration predates the field.
    private static let defaultAsymEntry = 0.35
    /// Yaw gate, radians from the calibration pose, with hysteresis.
    private static let yawGateOn = 0.35
    private static let yawGateOff = 0.25
    /// Open-baseline EMA rate (~1s time constant at 30 fps).
    private static let baselineAlpha = 0.03

    /// Fired once per wink with the user's eye and the episode ONSET time —
    /// callers that select should use gaze state from just before onset,
    /// because a closing eyelid corrupts the landmarks mid-wink.
    var onWink: ((Eye, Double) -> Void)?

    var calibration: WinkCalibrationData? {
        didSet { resetBaselines() }
    }
    var enabled = false

    private var state: State = .idle
    // Median-of-3 smoothing per eye; single-frame landmark spikes otherwise
    // read as instant blinks. Fixed capacity.
    private var recentLeft: [Double] = []
    private var recentRight: [Double] = []
    /// Consecutive candidate frames failing the companion/asymmetry checks.
    /// One frame is tolerated (landmark noise on droopy winkers); a blink
    /// keeps failing, so it still aborts within ~2 frames.
    private var invalidStreak = 0
    private var yawGated = false
    /// Open baselines that track the current pose/lighting; normalization
    /// against the frontal calibration snapshot alone misreads openness as
    /// soon as the head turns.
    private var adaptiveOpenLeft = 0.0
    private var adaptiveOpenRight = 0.0

    /// True only while an eye is actually being winked — the gaze pipeline
    /// holds its last output then, because mid-wink landmarks are corrupted.
    /// Deliberately excludes blink suppression: holding there froze tracking
    /// whenever suppression couldn't resolve.
    var isEpisodeActive: Bool {
        switch state {
        case .candidate, .fired: return true
        default: return false
        }
    }

    func reset() {
        state = .idle
        recentLeft.removeAll(keepingCapacity: true)
        recentRight.removeAll(keepingCapacity: true)
        invalidStreak = 0
        yawGated = false
        resetBaselines()
    }

    /// Feed one frame's openness (Vision labeling) and head yaw. Main thread.
    func ingest(visionLeft: Double, visionRight: Double, yaw: Double, time: Double) {
        guard enabled, let cal = calibration else { return }

        // Beyond the yaw gate the far eye's landmarks are unreliable —
        // Vision can report an "open" shape on a blinking half-occluded eye,
        // which is exactly how head-turned blinks fake winks. Pause detection
        // (never holding the pipeline) until the head comes back.
        let yawDelta = abs(yaw - (cal.referenceYaw ?? 0))
        if yawGated {
            guard yawDelta < Self.yawGateOff else { return }
            yawGated = false
        } else if yawDelta > Self.yawGateOn {
            yawGated = true
            state = .idle
            recentLeft.removeAll(keepingCapacity: true)
            recentRight.removeAll(keepingCapacity: true)
            return
        }

        recentLeft.append(visionLeft)
        recentRight.append(visionRight)
        if recentLeft.count > 3 { recentLeft.removeFirst() }
        if recentRight.count > 3 { recentRight.removeFirst() }
        let smoothLeft = Self.median(recentLeft)
        let smoothRight = Self.median(recentRight)

        // Track slow openness drift (pose, distance, lighting) while no
        // event is in flight and the eye is actually open. Clamped to a sane
        // band around the calibrated level so it can never wander off.
        switch state {
        case .idle, .refractory:
            Self.adapt(&adaptiveOpenLeft, toward: smoothLeft, calibratedOpen: cal.visionLeftOpen)
            Self.adapt(&adaptiveOpenRight, toward: smoothRight, calibratedOpen: cal.visionRightOpen)
        default:
            break
        }

        let visionLeftN = Self.normalize(smoothLeft, open: adaptiveOpenLeft, closed: cal.visionLeftClosed)
        let visionRightN = Self.normalize(smoothRight, open: adaptiveOpenRight, closed: cal.visionRightClosed)
        let leftN = cal.userLeftIsVisionLeft ? visionLeftN : visionRightN
        let rightN = cal.userLeftIsVisionLeft ? visionRightN : visionLeftN

        step(
            leftN: leftN, rightN: rightN,
            guardLevel: cal.companionGuard,
            asymEntry: cal.asymEntry ?? Self.defaultAsymEntry,
            time: time
        )
    }

    /// Lost the face entirely — abandon any in-flight episode.
    func ingestNoFace() {
        state = .idle
        recentLeft.removeAll(keepingCapacity: true)
        recentRight.removeAll(keepingCapacity: true)
        invalidStreak = 0
    }

    private func step(leftN: Double, rightN: Double, guardLevel: Double, asymEntry: Double, time: Double) {
        let leftClosed = leftN < Self.closeThreshold
        let rightClosed = rightN < Self.closeThreshold

        switch state {
        case .idle:
            if leftClosed && rightClosed {
                state = .suppressed(since: time)
            } else if leftClosed, rightN >= guardLevel, rightN - leftN >= asymEntry {
                invalidStreak = 0
                state = .candidate(eye: .left, onset: time)
            } else if rightClosed, leftN >= guardLevel, leftN - rightN >= asymEntry {
                invalidStreak = 0
                state = .candidate(eye: .right, onset: time)
            }

        case .candidate(let eye, let onset):
            let winkN = eye == .left ? leftN : rightN
            let companionN = eye == .left ? rightN : leftN
            let frameValid = companionN >= guardLevel && companionN - winkN >= asymEntry
            invalidStreak = frameValid ? 0 : invalidStreak + 1
            if time - onset > Self.maxHold || invalidStreak >= 2 {
                state = .suppressed(since: time)
            } else if winkN > Self.reopenThreshold {
                // Reopened before the hold requirement: noise or half-blink.
                state = .refractory(until: time + Self.refractoryInterval)
            } else if frameValid, time - onset >= Self.minHold {
                state = .fired(eye: eye)
                onWink?(eye, onset)
            }

        case .fired(let eye):
            let winkN = eye == .left ? leftN : rightN
            if winkN > Self.reopenThreshold {
                state = .refractory(until: time + Self.refractoryInterval)
            }

        case .suppressed(let since):
            if (leftN > Self.reopenThreshold && rightN > Self.reopenThreshold)
                || time - since > Self.suppressedTimeout {
                state = .refractory(until: time + Self.refractoryInterval)
            }

        case .refractory(let until):
            if time >= until {
                state = .idle
            }
        }
    }

    private func resetBaselines() {
        adaptiveOpenLeft = calibration?.visionLeftOpen ?? 0
        adaptiveOpenRight = calibration?.visionRightOpen ?? 0
    }

    private static func adapt(_ baseline: inout Double, toward value: Double, calibratedOpen: Double) {
        // Only follow open-ish readings (vs the CALIBRATED reference, so a
        // drifted-high baseline can still come back down); a closing eye must
        // not drag the baseline down and hide its own closure.
        guard value > calibratedOpen * 0.55 else { return }
        let updated = baseline + (value - baseline) * baselineAlpha
        baseline = min(max(updated, calibratedOpen * 0.6), calibratedOpen * 1.6)
    }

    private static func normalize(_ value: Double, open: Double, closed: Double) -> Double {
        let range = open - closed
        guard range > 0.001 else { return 1 }
        return min(max((value - closed) / range, 0), 1)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
