import Foundation

/// One Euro filter (Casiez et al.): low lag when the signal moves fast,
/// strong smoothing when it is nearly still. Ideal for gaze jitter.
final class OneEuroFilter {
    private let minCutoff: Double
    private let beta: Double
    private let dCutoff: Double
    private var lastValue: Double?
    private var lastDerivative: Double = 0
    private var lastTime: Double?

    init(minCutoff: Double, beta: Double, dCutoff: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    func reset() {
        lastValue = nil
        lastDerivative = 0
        lastTime = nil
    }

    private func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    func filter(_ value: Double, timestamp: Double) -> Double {
        guard let prev = lastValue, let prevTime = lastTime, timestamp > prevTime else {
            lastValue = value
            lastTime = timestamp
            return value
        }
        let dt = timestamp - prevTime
        let rawDerivative = (value - prev) / dt
        let aD = alpha(cutoff: dCutoff, dt: dt)
        let derivative = aD * rawDerivative + (1 - aD) * lastDerivative
        let cutoff = minCutoff + beta * abs(derivative)
        let a = alpha(cutoff: cutoff, dt: dt)
        let filtered = a * value + (1 - a) * prev
        lastValue = filtered
        lastDerivative = derivative
        lastTime = timestamp
        return filtered
    }
}
