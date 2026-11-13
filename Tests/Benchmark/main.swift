// Benchmark: v0.1 pointer pipeline vs the current one, on synthetic AirPods motion (25 Hz).
import Foundation

// Deterministic Gaussian noise.
var seed: UInt64 = 42
func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
func gauss() -> Double { sqrt(-2 * log(max(rnd(), 1e-12))) * cos(2 * .pi * rnd()) }

let dt = 0.04 // 25 Hz, like AirPods
let deg = Double.pi / 180

// Old pipeline from v0.1.
struct Old {
    var vx = 0.0, frac = 0.0
    mutating func step(_ dyaw: Double) -> Double {
        var rate = dyaw / dt; if abs(rate) < 0.04 { rate = 0 }
        let dx = -rate * dt * 2200
        vx = 0.55 * vx + 0.45 * dx
        frac += vx; let m = frac.rounded(.towardZero); frac -= m; return m
    }
}

/// Feed a yaw-angle trajectory (degrees per sample) and return cursor x positions.
func run(_ yaw: [Double], noise: Double) -> (old: [Double], new: [Double]) {
    var o = Old(); var s = MotionShaper()
    var xo = 0.0, xn = 0.0, prev = 0.0
    var outO: [Double] = [], outN: [Double] = []
    for target in yaw {
        let a = target * deg + gauss() * noise * deg
        let d = HeadDelta(yaw: a - prev, pitch: gauss() * noise * deg * 0.0, pitchRate: 0, dt: dt)
        prev = a
        xo += o.step(d.yaw); xn += s.process(d).dx
        outO.append(xo); outN.append(xn)
    }
    return (outO, outN)
}

func spread(_ xs: [Double]) -> Double { (xs.max() ?? 0) - (xs.min() ?? 0) }
func pad(_ s: String) -> String { s.padding(toLength: 38, withPad: " ", startingAt: 0) }
func f(_ x: Double) -> String { String(format: "%7.1f", x) }

print(pad("scenario"), "   old px", "   new px")

// 1. Holding head still with sensor noise (0.08 deg per sample), 5 s.
let still = run(Array(repeating: 0, count: 125), noise: 0.08)
print(pad("jitter while still (wander, 5 s)"), f(spread(still.old)), "  ", f(spread(still.new)))

// 2. Slow careful aim: 2 deg over 1 s.
let slow = run((0..<50).map { min(Double($0) * 2.0 / 25, 2.0) }, noise: 0.03)
print(pad("slow aim, 2 deg of head turn"), f(abs(slow.old.last!)), "  ", f(abs(slow.new.last!)))

// 3. Medium move: 10 deg in 0.5 s.
let med = run((0..<40).map { min(Double($0) * 10.0 / 12.5, 10.0) }, noise: 0.03)
print(pad("medium move, 10 deg in 0.5 s"), f(abs(med.old.last!)), "  ", f(abs(med.new.last!)))

// 4. Fast sweep: 25 deg in 0.4 s.
let fast = run((0..<40).map { min(Double($0) * 25.0 / 10, 25.0) }, noise: 0.03)
print(pad("fast sweep, 25 deg in 0.4 s"), f(abs(fast.old.last!)), "  ", f(abs(fast.new.last!)))

// 5. Lag: how far the cursor still travels after the head stops (fast sweep).
let stopIdx = 10
print(pad("coast after a fast sweep stops"), f(abs(fast.old.last! - fast.old[stopIdx])), "  ", f(abs(fast.new.last! - fast.new[stopIdx])))
// Samples until 95% of final position reached after stopping.
func settle(_ xs: [Double]) -> Int { let fin = xs.last!; return (stopIdx..<xs.count).first { abs(xs[$0]) >= 0.95 * abs(fin) }! - stopIdx }
print(pad("ms to reach 95% after stop"), f(Double(settle(fast.old)) * 40), "  ", f(Double(settle(fast.new)) * 40))
