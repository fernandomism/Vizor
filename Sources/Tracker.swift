import AVFoundation
import CoreImage
import CoreML
import Vision

/// Camera → Apple Vision (face and eye outlines) → Google's iris model (Core ML) → pointer and clicks.
final class Tracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Each frame's look and eye openness, delivered on the main thread. Used by calibration.
    var onSample: ((Gaze, Double) -> Void)?
    /// A double (2) or triple (3) blink and where the pointer was, on the main thread. The app decides
    /// whether that clicks or opens zoom to click.
    var onBlinks: ((Int, CGPoint) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "vizor.camera")
    private let faces = VNDetectFaceLandmarksRequest()
    private let iris: VNCoreMLRequest
    // Only touched on `queue`.
    private var samples: [GazeSample] = []
    private var model: GazeModel?
    private var history: [(time: TimeInterval, gaze: Gaze)] = []  // the last second of looks
    private var errors: [Double] = []  // how far off the model was at your last clicks
    private var blinks = BlinkCounter()
    private var hold = PointerHold()
    private var aim: CGPoint?  // smoothed gaze on screen
    private var cursor: CGPoint?  // where Vizor last put the pointer
    private var eyeMovedAt = 0.0, handMovedAt = 0.0, clickedAt = 0.0
    private var correcting = false  // you're moving the pointer by hand to fix where Vizor put it
    private var zoomed = false  // the zoom view is up, so the pointer isn't over the real screen

    init(camera: AVCaptureDevice) throws {
        guard let model = Bundle.main.url(forResource: "IrisLandmark", withExtension: "mlpackage") else {
            throw NSError(domain: "Vizor", code: 1, userInfo: [NSLocalizedDescriptionKey: "The iris model is missing from the app."])
        }
        let request = VNCoreMLRequest(model: try VNCoreMLModel(for: MLModel(contentsOf: MLModel.compileModel(at: model))))
        request.imageCropAndScaleOption = .scaleFill
        iris = request
        super.init()
        // Center Stage re-frames the shot as you move, which would hide where your head really is.
        AVCaptureDevice.centerStageControlMode = .cooperative
        AVCaptureDevice.isCenterStageEnabled = false
        // More pixels on each eye means less jitter.
        let presets: [AVCaptureSession.Preset] = [.hd1920x1080, .hd1280x720]
        session.sessionPreset = presets.first { session.canSetSessionPreset($0) } ?? .high
        session.addInput(try AVCaptureDeviceInput(device: camera))
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
    }

    func start() { queue.async { self.session.startRunning() } }
    func stop() { queue.async { self.session.stopRunning() } }

    /// Steers with these calibration and learned samples; nil pauses the pointer (during calibration).
    func use(_ samples: [GazeSample]?) {
        queue.async {
            self.samples = samples ?? []
            self.model = samples.flatMap { GazeModel(samples: $0) }
            self.errors = []
            self.aim = nil
            self.cursor = nil
            self.hold = PointerHold()
            self.correcting = false
        }
    }

    /// While zoomed, where you look and where the pointer is don't match the real screen: don't learn.
    func setZoomed(_ on: Bool) { queue.async { self.zoomed = on } }

    /// A real mouse or trackpad click: you were almost certainly looking where you clicked.
    func userClicked() {
        queue.async {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.clickedAt > 0.3, let at = CGEvent(source: nil)?.location else { return }  // not Vizor's blink clicks
            self.learn(at: at)
        }
    }

    /// Adds where you were just looking as a sample for `target`, then refits and saves. On `queue`.
    private func learn(at target: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        let looks = history.filter { now - $0.time <= 0.5 }.map { $0.gaze }
        guard let model, looks.count >= 5, !zoomed else { return }
        let sample = GazeSample(gaze: medianGaze(looks), target: target, learned: true)
        errors = Array((errors + [model.error(sample)]).suffix(20))
        // Keep every calibration dot and the 80 most recent learned samples.
        samples = samples.filter { !$0.learned } + (samples.filter { $0.learned } + [sample]).suffix(80)
        self.model = GazeModel(samples: samples) ?? model
        let saved = samples, accuracy = median(errors)
        DispatchQueue.main.async {
            UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: "gazeSamples")
            UserDefaults.standard.set(accuracy, forKey: "recentAccuracy")
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        try? VNImageRequestHandler(cvPixelBuffer: pixels).perform([faces])
        guard let face = faces.results?.first, let marks = face.landmarks,
              let a = marks.leftEye, let b = marks.rightEye else { return }

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
        let box = face.boundingBox
        let look = Gaze(eye: gaze, head: [Double(box.midX), Double(box.midY), face.yaw?.doubleValue ?? 0, face.pitch?.doubleValue ?? 0])
        let now = ProcessInfo.processInfo.systemUptime
        history.append((now, look))
        history.removeAll { now - $0.time > 1 }
        DispatchQueue.main.async { [open] in self.onSample?(look, open) }

        guard let model else { return }
        let settings = UserDefaults.standard
        blinks.window = settings.double(forKey: "blinkWindow")
        let closed = open < settings.double(forKey: "blinkThreshold") * settings.double(forKey: "openBaseline")
        if let n = blinks.update(closed: closed, at: now), n == 2 || n == 3, let at = CGEvent(source: nil)?.location {
            DispatchQueue.main.async { self.onBlinks?(n, at) }
        }
        guard !blinks.pending else { return }  // hold the pointer still so the click lands where you looked

        let target = model.apply(look), keep = CGFloat(settings.double(forKey: "smoothing"))
        let aim = self.aim.map { CGPoint(x: $0.x + (1 - keep) * (target.x - $0.x), y: $0.y + (1 - keep) * (target.y - $0.y)) } ?? target
        self.aim = aim
        if let cursor, let pointer = CGEvent(source: nil)?.location, hypot(pointer.x - cursor.x, pointer.y - cursor.y) > 3 {
            hold.rest(at: aim)  // moved by hand: leave it there until the eyes really move
            self.cursor = pointer
            if now - eyeMovedAt < 3 { correcting = true }  // fixing where Vizor just put it
            handMovedAt = now
            return
        }
        if correcting, now - handMovedAt >= 0.4, let cursor {
            correcting = false
            learn(at: cursor)  // the pointer came to rest where you were looking
        }
        hold.radius = settings.double(forKey: "holdRadius")
        guard let p = hold.update(aim) else { return }  // eyes haven't really moved: keep the pointer still
        let screen = CGDisplayBounds(CGMainDisplayID())  // shortcut: main display only, calibrate per display for multi-monitor
        let moved = CGPoint(x: min(max(p.x, screen.minX), screen.maxX - 1), y: min(max(p.y, screen.minY), screen.maxY - 1))
        cursor = moved
        eyeMovedAt = now
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

    /// Left click for a double blink, right click for a triple, at `point`. The pointer then stays
    /// there until your eyes really move, and the click isn't learned from.
    func click(_ count: Int, at point: CGPoint) {
        queue.async {
            self.clickedAt = ProcessInfo.processInfo.systemUptime
            let (down, up, button): (CGEventType, CGEventType, CGMouseButton) =
                count == 2 ? (.leftMouseDown, .leftMouseUp, .left) : (.rightMouseDown, .rightMouseUp, .right)
            for type in [CGEventType.mouseMoved, down, up] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
            }
            self.cursor = point
            if let aim = self.aim { self.hold.rest(at: aim) }
        }
    }
}
