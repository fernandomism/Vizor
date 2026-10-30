import CoreGraphics
import Foundation

/// Least-squares quadratic map from gaze features to screen points. Curved because the eyes rotate,
/// so the same eye movement covers more screen toward the edges.
struct GazeMap: Codable {
    private var center: [Double]  // features are centered and scaled so the fit works on numbers near 1
    private var scale: Double
    private var cx: [Double]
    private var cy: [Double]

    /// Needs 6 or more points. Fails when the features don't spread out (the eyes never moved).
    init?(features: [CGPoint], targets: [CGPoint]) {
        guard features.count >= 6, features.count == targets.count else { return nil }
        let n = Double(features.count)
        let c = [features.reduce(0) { $0 + Double($1.x) } / n, features.reduce(0) { $0 + Double($1.y) } / n]
        let s = features.map { hypot(Double($0.x) - c[0], Double($0.y) - c[1]) }.max() ?? 0
        guard s > 1e-9 else { return nil }
        var a = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
        var bx = [Double](repeating: 0, count: 6), by = bx
        for (f, t) in zip(features, targets) {
            let r = quadratic(f, c, s)
            for i in 0..<6 {
                for j in 0..<6 { a[i][j] += r[i] * r[j] }
                bx[i] += r[i] * Double(t.x)
                by[i] += r[i] * Double(t.y)
            }
        }
        guard let cx = solve(a, bx), let cy = solve(a, by) else { return nil }
        center = c
        scale = s
        self.cx = cx
        self.cy = cy
    }

    func apply(_ p: CGPoint) -> CGPoint {
        let r = quadratic(p, center, scale)
        return CGPoint(x: zip(r, cx).reduce(0) { $0 + $1.0 * $1.1 }, y: zip(r, cy).reduce(0) { $0 + $1.0 * $1.1 })
    }
}

private func quadratic(_ p: CGPoint, _ c: [Double], _ s: Double) -> [Double] {
    let x = (Double(p.x) - c[0]) / s, y = (Double(p.y) - c[1]) / s
    return [1, x, y, x * y, x * x, y * y]
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
