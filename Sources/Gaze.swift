import CoreGraphics
import Foundation

/// One look: where the iris sits inside the eye, plus where the head is and how it's turned.
struct Gaze: Codable {
    var eye: CGPoint
    var head: [Double]  // face center x and y as fractions of the frame, then yaw and pitch in radians
}

/// A look paired with the screen point it was at, from calibration or learned from your clicks.
struct GazeSample: Codable {
    var gaze: Gaze
    var target: CGPoint
    var learned = false
}

/// Middle value of each number across several frames, steadier than any single frame.
func medianGaze(_ looks: [Gaze]) -> Gaze {
    Gaze(eye: CGPoint(x: median(looks.map { Double($0.eye.x) }), y: median(looks.map { Double($0.eye.y) })),
         head: (0..<4).map { i in median(looks.map { $0.head[i] }) })
}

func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

/// Maps a look to a screen point with ridge regression, the way WebGazer learns from clicks.
/// Curved in the eyes (they rotate, so the same eye movement covers more screen toward the edges),
/// plus a straight-line head correction. The ridge penalty keeps the head part near zero until
/// learned samples show how moving your head shifts where you're looking.
struct GazeModel {
    private static let headScale = [0.05, 0.05, 0.1, 0.1]  // a typical head move: 5% of the frame, about 6°
    private static let eyeRidge = 1e-3, headRidge = 0.01  // per sample
    private let mean: [Double]
    private let scale: [Double]
    private let cx: [Double]
    private let cy: [Double]

    /// Needs 6 or more samples. Fails when the eyes didn't move in two directions. After a first fit,
    /// samples far off the rest (a click while looking elsewhere) are dropped and it fits again.
    init?(samples: [GazeSample]) {
        guard let first = GazeModel.fit(samples) else { return nil }
        let limit = max(3 * median(samples.map(first.error)), 40)
        let kept = samples.filter { first.error($0) <= limit }
        self = kept.count < samples.count ? GazeModel.fit(kept) ?? first : first
    }

    private init(mean: [Double], scale: [Double], cx: [Double], cy: [Double]) {
        self.mean = mean
        self.scale = scale
        self.cx = cx
        self.cy = cy
    }

    func apply(_ gaze: Gaze) -> CGPoint {
        let r = terms(gaze, mean, scale)
        return CGPoint(x: zip(r, cx).reduce(0) { $0 + $1.0 * $1.1 }, y: zip(r, cy).reduce(0) { $0 + $1.0 * $1.1 })
    }

    /// How far off the model is for this sample, in points.
    func error(_ sample: GazeSample) -> Double {
        let p = apply(sample.gaze)
        return Double(hypot(p.x - sample.target.x, p.y - sample.target.y))
    }

    private static func fit(_ samples: [GazeSample]) -> GazeModel? {
        guard samples.count >= 6 else { return nil }
        let n = Double(samples.count)
        let columns = samples.map { [Double($0.gaze.eye.x), Double($0.gaze.eye.y)] + $0.gaze.head }
        let mean: [Double] = (0..<6).map { i in columns.reduce(0.0) { $0 + $1[i] } / n }
        let sx: Double = (columns.reduce(0.0) { $0 + pow($1[0] - mean[0], 2) } / n).squareRoot()
        let sy: Double = (columns.reduce(0.0) { $0 + pow($1[1] - mean[1], 2) } / n).squareRoot()
        guard sx > 1e-9, sy > 1e-9 else { return nil }
        let r: Double = columns.reduce(0.0) { $0 + ($1[0] - mean[0]) * ($1[1] - mean[1]) } / n / (sx * sy)
        guard abs(r) < 0.99 else { return nil }  // eyes moved along one line only
        let scale = [sx, sy] + headScale
        var a = [[Double]](repeating: [Double](repeating: 0, count: 10), count: 10)
        var bx = [Double](repeating: 0, count: 10), by = bx
        for sample in samples {
            let t = terms(sample.gaze, mean, scale)
            for i in 0..<10 {
                for j in 0..<10 { a[i][j] += t[i] * t[j] }
                bx[i] += t[i] * Double(sample.target.x)
                by[i] += t[i] * Double(sample.target.y)
            }
        }
        for i in 1..<10 { a[i][i] += n * (i < 6 ? eyeRidge : headRidge) }
        guard let cx = solve(a, bx), let cy = solve(a, by) else { return nil }
        return GazeModel(mean: mean, scale: scale, cx: cx, cy: cy)
    }
}

