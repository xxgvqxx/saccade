import Foundation
import AVFoundation
import CoreVideo

/// Captures webcam frames and runs the gaze estimator on each one.
/// Callbacks fire on the internal camera queue.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "saccade.camera", qos: .userInteractive)
    private let estimator = GazeEstimator()
    private var currentInput: AVCaptureDeviceInput?

    var onFeatures: (([Double]) -> Void)?
    var onNoFace: (() -> Void)?
    private(set) var currentDeviceName: String?

    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    static func pickDevice(uniqueID: String?, preferredName: String) -> AVCaptureDevice? {
        let devices = availableDevices()
        if let uniqueID, let match = devices.first(where: { $0.uniqueID == uniqueID }) {
            return match
        }
        if !preferredName.isEmpty,
           let match = devices.first(where: {
               $0.localizedName.lowercased().contains(preferredName.lowercased())
           }) {
            return match
        }
        // Prefer any external camera over the built-in one, since the external
        // camera is usually the one mounted on the monitor being tracked.
        if let external = devices.first(where: { $0.deviceType == .external }) {
            return external
        }
        return devices.first
    }

    func start(uniqueID: String?, preferredName: String, completion: @escaping (Bool, String) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                completion(false, "Camera access denied")
                return
            }
            self.queue.async {
                guard let device = Self.pickDevice(uniqueID: uniqueID, preferredName: preferredName) else {
                    completion(false, "No camera found")
                    return
                }
                let ok = self.configure(device: device)
                completion(ok, ok ? device.localizedName : "Camera setup failed")
            }
        }
    }

    func switchTo(device: AVCaptureDevice) {
        queue.async {
            _ = self.configure(device: device)
        }
    }

    var isRunning: Bool { session.isRunning }

    /// Stops/starts capture without tearing the session down — turns the
    /// webcam (and its LED) off while the app stays in the menu bar.
    func setRunning(_ on: Bool) {
        queue.async {
            if on {
                if !self.session.isRunning { self.session.startRunning() }
            } else if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func configure(device: AVCaptureDevice) -> Bool {
        session.beginConfiguration()

        if let input = currentInput {
            session.removeInput(input)
            currentInput = nil
        }
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        currentInput = input
        currentDeviceName = device.localizedName

        // More pixels on the eyes = less landmark quantization jitter; Vision
        // handles 1080p at 30 fps fine on Apple Silicon.
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        if session.outputs.isEmpty {
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                return false
            }
            session.addOutput(output)
        }

        // startRunning must happen outside begin/commitConfiguration.
        session.commitConfiguration()
        if !session.isRunning {
            session.startRunning()
        }
        return true
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // The capture queue never goes idle while the camera runs, so GCD may
        // never drain its autorelease pool — Vision's per-frame objects would
        // accumulate for hours (multi-GB). Drain explicitly every frame.
        autoreleasepool {
            if let raw = estimator.features(from: pixelBuffer) {
                onFeatures?(raw)
            } else {
                onNoFace?()
            }
        }
    }
}
