import AppKit

/// Cursor-following refinement. While active, camera frames where the user is
/// plausibly fixating their own pointer become extra training samples. The
/// heuristics encode when that fixation assumption holds: the cursor moved
/// recently (people watch what they drag), at a speed slow enough that gaze
/// isn't leading it to the destination, and not immediately after a teleport
/// (cursor warp, jump between screens).
final class PursuitCalibrator {
    /// A single-frame jump beyond this is a warp, not a movement.
    private let teleportDistance: CGFloat = 250
    private let teleportCooldown: Double = 0.35
    /// Speed (px/s) that counts as "the cursor is moving".
    private let moveSpeedFloor: Double = 20
    /// How long after the last movement fixation on the cursor is still assumed
    /// — covers the settle right after the pointer stops.
    private let followWindow: Double = 0.7
    /// Above this speed the eyes lead the cursor toward its destination, so
    /// pairing gaze features with the current cursor position would mistrain.
    private let maxFollowSpeed: Double = 900
    /// Minimum spacing between accepted samples, so a long fixation on a
    /// stopped cursor cannot flood the sample buffer.
    private let minAcceptInterval: Double = 0.1

    private(set) var isActive = false
    private var lastCursor: CGPoint?
    private var lastFrameTime: Double = 0
    private var lastMoveTime: Double = -.infinity
    private var cooldownUntil: Double = 0
    private var lastAcceptTime: Double = 0

    func start() {
        isActive = true
        lastCursor = nil
        lastMoveTime = -.infinity
        cooldownUntil = 0
        lastAcceptTime = 0
    }

    func stop() {
        isActive = false
    }

    /// Call once per camera frame while active (main thread). Returns the
    /// cursor position in global CG coordinates when this frame should become
    /// a training sample, else nil.
    func sampleCursor(now: Double) -> CGPoint? {
        let cursorCG = Coordinates.appKitToCG(NSEvent.mouseLocation)
        defer {
            lastCursor = cursorCG
            lastFrameTime = now
        }
        guard let last = lastCursor else { return nil }

        let dist = hypot(cursorCG.x - last.x, cursorCG.y - last.y)
        if dist > teleportDistance {
            cooldownUntil = now + teleportCooldown
            lastMoveTime = -.infinity
            return nil
        }
        let dt = max(now - lastFrameTime, 1.0 / 120.0)
        let speed = Double(dist) / dt
        if speed > moveSpeedFloor {
            lastMoveTime = now
        }
        guard now >= cooldownUntil,
              now - lastMoveTime < followWindow,
              speed < maxFollowSpeed,
              now - lastAcceptTime >= minAcceptInterval
        else { return nil }

        lastAcceptTime = now
        return cursorCG
    }
}
