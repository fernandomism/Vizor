import CoreGraphics

// Run: swiftc Sources/Gaze.swift Tests/main.swift -o /tmp/vizor-selftest && /tmp/vizor-selftest

// The fit recovers a known curved map from 12 calibration dots on a jittered 4×3 grid.
let features = (0..<12).map { i in
    CGPoint(x: -0.1 + 0.2 * Double(i % 4) / 3 + 0.003 * Double(i % 5), y: -0.08 + 0.08 * Double(i / 4) - 0.002 * Double(i % 3))
}
let truth = { (p: CGPoint) in
    CGPoint(x: 720 + 7000 * p.x + 300 * p.y + 9000 * p.x * p.x, y: 450 - 200 * p.x + 5000 * p.y + 4000 * p.x * p.y)
}
let map = GazeMap(features: features, targets: features.map(truth))!
for p in [CGPoint(x: 0.05, y: -0.02), CGPoint(x: -0.07, y: 0.06)] {
    let got = map.apply(p), want = truth(p)
    precondition(abs(got.x - want.x) < 1e-4 && abs(got.y - want.y) < 1e-4, "fit is off at \(p)")
}
precondition(GazeMap(features: Array(repeating: CGPoint(x: 0.01, y: 0.02), count: 12), targets: features.map(truth)) == nil,
             "eyes that never moved must fail calibration")
precondition(GazeMap(features: features.map { CGPoint(x: $0.x, y: $0.x) }, targets: features.map(truth)) == nil,
             "eyes that moved along one line only can't map the whole screen")
precondition(GazeMap(features: Array(features.prefix(5)), targets: Array(features.prefix(5)).map(truth)) == nil,
             "a curved fit needs at least 6 dots")

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

// The pointer holds still through webcam jitter and moves only when the gaze really moves.
func jitter(around p: CGPoint, _ i: Int) -> CGPoint {
    CGPoint(x: p.x + Double(i % 5) * 8 - 16, y: p.y + Double(i % 3) * 10 - 10)
}
var hold = PointerHold()
let start = CGPoint(x: 500, y: 500), end = CGPoint(x: 800, y: 500)
precondition(hold.update(start) == start, "the first gaze places the pointer")
for i in 0..<30 { precondition(hold.update(jitter(around: start, i)) == nil, "jitter must not move the pointer") }
var pointer = start
for x in stride(from: 600.0, through: 800, by: 100) { pointer = hold.update(CGPoint(x: x, y: 500)) ?? pointer }
for _ in 0..<5 { pointer = hold.update(end) ?? pointer }
precondition(pointer == end, "a real look elsewhere moves the pointer to where the gaze settles")
for i in 0..<30 { precondition(hold.update(jitter(around: end, i)) == nil, "holds still again after settling") }
hold.rest(at: CGPoint(x: 820, y: 500))
precondition(hold.update(CGPoint(x: 840, y: 510)) == nil, "stays where it was put by hand")
precondition(hold.update(CGPoint(x: 300, y: 300)) != nil, "moves again once the eyes really move")
print("selftest ok")