/// Curved terms for the eyes, straight-line terms for the head, each centered and scaled near 1.
private func terms(_ gaze: Gaze, _ mean: [Double], _ scale: [Double]) -> [Double] {
    let values = [Double(gaze.eye.x), Double(gaze.eye.y)] + gaze.head
    let z = (0..<values.count).map { (values[$0] - mean[$0]) / scale[$0] }
    let x = z[0], y = z[1]
    return [1, x, y, x * y, x * x, y * y] + z[2...]
}

/// Gauss-Jordan elimination with partial pivoting; nil when the system is (nearly) singular.
private func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
    var m = zip(a, b).map { $0 + [$1] }
    let n = b.count
    for col in 0..<n {
        guard let p = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[p][col]) > 1e-9 else { return nil }
        m.swapAt(col, p)
        for row in 0..<n where row != col {
            let f = m[row][col] / m[col][col]
            for k in col...n { m[row][k] -= f * m[col][k] }
        }
    }
    return (0..<n).map { m[$0][n] / m[$0][$0] }
}

/// Counts deliberate blinks. Returns the count once the eyes have stayed open longer than `window`.
struct BlinkCounter {
    var window = 0.5
    private var count = 0
    private var closedAt: Double?
    private var lastBlink = 0.0

    /// True while the eyes are shut or more blinks may follow, so the pointer should hold still.
    var pending: Bool { count > 0 || closedAt != nil }

    mutating func update(closed: Bool, at t: Double) -> Int? {
        if closed {
            if closedAt == nil { closedAt = t }
            return nil
        }
        if let start = closedAt {
            closedAt = nil
            let length = t - start
            if length > 0.5 {
                count = 0  // eyes rested shut: not a click gesture
            } else if length >= 0.05 {  // shorter is a single noisy frame
                count += 1
                lastBlink = t
            }
            return nil
        }
        guard count > 0, t - lastBlink > window else { return nil }
        defer { count = 0 }
        return count
    }
}

/// Keeps the pointer still until the gaze really moves. Resting: gaze changes smaller than `radius`
/// (webcam noise, small flicks) are ignored. Moving: the pointer follows the gaze until it settles.
struct PointerHold {
    var radius = 50.0
    private var anchor: CGPoint?  // gaze when the pointer last came to rest
    private var last: CGPoint?
    private var moving = false
    private var settled = 0

    /// Returns where the pointer should go, or nil to leave it where it is.
    mutating func update(_ gaze: CGPoint) -> CGPoint? {
        defer { last = gaze }
        guard let anchor else {
            self.anchor = gaze
            return gaze
        }
        if !moving {
            guard distance(gaze, anchor) > radius else { return nil }
            moving = true
            settled = 0
        }
        if let last, distance(gaze, last) < radius / 5 { settled += 1 } else { settled = 0 }
        if settled >= 3 {
            moving = false
            self.anchor = gaze
        }
        return gaze
    }

    /// The pointer was put somewhere by hand: leave it there until the gaze moves.
    mutating func rest(at gaze: CGPoint) {
        anchor = gaze
        moving = false
    }
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) }

/// The part of the screen that zoom to click magnifies: the area around `center`, sized screen ÷ factor
/// and kept inside the screen. Points are in pointer coordinates (top-left origin).
struct ZoomRegion {
    let rect: CGRect
    let factor: CGFloat

    init(around center: CGPoint, in screen: CGRect, factor: CGFloat) {
        let size = CGSize(width: screen.width / factor, height: screen.height / factor)
        let x = min(max(center.x - size.width / 2, screen.minX), screen.maxX - size.width)
        let y = min(max(center.y - size.height / 2, screen.minY), screen.maxY - size.height)
        rect = CGRect(origin: CGPoint(x: x, y: y), size: size)
        self.factor = factor
    }

    /// The real spot on screen under `point` on the magnified view, which fills `screen`.
    func unzoom(_ point: CGPoint, in screen: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + (point.x - screen.minX) / factor, y: rect.minY + (point.y - screen.minY) / factor)
    }
}
