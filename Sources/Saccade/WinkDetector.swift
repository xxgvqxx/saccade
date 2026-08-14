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
}

/// Separates deliberate winks from blinks using calibrated per-eye openness.
///
/// A wink fires only when ONE eye stays closed for `minHold` seconds while
/// the other eye never drops below the calibrated companion guard. Blinks
/// can't pass that gate twice over: both eyes fall together within a frame or
/// two (the companion guard trips immediately), and a whole blink is over in
/// 100–300 ms — shorter than the hold requirement.
///
/// All state is O(1) and main-thread-only. Buffers are fixed size (3 frames
/// of smoothing per eye) — nothing here grows with runtime.
final class WinkDetector {
    enum Eye: String {
        case left, right
    }

    private enum State {
        case idle
        /// One eye closed; watching hold time and the companion eye.
        case candidate(eye: Eye, onset: Double)
        /// Fired; waiting for the winking eye to reopen.
        case fired(eye: Eye)
        /// Blink (or failed wink) in progress; waiting for both eyes open.
        case suppressed
        /// Both eyes open after an event; brief dead time.
        case refractory(until: Double)
    }

    /// Normalized openness below this = closed.
    private static let closeThreshold = 0.35
    /// Normalized openness above this = open again (hysteresis gap).
    private static let reopenThreshold = 0.55
    /// One eye must stay closed this long (other eye open) to be a wink.
    private static let minHold = 0.18
    /// A candidate this old is stale (ingestion was paused mid-episode, e.g.
    /// by a calibration starting) — discard rather than fire with an ancient
    /// onset.
    private static let maxHold = 2.0
    /// Dead time after any completed event before a new one can start.
    private static let refractoryInterval = 0.35

    /// Fired once per wink with the user's eye and the episode ONSET time —
    /// callers that select should use gaze state from just before onset,
    /// because a closing eyelid corrupts the landmarks mid-wink.
    var onWink: ((Eye, Double) -> Void)?

    var calibration: WinkCalibrationData?
    var enabled = false

    private var state: State = .idle
    // Median-of-3 smoothing per eye; single-frame landmark spikes otherwise
    // read as instant blinks. Fixed capacity.
    private var recentLeft: [Double] = []
    private var recentRight: [Double] = []
    /// Consecutive candidate frames with the companion eye under the guard.
    /// One frame is tolerated (landmark noise on droopy winkers); a blink
    /// keeps the companion down, so it still aborts within ~2 frames.
    private var companionLowStreak = 0

    /// True while any eye is closed or an event is settling — the gaze
    /// pipeline should hold its last output rather than chase corrupted
    /// mid-wink landmarks.
    var isEpisodeActive: Bool {
        switch state {
        case .idle, .refractory: return false
        default: return true
        }
    }

    func reset() {
        state = .idle
        recentLeft.removeAll(keepingCapacity: true)
        recentRight.removeAll(keepingCapacity: true)
    }

    /// Feed one frame's openness (Vision labeling). Main thread.
    func ingest(visionLeft: Double, visionRight: Double, time: Double) {
        guard enabled, let cal = calibration else { return }

        recentLeft.append(visionLeft)
        recentRight.append(visionRight)
        if recentLeft.count > 3 { recentLeft.removeFirst() }
        if recentRight.count > 3 { recentRight.removeFirst() }

        let visionLeftN = Self.normalize(
            Self.median(recentLeft), open: cal.visionLeftOpen, closed: cal.visionLeftClosed
        )
        let visionRightN = Self.normalize(
            Self.median(recentRight), open: cal.visionRightOpen, closed: cal.visionRightClosed
        )
        let leftN = cal.userLeftIsVisionLeft ? visionLeftN : visionRightN
        let rightN = cal.userLeftIsVisionLeft ? visionRightN : visionLeftN

        step(leftN: leftN, rightN: rightN, guardLevel: cal.companionGuard, time: time)
    }

    /// Lost the face entirely — abandon any in-flight episode.
    func ingestNoFace() {
        if isEpisodeActive { state = .suppressed }
        recentLeft.removeAll(keepingCapacity: true)
        recentRight.removeAll(keepingCapacity: true)
    }

    private func step(leftN: Double, rightN: Double, guardLevel: Double, time: Double) {
        let leftClosed = leftN < Self.closeThreshold
        let rightClosed = rightN < Self.closeThreshold

        switch state {
        case .idle:
            if leftClosed && rightClosed {
                state = .suppressed
            } else if leftClosed, rightN >= guardLevel {
                companionLowStreak = 0
                state = .candidate(eye: .left, onset: time)
            } else if rightClosed, leftN >= guardLevel {
                companionLowStreak = 0
                state = .candidate(eye: .right, onset: time)
            }

        case .candidate(let eye, let onset):
            let winkN = eye == .left ? leftN : rightN
            let companionN = eye == .left ? rightN : leftN
            companionLowStreak = companionN < guardLevel ? companionLowStreak + 1 : 0
            if time - onset > Self.maxHold {
                state = .suppressed
            } else if companionLowStreak >= 2 {
                // The other eye followed it down and stayed down — a blink.
                state = .suppressed
            } else if winkN > Self.reopenThreshold {
                // Reopened before the hold requirement: noise or half-blink.
                state = .refractory(until: time + Self.refractoryInterval)
            } else if time - onset >= Self.minHold {
                state = .fired(eye: eye)
                onWink?(eye, onset)
            }

        case .fired(let eye):
            let winkN = eye == .left ? leftN : rightN
            let companionN = eye == .left ? rightN : leftN
            if winkN > Self.reopenThreshold, companionN > Self.reopenThreshold {
                state = .refractory(until: time + Self.refractoryInterval)
            }

        case .suppressed:
            if leftN > Self.reopenThreshold, rightN > Self.reopenThreshold {
                state = .refractory(until: time + Self.refractoryInterval)
            }

        case .refractory(let until):
            if time >= until {
                state = .idle
            }
        }
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
