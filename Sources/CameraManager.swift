import AVFoundation
import CoreMedia

/// Owns the capture session. Always picks the *widest, uncropped* sensor mode and disables
/// Center Stage so the whole field of view reaches the pose tracker.
final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "bird.camera", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private(set) var device: AVCaptureDevice?
    private(set) var formatDescription = ""
    private(set) var aspect: Float = 4.0 / 3.0

    /// Called on `queue` for every frame.
    var onFrame: ((CVPixelBuffer, Double) -> Void)?
    /// Called on the main queue after the device / format changes.
    var onConfigured: (() -> Void)?

    static func availableDevices() -> [AVCaptureDevice] {
        let ds = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video, position: .unspecified)
        return ds.devices
    }

    static func defaultDevice() -> AVCaptureDevice? {
        let devices = availableDevices()
        if let saved = UserDefaults.standard.string(forKey: "cameraID"),
           let d = devices.first(where: { $0.uniqueID == saved }) {
            return d
        }
        // "The camera on my Mac": the built-in one first.
        return devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
            ?? devices.first
    }

    /// The widest mode is the landscape one that uses the most sensor area (4:3 full-sensor
    /// modes beat the 16:9 crops). Ties go to faster modes (up to 60 fps), then to the most pixels.
    static func widestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width > d.height && d.width >= 640
        }
        func score(_ f: AVCaptureDevice.Format) -> (Double, Double, Double) {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            // Taller aspect = less cropped for these cameras (sensor is ~4:3).
            let tallness = Double(d.height) / Double(d.width)
            let fps = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let area = Double(d.width) * Double(d.height)
            return (tallness.rounded(toPlaces: 2), min(fps, 60), area)
        }
        return candidates.max { a, b in
            let sa = score(a), sb = score(b)
            if sa.0 != sb.0 { return sa.0 < sb.0 }
            if sa.1 != sb.1 { return sa.1 < sb.1 }
            return sa.2 < sb.2
        }
    }

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    func start(with requested: AVCaptureDevice?) {
        guard let dev = requested ?? CameraManager.defaultDevice() else { return }
        queue.async { [self] in
            // Turn Center Stage (auto-crop / auto-zoom) off so we get the full frame.
            if #available(macOS 12.3, *) {
                AVCaptureDevice.centerStageControlMode = .app
                AVCaptureDevice.isCenterStageEnabled = false
            }
            session.beginConfiguration()
            for i in session.inputs { session.removeInput(i) }
            if let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
                session.addInput(input)
            }
            if session.outputs.isEmpty {
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) { session.addOutput(output) }
            }
            if let fmt = CameraManager.widestFormat(for: dev), (try? dev.lockForConfiguration()) != nil {
                dev.activeFormat = fmt
                let fps = fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
                let target = min(fps, 60)
                dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(target))
                dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(target))
                dev.unlockForConfiguration()
                let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                aspect = Float(d.width) / Float(d.height)
                formatDescription = "\(d.width)×\(d.height)"
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            // The session may pick its own preset format on start; insist on the wide one.
            if let fmt = CameraManager.widestFormat(for: dev), dev.activeFormat != fmt,
               (try? dev.lockForConfiguration()) != nil {
                dev.activeFormat = fmt
                dev.unlockForConfiguration()
            }
            device = dev
            let active = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
            Log.write("camera active format \(active.width)x\(active.height)")
            UserDefaults.standard.set(dev.uniqueID, forKey: "cameraID")
            Log.write("camera: \(dev.localizedName) format \(formatDescription) aspect \(aspect) centerStage \(dev.isCenterStageActive)")
            DispatchQueue.main.async { self.onConfigured?() }
        }
    }

    func stop() { queue.async { self.session.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pb, CACurrentMediaTime())
    }
}

private extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let m = pow(10.0, Double(p))
        return (self * m).rounded() / m
    }
}

/// Tiny file logger so tracking can be diagnosed without looking at camera images.
enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        return dir.appendingPathComponent("BirdGame.log")
    }()
    private static let q = DispatchQueue(label: "bird.log")
    private static var handle: FileHandle? = {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()
    static func write(_ s: String) {
        let line = String(format: "%.3f ", CACurrentMediaTime()) + s + "\n"
        q.async { handle?.write(line.data(using: .utf8)!) }
    }
}
