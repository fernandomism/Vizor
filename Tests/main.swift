import CoreGraphics

// Run: swiftc Sources/Gaze.swift Tests/main.swift -o /tmp/vizor-selftest && /tmp/vizor-selftest

// The fit recovers a known map from the 5 calibration points.
let features = [CGPoint(x: 0, y: 0), CGPoint(x: -0.1, y: -0.08), CGPoint(x: 0.1, y: -0.08),
                CGPoint(x: 0.1, y: 0.08), CGPoint(x: -0.1, y: 0.08)]
let truth = { (p: CGPoint) in CGPoint(x: 720 + 7000 * p.x + 300 * p.y, y: 450 - 200 * p.x + 5000 * p.y) }
let map = GazeMap(features: features, targets: features.map(truth))!
for p in [CGPoint(x: 0.05, y: -0.02), CGPoint(x: -0.07, y: 0.06)] {
    let got = map.apply(p), want = truth(p)
    precondition(abs(got.x - want.x) < 1e-6 && abs(got.y - want.y) < 1e-6, "fit is off at \(p)")
}
precondition(GazeMap(features: Array(repeating: .zero, count: 5), targets: features.map(truth)) == nil,
             "eyes that never moved must fail calibration")

// Blinks at 30 fps: eyes closed during the given time ranges.
func blinks(_ closed: [ClosedRange<Double>]) -> [Int] {
    var counter = BlinkCounter(), out: [Int] = []
    for frame in 0..<120 {
        let t = Double(frame) / 30
        if let n = counter.update(closed: closed.contains { $0.contains(t) }, at: t) { out.append(n) }
    }
    return out
}
precondition(blinks([1.0...1.15, 1.35...1.5]) == [2], "double blink")
precondition(blinks([1.0...1.15, 1.35...1.5, 1.7...1.85]) == [3], "triple blink")
precondition(blinks([1.0...1.15]) == [1], "single blink")
precondition(blinks([1.0...2.0]) == [], "eyes resting shut is not a blink")
precondition(blinks([0.5...0.6, 1.6...1.7]) == [1, 1], "blinks far apart are separate")
precondition(blinks([1.0...1.01]) == [], "one closed frame is noise")
print("selftest ok")
