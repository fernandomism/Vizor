import CoreGraphics
import Foundation

/// Least-squares affine map from gaze features to screen points: screen = A · (x, y, 1).
struct GazeMap: Codable {
    private var ax: [Double]
    private var ay: [Double]

    /// Fails when the features don't spread out (the eyes never moved), so there is nothing to fit.
    init?(features: [CGPoint], targets: [CGPoint]) {
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        var bx = [0.0, 0, 0], by = [0.0, 0, 0]
        for (f, t) in zip(features, targets) {
            let r = [Double(f.x), Double(f.y), 1]
            for i in 0..<3 {
                for j in 0..<3 { m[i][j] += r[i] * r[j] }
                bx[i] += r[i] * Double(t.x)
                by[i] += r[i] * Double(t.y)
            }
        }
        guard let ax = solve3(m, bx), let ay = solve3(m, by) else { return nil }
        self.ax = ax
        self.ay = ay
    }

    func apply(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        return CGPoint(x: ax[0] * x + ax[1] * y + ax[2], y: ay[0] * x + ay[1] * y + ay[2])
    }
}

private func det3(_ m: [[Double]]) -> Double {
    m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
        - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
        + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
}

/// Cramer's rule for the 3×3 normal equations.
private func solve3(_ m: [[Double]], _ b: [Double]) -> [Double]? {
    let d = det3(m)
    guard abs(d) > 1e-12 else { return nil }
    return (0..<3).map { c in
        det3(m.indices.map { i in m[i].indices.map { j in j == c ? b[i] : m[i][j] } }) / d
    }
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
