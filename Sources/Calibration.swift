import AppKit

/// Shows a dot at the center and each corner and records where the eyes point while you look at it.
final class Calibration {
    private let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    private let dot = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
    private let tracker: Tracker
    private let done: (GazeMap?, Double) -> Void
    private var spots: [CGPoint] = []
    private var features: [CGPoint] = []
    private var gaze: [CGPoint] = []
    private var open: [Double] = []
    private var collecting = false

    /// `done` gets the fitted map (nil if it failed) and the open-eye baseline used to detect blinks.
    init(tracker: Tracker, done: @escaping (GazeMap?, Double) -> Void) {
        self.tracker = tracker
        self.done = done
        let frame = NSScreen.screens[0].frame  // shortcut: main display only, calibrate per display for multi-monitor
        let m: CGFloat = 40
        spots = [CGPoint(x: frame.midX, y: frame.midY),
                 CGPoint(x: m, y: frame.maxY - m), CGPoint(x: frame.maxX - m, y: frame.maxY - m),
                 CGPoint(x: frame.maxX - m, y: m), CGPoint(x: m, y: m)]

        window.setFrame(frame, display: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        let label = NSTextField(labelWithString: "Keep your head still and look at the red dot.")
        label.font = .systemFont(ofSize: 22)
        label.textColor = .white
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: frame.midX - label.frame.width / 2, y: frame.midY - 80))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 15
        window.contentView?.addSubview(label)
        window.contentView?.addSubview(dot)
        window.orderFrontRegardless()

        tracker.onSample = { [weak self] g, o in
            guard let self, self.collecting else { return }
            self.gaze.append(g)
            self.open.append(o)
        }
        show(0)
    }

    private func show(_ i: Int) {
        guard i < spots.count else {
            // Window points have a bottom-left origin; the pointer uses top-left.
            return finish(GazeMap(features: features, targets: spots.map { CGPoint(x: $0.x, y: window.frame.height - $0.y) }))
        }
        dot.setFrameOrigin(NSPoint(x: spots[i].x - 15, y: spots[i].y - 15))
        gaze = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.collecting = true }  // let the eyes land first
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.collecting = false
            guard self.gaze.count >= 10 else { return self.finish(nil) }  // face wasn't seen
            self.features.append(CGPoint(x: median(self.gaze.map(\.x)), y: median(self.gaze.map(\.y))))
            self.show(i + 1)
        }
    }

    private func finish(_ map: GazeMap?) {
        tracker.onSample = nil
        window.orderOut(nil)
        done(map, map == nil ? 0 : median(open))
    }
}

private func median<T: Comparable>(_ values: [T]) -> T { values.sorted()[values.count / 2] }
