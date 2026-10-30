import AppKit
import Carbon.HIToolbox

/// Shows red dots around the screen. Look at each one and tap Space: the gaze from just before
/// the tap is saved for that spot and the dot turns green. The last 4 dots check the accuracy.
final class Calibration {
    private static let checks = 4
    private let window = KeyWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    private let dot = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
    private let label = NSTextField(labelWithString: "")
    private let tracker: Tracker
    private let done: ([GazeSample]?, Double, Double) -> Void
    private var spots: [CGPoint] = []
    private var saved: [GazeSample] = []
    private var errors: [Double] = []
    private var model: GazeModel?
    private var open: [Double] = []
    private var recent: [(time: TimeInterval, gaze: Gaze, open: Double)] = []
    private var monitor: Any?
    private var saving = false

    /// `done` gets the samples (nil if it failed), the open-eye baseline used to detect blinks,
    /// and the average miss on the check dots in points.
    init(tracker: Tracker, done: @escaping ([GazeSample]?, Double, Double) -> Void) {
        self.tracker = tracker
        self.done = done
        let frame = NSScreen.screens[0].frame  // shortcut: main display only, calibrate per display for multi-monitor
        // One random spot in each cell of a 4×3 grid: center, halfway and edges, in shuffled order.
        let area = frame.insetBy(dx: 30, dy: 30), cols = 4, rows = 3
        let cellWidth = area.width / CGFloat(cols), cellHeight = area.height / CGFloat(rows)
        spots = (0..<cols * rows).map { i -> CGPoint in
            let x = area.minX + (CGFloat(i % cols) + CGFloat.random(in: 0.1...0.9)) * cellWidth
            let y = area.minY + (CGFloat(i / cols) + CGFloat.random(in: 0.1...0.9)) * cellHeight
            return CGPoint(x: x, y: y)
        }.shuffled()
        spots += (0..<Calibration.checks).map { _ in
            CGPoint(x: CGFloat.random(in: area.minX...area.maxX), y: CGFloat.random(in: area.minY...area.maxY))
        }

        window.setFrame(frame, display: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        label.font = .systemFont(ofSize: 22)
        label.textColor = .white
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 15
        window.contentView?.addSubview(label)
        window.contentView?.addSubview(dot)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        tracker.onSample = { [weak self] gaze, open in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.recent.append((now, gaze, open))
            self.recent.removeAll { now - $0.time > 1 }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Int(event.keyCode) == kVK_Space else { return event }  // Esc and other keys pass through
            if !event.isARepeat { self?.save() }
            return nil
        }
        show()
    }

    /// Closes without saving anything.
    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        tracker.onSample = nil
        window.orderOut(nil)
    }

    private var checking: Bool { saved.count >= spots.count - Calibration.checks }

    private func show() {
        let spot = spots[saved.count]
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.setFrameOrigin(NSPoint(x: spot.x - 15, y: spot.y - 15))
        if checking {
            let n = saved.count - (spots.count - Calibration.checks) + 1
            say("Checking accuracy: look at the red dot and tap Space (\(n) of \(Calibration.checks)) · Esc stops")
        } else {
            say("Look at the red dot and tap Space (\(saved.count + 1) of \(spots.count - Calibration.checks)) · Esc stops")
        }
    }

    private func save() {
        guard !saving else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let looks = recent.filter { now - $0.time <= 0.5 }  // while you were looking at the dot
        guard looks.count >= 5 else {
            return say("Couldn't see your eyes. Check the light, look at the dot and tap Space again.")
        }
        // Window points have a bottom-left origin; the pointer uses top-left.
        let spot = spots[saved.count]
        let sample = GazeSample(gaze: medianGaze(looks.map { $0.gaze }), target: CGPoint(x: spot.x, y: window.frame.height - spot.y))
        if checking, let model { errors.append(model.error(sample)) }
        saved.append(sample)
        open += looks.map { $0.open }
        if saved.count == spots.count - Calibration.checks {
            model = GazeModel(samples: saved)
            guard model != nil else { return finish() }
        }
        saving = true
        dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        say("Saved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard self.monitor != nil else { return }  // stopped with Esc meanwhile
            self.saving = false
            if self.saved.count < self.spots.count { self.show() } else { self.finish() }
        }
    }

    private func finish() {
        guard model != nil, !errors.isEmpty else {
            cancel()
            return done(nil, 0, 0)
        }
        let accuracy = errors.reduce(0, +) / Double(errors.count)
        dot.isHidden = true
        say("Done. Accuracy: about \(Int(accuracy)) points (lower is better)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard self.monitor != nil else { return }
            self.cancel()
            self.done(self.saved, median(self.open), accuracy)
        }
    }

    private func say(_ text: String) {
        label.stringValue = text
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: window.frame.midX - label.frame.width / 2, y: window.frame.midY - 60))
    }
}

/// Borderless windows don't take key presses unless they say so.
private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
