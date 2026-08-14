import Foundation
import Vision
import CoreVideo

/// Extracts a raw gaze feature vector from one camera frame using Vision
/// face landmarks. Returns nil when there is no face; when the face is there
/// but an eye is closed, per-eye openness is still reported (the wink signal)
/// and only the gaze features are withheld.
///
/// Feature layout (14 values):
///   0 left pupil x within left-eye bbox   (0..1)
///   1 left pupil y within left-eye bbox
///   2 right pupil x within right-eye bbox
///   3 right pupil y within right-eye bbox
///   4 head yaw (radians)
///   5 head pitch (radians)
///   6 head roll (radians)
///   7 face bbox center x (normalized image coords)
///   8 face bbox center y
///   9 face bbox width (distance proxy)
///  10 nose x offset from eye midpoint / inter-eye distance (yaw proxy)
///  11 nose y offset from eye midpoint / inter-eye distance (pitch proxy)
///  12 inter-eye distance in face space (yaw foreshortening proxy)
///  13 eye midpoint y in face space (pitch proxy)
///
/// Features 10-13 are landmark-derived head geometry: they are continuous and
/// independent of Vision's pose numbers, so head rotation stays observable to
/// the regression even where yaw/pitch/roll are coarse.
final class GazeEstimator {
    static let rawFeatureCount = 14

    /// One analyzed frame. Openness values are the eye-region height/width
    /// ratio in Vision's own left/right labeling — the wink calibrator learns
    /// which region is the user's left eye, so mirroring never matters here.
    struct FrameResult {
        /// nil while an eye is closed — pupil landmarks are garbage then.
        let gazeFeatures: [Double]?
        let visionLeftOpenness: Double
        let visionRightOpenness: Double
        /// Head yaw in radians (0 when Vision doesn't report one). The wink
        /// detector gates on this — far-eye landmarks lie under big yaw.
        let headYaw: Double
    }

    func analyze(_ pixelBuffer: CVPixelBuffer) -> FrameResult? {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let face = request.results?.first,
              let landmarks = face.landmarks,
              let leftEye = landmarks.leftEye,
              let rightEye = landmarks.rightEye,
              let leftPupilRegion = landmarks.leftPupil,
              let rightPupilRegion = landmarks.rightPupil,
              let leftPupil = leftPupilRegion.normalizedPoints.first,
              let rightPupil = rightPupilRegion.normalizedPoints.first,
              let nose = landmarks.nose, !nose.normalizedPoints.isEmpty
        else { return nil }

        let leftBox = Self.boundingBox(of: leftEye)
        let rightBox = Self.boundingBox(of: rightEye)
        guard leftBox.width > 0.001, rightBox.width > 0.001 else { return nil }

        // A closed eye collapses vertically. Openness always ships (it IS the
        // wink signal); gaze features only when both eyes are usable.
        let leftOpenness = leftBox.height / leftBox.width
        let rightOpenness = rightBox.height / rightBox.width
        guard leftOpenness > 0.12, rightOpenness > 0.12 else {
            return FrameResult(
                gazeFeatures: nil,
                visionLeftOpenness: leftOpenness,
                visionRightOpenness: rightOpenness,
                headYaw: face.yaw?.doubleValue ?? 0
            )
        }

        let lpx = (Double(leftPupil.x) - leftBox.minX) / leftBox.width
        let lpy = (Double(leftPupil.y) - leftBox.minY) / leftBox.height
        let rpx = (Double(rightPupil.x) - rightBox.minX) / rightBox.width
        let rpy = (Double(rightPupil.y) - rightBox.minY) / rightBox.height

        let yaw = face.yaw?.doubleValue ?? 0
        let pitch = face.pitch?.doubleValue ?? 0
        let roll = face.roll?.doubleValue ?? 0
        let box = face.boundingBox

        // Landmark-derived head geometry, all in face-normalized space.
        let eyeMidX = (leftBox.minX + leftBox.width / 2 + rightBox.minX + rightBox.width / 2) / 2
        let eyeMidY = (leftBox.minY + leftBox.height / 2 + rightBox.minY + rightBox.height / 2) / 2
        let interEyeDX = (rightBox.minX + rightBox.width / 2) - (leftBox.minX + leftBox.width / 2)
        let interEyeDY = (rightBox.minY + rightBox.height / 2) - (leftBox.minY + leftBox.height / 2)
        let interEye = (interEyeDX * interEyeDX + interEyeDY * interEyeDY).squareRoot()
        guard interEye > 0.01 else {
            return FrameResult(
                gazeFeatures: nil,
                visionLeftOpenness: leftOpenness,
                visionRightOpenness: rightOpenness,
                headYaw: yaw
            )
        }

        var noseX = 0.0, noseY = 0.0
        for point in nose.normalizedPoints {
            noseX += Double(point.x)
            noseY += Double(point.y)
        }
        noseX /= Double(nose.normalizedPoints.count)
        noseY /= Double(nose.normalizedPoints.count)
        let noseDX = (noseX - eyeMidX) / interEye
        let noseDY = (noseY - eyeMidY) / interEye

        return FrameResult(
            gazeFeatures: [
                lpx, lpy, rpx, rpy,
                yaw, pitch, roll,
                Double(box.midX), Double(box.midY), Double(box.width),
                noseDX, noseDY, interEye, eyeMidY,
            ],
            visionLeftOpenness: leftOpenness,
            visionRightOpenness: rightOpenness,
            headYaw: yaw
        )
    }

    private struct Box {
        var minX: Double, minY: Double, width: Double, height: Double
    }

    private static func boundingBox(of region: VNFaceLandmarkRegion2D) -> Box {
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for point in region.normalizedPoints {
            minX = min(minX, Double(point.x))
            minY = min(minY, Double(point.y))
            maxX = max(maxX, Double(point.x))
            maxY = max(maxY, Double(point.y))
        }
        return Box(minX: minX, minY: minY, width: maxX - minX, height: maxY - minY)
    }
}
