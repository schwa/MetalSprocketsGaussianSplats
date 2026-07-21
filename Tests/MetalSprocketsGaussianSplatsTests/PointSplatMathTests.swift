#if !arch(x86_64)
import Foundation
import MetalSprocketsGaussianSplatShaders
import Testing

// Reference Li2 via power series: Li2(x) = sum x^k / k^2. Converges for x in [0, 1].
private func referenceDilog(_ x: Double) -> Double {
    var sum = 0.0
    var term = x
    for k in 1...200_000 {
        sum += term / Double(k * k)
        term *= x
        if term < 1e-12 {
            break
        }
    }
    return sum
}

@Suite("PointSplatMath")
struct PointSplatMathTests {
    @Test("dilog(1) equals pi^2/6")
    func dilogAtOne() {
        // The fit's worst error is at the x=1 endpoint (~2.5e-4 in float).
        #expect(abs(Double(gps_dilog(1.0)) - Double.pi * Double.pi / 6.0) < 5e-4)
    }

    @Test("dilog matches power series across [0, 1]")
    func dilogMatchesSeries() {
        for i in 0...100 {
            let x = Double(i) / 100.0
            let fit = Double(gps_dilog(Float(x)))
            let reference = referenceDilog(x)
            #expect(abs(fit - reference) < 5e-4, "x=\(x) fit=\(fit) ref=\(reference)")
        }
    }

    @Test("inv_dilog round-trips dilog")
    func invDilogRoundTrip() {
        for i in 1...99 {
            let x = Float(i) / 100.0
            let roundTrip = gps_inv_dilog(gps_dilog(x))
            #expect(abs(roundTrip - x) < 2e-3, "x=\(x) roundTrip=\(roundTrip)")
        }
    }

    @Test("pcg2d produces roughly uniform values")
    func pcgUniformity() {
        var seed = gps_make_seed(1, 1)
        var sum = 0.0
        let n = 100_000
        for _ in 0..<n {
            let u = gps_pcg2d(&seed)
            #expect(u.x >= 0 && u.x < 1)
            #expect(u.y >= 0 && u.y < 1)
            sum += Double(u.x) + Double(u.y)
        }
        let mean = sum / Double(2 * n)
        #expect(abs(mean - 0.5) < 0.01)
    }

    @Test("poisson sample mean and variance match lambda")
    func poissonStatistics() {
        let lambda: Float = 50.0
        var seed = gps_make_seed(7, 3)
        let n = 100_000
        var sum = 0.0
        var sumSquares = 0.0
        for _ in 0..<n {
            let k = Double(gps_poisson(&seed, lambda))
            sum += k
            sumSquares += k * k
        }
        let mean = sum / Double(n)
        let variance = sumSquares / Double(n) - mean * mean
        #expect(abs(mean - Double(lambda)) < 0.5, "mean=\(mean)")
        #expect(abs(variance - Double(lambda)) < 2.5, "variance=\(variance)")
    }

    @Test("stochastic round is unbiased and non-negative")
    func stochasticRound() {
        var seed = gps_make_seed(11, 5)
        let x: Float = 2.3
        let n = 100_000
        var sum = 0.0
        for _ in 0..<n {
            let u = gps_pcg2d(&seed).x
            let rounded = gps_stochastic_round(x, u)
            #expect(rounded == 2 || rounded == 3)
            sum += Double(rounded)
        }
        #expect(abs(sum / Double(n) - Double(x)) < 0.01)
        #expect(gps_stochastic_round(-0.5, 0.9) == 0)
    }

    @Test("box muller radius follows Rayleigh CDF")
    func boxMullerRadius() {
        var seed = gps_make_seed(13, 7)
        let n = 100_000
        let r0: Float = 1.0
        var inside = 0
        for _ in 0..<n {
            let u = gps_pcg2d(&seed)
            let sample = gps_box_muller(u.x, u.y)
            let radius = (sample.x * sample.x + sample.y * sample.y).squareRoot()
            if radius <= r0 {
                inside += 1
            }
        }
        // P(r <= r0) = 1 - exp(-r0^2 / 2)
        let expected = 1.0 - exp(-Double(r0 * r0) / 2.0)
        #expect(abs(Double(inside) / Double(n) - expected) < 0.01)
    }

    @Test("corrected box muller radius follows opacity-corrected CDF")
    func correctedBoxMullerRadius() {
        let alpha: Float = 0.9
        var seed = gps_make_seed(17, 9)
        let n = 200_000
        let radii: [Float] = [0.5, 1.0, 2.0]
        var counts = [Int](repeating: 0, count: radii.count)
        for _ in 0..<n {
            let u = gps_pcg2d(&seed)
            let sample = gps_corrected_box_muller(u.x, u.y, alpha)
            let radius = (sample.x * sample.x + sample.y * sample.y).squareRoot()
            for (i, r0) in radii.enumerated() where radius <= r0 {
                counts[i] += 1
            }
        }
        // F_alpha(r) / F_alpha(inf) = (Li2(a) - Li2(a exp(-r^2/2))) / Li2(a)
        let li2Alpha = referenceDilog(Double(alpha))
        for (i, r0) in radii.enumerated() {
            let expected = (li2Alpha - referenceDilog(Double(alpha) * exp(-Double(r0 * r0) / 2.0))) / li2Alpha
            let actual = Double(counts[i]) / Double(n)
            #expect(abs(actual - expected) < 0.01, "r0=\(r0) actual=\(actual) expected=\(expected)")
        }
    }
}
#endif
