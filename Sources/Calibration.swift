import AppKit
import Carbon.HIToolbox

/// Shows red dots around the screen. Look at each one and tap Space: the gaze from just before
/// the tap is saved for that spot and the dot turns green.
final class Calibration {
    private let window = KeyWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    private let dot = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
    private let label = NSTextField(labelWithString: "")
    private let tracker: Tracker
    private let done: (GazeMap?, Double) -> Void
    private var spots: [CGPoint] = []
    private var features: [CGPoint] = []
    private var open: [Double] = []
    private var samples: [(time: TimeInterval, gaze: CGPoint, open: Double)] = []
    private var monitor: Any?
    private var saving = false

    /// `done` gets the fitted map (nil if it failed) and the open-eye baseline used to detect blinks.
    init(tracker: Tracker, done: @escaping (GazeMap?, Double) -> Void) {
        self.tracker = tracker
        self.done = done
        let frame = NSScreen.screens[0].frame  // shortcut: main display only, calibrate per display for multi-monitor
        // One random spot in each cell of a 4×3 grid: center, halfway and edges, in shuffled order.
        let area = frame.insetBy(dx: 30, dy: 30), cols = 4, rows = 3
        spots = (0..<cols * rows).map { i in
            CGPoint(x: area.minX + (CGFloat(i % cols) + .random(in: 0.1...0.9)) * area.width / CGFloat(cols),
                    y: area.minY + (CGFloat(i / cols) + .random(in: 0.1...0.9)) * area.height / CGFloat(rows))
        }.shuffled()

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
            self.samples.append((now, gaze, open))
            self.samples.removeAll { now - $0.time > 1 }
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

    private func show() {
        let spot = spots[features.count]
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.setFrameOrigin(NSPoint(x: spot.x - 15, y: spot.y - 15))
        say("Look at the red dot and tap Space (\(features.count + 1) of \(spots.count)) · Esc stops")
    }

    private func save() {
        guard !saving else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let recent = samples.filter { now - $0.time <= 0.5 }  // while you were looking at the dot
        guard recent.count >= 5 else {
            return say("Couldn't see your eyes. Check the light, look at the dot and tap Space again.")
        }
        features.append(CGPoint(x: median(recent.map { $0.gaze.x }), y: median(recent.map { $0.gaze.y })))
        open += recent.map { $0.open }
        saving = true
        dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        say("Saved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard self.monitor != nil else { return }  // stopped with Esc meanwhile
            self.saving = false
            if self.features.count < self.spots.count { self.show() } else { self.finish() }
        }
    }

    private func finish() {
        // Window points have a bottom-left origin; the pointer uses top-left.
        let height = window.frame.height
        let map = GazeMap(features: features, targets: spots.map { CGPoint(x: $0.x, y: height - $0.y) })
        cancel()
        done(map, median(open))
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

private func median<T: Comparable>(_ values: [T]) -> T { values.sorted()[values.count / 2] }
