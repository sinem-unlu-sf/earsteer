import Foundation
import CoreGraphics

let deg = Double.pi / 180
let dt = 0.04
// Logic tests for tilt scrolling and dwell clicking, run on synthetic head motion.
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if !ok { failures += 1 }
    print(ok ? "PASS" : "FAIL", name, detail)
}

// --- Tilt scroller ---
func runRoll(_ rolls: [Double]) -> (scrolledAt: [Int], velocities: [Double]) {
    var s = TiltScroller(); var t = 0.0; var at: [Int] = []; var v: [Double] = []
    for (i, r) in rolls.enumerated() { s.update(roll: r * deg, dt: dt, now: t); t += dt; if s.isScrolling { at.append(i) }; v.append(s.velocity) }
    return (at, v)
}
// Posture drift: slowly lean 6 deg over 10 s -> no scroll.
check("slow posture drift does not scroll", runRoll((0..<250).map { Double($0) / 250 * 6 }).scrolledAt.isEmpty)
// Brief 15 deg flick for 0.08 s -> no scroll (hold time).
check("brief flick does not scroll", runRoll(Array(repeating: 0, count: 25) + [15, 15] + Array(repeating: 0, count: 25)).scrolledAt.isEmpty)
// Hold 18 deg right -> scrolls positive; then return to 0 -> stops.
let r = runRoll(Array(repeating: 0, count: 25) + Array(repeating: 18, count: 25) + Array(repeating: 0, count: 25))
check("held tilt scrolls", !r.scrolledAt.isEmpty, "starts at sample \(r.scrolledAt.first ?? -1)")
check("returning upright stops", !r.scrolledAt.contains { $0 >= 52 })
check("tilt sign maps to positive velocity", (r.velocities.max() ?? 0) > 0, String(format: "%.0f px/s at 18°", r.velocities.max() ?? 0))
let l = runRoll(Array(repeating: 0, count: 25) + Array(repeating: -30, count: 25))
check("opposite tilt scrolls the other way, faster", (l.velocities.min() ?? 0) < -(r.velocities.max() ?? 0), String(format: "%.0f px/s at -30°", l.velocities.min() ?? 0))

// --- Dwell ---
var d = DwellLogic(); var t = 0.0; var fires: [Double] = []
func feed(_ p: CGPoint, travel: Double, seconds: Double) {
    let steps = Int(seconds * 120)
    for _ in 0..<steps { if case .fire = d.update(now: t, point: p, headTravel: travel) { fires.append(t) }; t += 1.0 / 120 }
}
feed(CGPoint(x: 100, y: 100), travel: 0, seconds: 2)
check("no click without head movement first", fires.isEmpty)
for i in 0..<60 { _ = d.update(now: t, point: CGPoint(x: 100 + Double(i), y: 100), headTravel: 1); t += 1.0 / 120 }
let moved = t
feed(CGPoint(x: 160, y: 100), travel: 0, seconds: 3)
check("one click after moving then holding still", fires.count == 1, String(format: "fired %.2f s after stopping", (fires.first ?? 0) - moved))
feed(CGPoint(x: 160, y: 100), travel: 0, seconds: 3)
check("no repeat click while still", fires.count == 1)

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
