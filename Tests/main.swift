import CoreGraphics

// Run: swiftc Sources/Gaze.swift Tests/main.swift -o /tmp/vizor-selftest && /tmp/vizor-selftest

// A made-up face: screen point = curved function of the eyes + a shift from moving the head.
func look(_ x: Double, _ y: Double, headX: Double = 0.5, headY: Double = 0.5) -> Gaze {
    Gaze(eye: CGPoint(x: x, y: y), head: [headX, headY, 0, 0])
}
func truth(_ g: Gaze) -> CGPoint {
    let x = Double(g.eye.x), y = Double(g.eye.y)
    let screenX: Double = 720 + 7000 * x + 300 * y + 9000 * x * x + 3000 * (g.head[0] - 0.5)
    let screenY: Double = 450 - 200 * x + 5000 * y + 4000 * x * y + 2000 * (g.head[1] - 0.5)
    return CGPoint(x: screenX, y: screenY)
}
func gridDot(_ i: Int) -> Gaze {
    let x: Double = -0.1 + 0.2 * Double(i % 4) / 3 + 0.003 * Double(i % 5)
    let y: Double = -0.08 + 0.08 * Double(i / 4) - 0.002 * Double(i % 3)
    return look(x, y)
}
func samples(_ looks: [Gaze]) -> [GazeSample] { looks.map { GazeSample(gaze: $0, target: truth($0)) } }
func missBy(_ model: GazeModel, _ g: Gaze) -> Double {
    let got = model.apply(g), want = truth(g)
    return Double(hypot(got.x - want.x, got.y - want.y))
}
func wobble(_ i: Int, _ k: Double) -> Double { sin(Double(i) * k) }  // repeatable stand-in for randomness

// Calibration with a still head recovers the curved eye map from 12 dots.
let calibration = samples((0..<12).map(gridDot))
let calibrated = GazeModel(samples: calibration)!
for g in [look(0.05, -0.02), look(-0.07, 0.06)] { precondition(missBy(calibrated, g) < 2, "calibration fit is off") }
precondition(GazeModel(samples: samples(Array(repeating: look(0.01, 0.02), count: 12))) == nil,
             "eyes that never moved must fail calibration")
precondition(GazeModel(samples: samples((0..<12).map { look(Double(gridDot($0).eye.x), Double(gridDot($0).eye.x)) })) == nil,
             "eyes that moved along one line only can't map the whole screen")
precondition(GazeModel(samples: Array(calibration.prefix(5))) == nil, "needs at least 6 dots")

// Learned clicks with the head moving teach the model how head movement shifts the gaze.
let headMoved = look(0.02, 0.01, headX: 0.53, headY: 0.47)
let clicksWithHeadMoving = samples((0..<40).map { i in
    look(0.1 * wobble(i, 1.3), 0.08 * wobble(i, 2.1), headX: 0.5 + 0.05 * wobble(i, 0.7), headY: 0.5 + 0.05 * wobble(i, 1.9))
})
precondition(missBy(calibrated, headMoved) > 50, "a moved head should throw off calibration alone")
precondition(missBy(GazeModel(samples: calibration + clicksWithHeadMoving)!, headMoved) < 10, "learning corrects for head movement")

// Clicks correct a calibration that came out 80 points off.
let biased = calibration.map { GazeSample(gaze: $0.gaze, target: CGPoint(x: $0.target.x + 80, y: $0.target.y)) }
let clicks = samples((0..<30).map { i in look(0.1 * wobble(i, 0.9), 0.08 * wobble(i, 1.7)) })
precondition(missBy(GazeModel(samples: biased)!, look(0.03, 0.02)) > 60, "the bias shows before learning")
precondition(missBy(GazeModel(samples: biased + clicks)!, look(0.03, 0.02)) < 25, "learning from clicks fixes the bias")

// A click made while looking somewhere else is dropped instead of skewing everything.
let withOutlier = calibration + [GazeSample(gaze: gridDot(5), target: CGPoint(x: 5000, y: -3000), learned: true)]
precondition(missBy(GazeModel(samples: withOutlier)!, look(0.05, -0.02)) < 2, "an outlier must be ignored")

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
    let dx: Double = Double(i % 5) * 8 - 16
    let dy: Double = Double(i % 3) * 10 - 10
    return CGPoint(x: Double(p.x) + dx, y: Double(p.y) + dy)
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

// Zoom to click magnifies the area around the pointer without leaving the screen, and maps back exactly.
let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
precondition(ZoomRegion(around: CGPoint(x: 5, y: 5), in: screen, factor: 3).rect == CGRect(x: 0, y: 0, width: 480, height: 300),
             "zoom stays inside the top-left corner")
let nearEdge = ZoomRegion(around: CGPoint(x: 1430, y: 450), in: screen, factor: 3)
precondition(nearEdge.rect.maxX == 1440 && nearEdge.rect.midY == 450, "zoom stays inside the right edge")
let middle = ZoomRegion(around: CGPoint(x: 720, y: 450), in: screen, factor: 3)
precondition(middle.unzoom(CGPoint(x: 720, y: 450), in: screen) == CGPoint(x: 720, y: 450), "the zoomed center is the real center")
precondition(middle.unzoom(CGPoint(x: 0, y: 0), in: screen) == middle.rect.origin, "the zoomed corner is the region's corner")
precondition(middle.unzoom(CGPoint(x: 1440, y: 900), in: screen) == CGPoint(x: middle.rect.maxX, y: middle.rect.maxY),
             "the far zoomed corner is the region's far corner")
print("selftest ok")
