import AVFoundation
import CoreImage
import CoreML
import Vision

/// Camera → Apple Vision (face and eye outlines) → Google's iris model (Core ML) → pointer and clicks.
final class Tracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Gaze feature and eye openness for every frame, delivered on the main thread. Used by calibration.
    var onSample: ((CGPoint, Double) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "vizor.camera")
    private let faces = VNDetectFaceLandmarksRequest()
    private let iris: VNCoreMLRequest
    // Only touched on `queue`.
    private var map: GazeMap?
    private var blinks = BlinkCounter()
    private var cursor: CGPoint?

    init(camera: AVCaptureDevice) throws {
        guard let model = Bundle.main.url(forResource: "IrisLandmark", withExtension: "mlpackage") else {
            throw NSError(domain: "Vizor", code: 1, userInfo: [NSLocalizedDescriptionKey: "The iris model is missing from the app."])
        }
        let request = VNCoreMLRequest(model: try VNCoreMLModel(for: MLModel(contentsOf: MLModel.compileModel(at: model))))
        request.imageCropAndScaleOption = .scaleFill
        iris = request
        super.init()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        session.addInput(try AVCaptureDeviceInput(device: camera))
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
    }

    func start() { queue.async { self.session.startRunning() } }
    func stop() { queue.async { self.session.stopRunning() } }

    /// nil pauses the pointer (during calibration).
    func setMap(_ map: GazeMap?) { queue.async { self.map = map; self.cursor = nil } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        try? VNImageRequestHandler(cvPixelBuffer: pixels).perform([faces])
        guard let marks = faces.results?.first?.landmarks, let a = marks.leftEye, let b = marks.rightEye else { return }

        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        let image = CIImage(cvPixelBuffer: pixels).clampedToExtent()
        // Order by position in the frame: the model wants the left one as-is and the right one mirrored.
        let eyes = [a, b].map { $0.pointsInImage(imageSize: size) }.sorted { ($0.first?.x ?? 0) < ($1.first?.x ?? 0) }
        var gaze = CGPoint.zero, open = 0.0
        for (i, eye) in eyes.enumerated() {
            guard let g = irisOffset(eye, in: image, mirrored: i == 1) else { return }
            gaze.x += g.x / 2
            gaze.y += g.y / 2
            open += openness(eye) / 2
        }
        DispatchQueue.main.async { [gaze, open] in self.onSample?(gaze, open) }

        guard let map else { return }
        let settings = UserDefaults.standard
        blinks.window = settings.double(forKey: "blinkWindow")
        let closed = open < settings.double(forKey: "blinkThreshold") * settings.double(forKey: "openBaseline")
        if let n = blinks.update(closed: closed, at: CMSampleBufferGetPresentationTimeStamp(sample).seconds) { click(n) }
        guard !blinks.pending else { return }  // hold the pointer still so the click lands where you looked

        let target = map.apply(gaze), keep = CGFloat(settings.double(forKey: "smoothing"))
        let p = cursor.map { CGPoint(x: $0.x + (1 - keep) * (target.x - $0.x), y: $0.y + (1 - keep) * (target.y - $0.y)) } ?? target
        let screen = CGDisplayBounds(CGMainDisplayID())  // shortcut: main display only, calibrate per display for multi-monitor
        let moved = CGPoint(x: min(max(p.x, screen.minX), screen.maxX - 1), y: min(max(p.y, screen.minY), screen.maxY - 1))
        cursor = moved
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: moved, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Iris position relative to the eye's center, in eye widths. The crop matches MediaPipe's:
    /// a square 2.3 eye widths wide, corners level, 64×64, right eye mirrored.
    private func irisOffset(_ eye: [CGPoint], in image: CIImage, mirrored: Bool) -> CGPoint? {
        guard let l = eye.min(by: { $0.x < $1.x }), let r = eye.max(by: { $0.x < $1.x }) else { return nil }
        let width = hypot(r.x - l.x, r.y - l.y)
        guard width > 2 else { return nil }
        let scale = 64 / (2.3 * width)
        let toCrop = CGAffineTransform(translationX: -(l.x + r.x) / 2, y: -(l.y + r.y) / 2)
            .concatenating(CGAffineTransform(rotationAngle: -atan2(r.y - l.y, r.x - l.x)))
            .concatenating(CGAffineTransform(scaleX: mirrored ? -scale : scale, y: scale))
            .concatenating(CGAffineTransform(translationX: 32, y: 32))
        let crop = image.transformed(by: toCrop).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        try? VNImageRequestHandler(ciImage: crop).perform([iris])
        guard let out = (iris.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue,
              out.count >= 2 else { return nil }
        let x = out[0].doubleValue, y = out[1].doubleValue  // iris center, in crop pixels
        return CGPoint(x: ((mirrored ? 64 - x : x) - 32) / 64, y: (y - 32) / 64)
    }

    /// Eye outline height over width: drops toward 0 when the eye closes.
    private func openness(_ eye: [CGPoint]) -> Double {
        let xs = eye.map(\.x), ys = eye.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(), x1 > x0 else { return 0 }
        return Double((y1 - y0) / (x1 - x0))
    }

    private func click(_ count: Int) {
        guard count == 2 || count == 3, let at = CGEvent(source: nil)?.location else { return }
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) =
            count == 2 ? (.leftMouseDown, .leftMouseUp, .left) : (.rightMouseDown, .rightMouseUp, .right)
        for type in [down, up] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: button)?.post(tap: .cghidEventTap)
        }
    }
}
