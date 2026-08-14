import Foundation
import CoreGraphics

/// Ridge regression from raw gaze features to a point on one screen.
/// Features get a degree-2 polynomial expansion so head pose can interact
/// with pupil position (head yaw does much of the horizontal work on an
/// ultrawide monitor).
struct GazeModel: Codable {
    var weightsX: [Double]
    var weightsY: [Double]
    /// The calibrated screen in global CG coordinates (origin top-left of the primary display).
    var screenFrame: CGRect
    /// Training RMS error in pixels — a rough accuracy expectation.
    var rmsErrorPixels: Double

    static func expand(_ raw: [Double]) -> [Double] {
        var terms: [Double] = [1]
        terms.append(contentsOf: raw)
        for i in 0..<raw.count {
            for j in i..<raw.count {
                terms.append(raw[i] * raw[j])
            }
        }
        return terms
    }

    /// Unclamped prediction in normalized screen coordinates (0..1 on the
    /// calibrated screen; values outside that range mean off-screen).
    func predictNormalized(_ raw: [Double]) -> (x: Double, y: Double) {
        let f = Self.expand(raw)
        var nx = 0.0, ny = 0.0
        for i in 0..<f.count {
            nx += weightsX[i] * f[i]
            ny += weightsY[i] * f[i]
        }
        return (nx, ny)
    }

    /// Unclamped prediction in global CG coordinates.
    func predict(_ raw: [Double]) -> CGPoint {
        let n = predictNormalized(raw)
        return CGPoint(
            x: screenFrame.minX + CGFloat(n.x) * screenFrame.width,
            y: screenFrame.minY + CGFloat(n.y) * screenFrame.height
        )
    }

    static func fit(
        samples: [(raw: [Double], target: CGPoint)],
        screenFrame: CGRect
    ) -> GazeModel? {
        guard !samples.isEmpty else { return nil }
        let X = samples.map { expand($0.raw) }
        let n = X.count
        let d = X[0].count
        guard n > d / 2 else { return nil }

        // Normal equations: A = XᵀX + λI, solved once per output axis.
        var A = [[Double]](repeating: [Double](repeating: 0, count: d), count: d)
        var bx = [Double](repeating: 0, count: d)
        var by = [Double](repeating: 0, count: d)
        let targetsX = samples.map { (Double($0.target.x) - Double(screenFrame.minX)) / Double(screenFrame.width) }
        let targetsY = samples.map { (Double($0.target.y) - Double(screenFrame.minY)) / Double(screenFrame.height) }

        for s in 0..<n {
            let row = X[s]
            for i in 0..<d {
                bx[i] += row[i] * targetsX[s]
                by[i] += row[i] * targetsY[s]
                for j in i..<d {
                    A[i][j] += row[i] * row[j]
                }
            }
        }
        for i in 0..<d {
            for j in 0..<i {
                A[i][j] = A[j][i]
            }
        }
        var trace = 0.0
        for i in 0..<d { trace += A[i][i] }
        let lambda = max(1e-8, 1e-4 * trace / Double(d))
        for i in 0..<d { A[i][i] += lambda }

        guard let wx = choleskySolve(A, bx), let wy = choleskySolve(A, by) else { return nil }

        var model = GazeModel(weightsX: wx, weightsY: wy, screenFrame: screenFrame, rmsErrorPixels: 0)
        var sumSquares = 0.0
        for s in samples {
            let p = model.predict(s.raw)
            let dx = Double(p.x - s.target.x)
            let dy = Double(p.y - s.target.y)
            sumSquares += dx * dx + dy * dy
        }
        model.rmsErrorPixels = (sumSquares / Double(n)).squareRoot()
        return model
    }

    /// Number of terms the degree-2 expansion produces for the current
    /// feature layout. Models saved with a different layout are rejected.
    static var expectedTermCount: Int {
        let n = GazeEstimator.rawFeatureCount
        return 1 + n + n * (n + 1) / 2
    }

    static func loadFromDisk() -> GazeModel? {
        guard let data = try? Data(contentsOf: Config.modelURL),
              let model = try? JSONDecoder().decode(GazeModel.self, from: data),
              model.weightsX.count == expectedTermCount,
              model.weightsY.count == expectedTermCount
        else { return nil }
        return model
    }

    func saveToDisk() {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Config.modelURL)
        }
    }
}

/// Solves A·x = b for symmetric positive definite A via Cholesky decomposition.
private func choleskySolve(_ A: [[Double]], _ b: [Double]) -> [Double]? {
    let n = A.count
    var L = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
    for i in 0..<n {
        for j in 0...i {
            var sum = A[i][j]
            for k in 0..<j { sum -= L[i][k] * L[j][k] }
            if i == j {
                guard sum > 0 else { return nil }
                L[i][j] = sum.squareRoot()
            } else {
                L[i][j] = sum / L[j][j]
            }
        }
    }
    var z = [Double](repeating: 0, count: n)
    for i in 0..<n {
        var sum = b[i]
        for k in 0..<i { sum -= L[i][k] * z[k] }
        z[i] = sum / L[i][i]
    }
    var x = [Double](repeating: 0, count: n)
    for i in stride(from: n - 1, through: 0, by: -1) {
        var sum = z[i]
        for k in (i + 1)..<n { sum -= L[k][i] * x[k] }
        x[i] = sum / L[i][i]
    }
    return x
}
