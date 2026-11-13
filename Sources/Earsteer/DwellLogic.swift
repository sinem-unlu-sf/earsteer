import Foundation
import CoreGraphics

/// Dwell clicking: hold the cursor still for `dwellTime` and it fires.
///
/// After firing, it won't fire again until head control has moved the cursor
/// at least `rearmDistance`, so resting on a spot gives one click, not many.
struct DwellLogic {
    enum Output: Equatable {
        case idle
        /// 0...1 progress toward firing, at the dwell point.
        case progress(Double, CGPoint)
        case fire(CGPoint)
    }

    var dwellTime = 0.8
    /// The cursor may wander this far (points) and still count as holding still.
    var radius = 10.0
    var rearmDistance = 25.0
    /// Don't show the ring for brief pauses.
    var showDelay = 0.2

    private var anchor: CGPoint?
    private var anchorTime: TimeInterval = 0
    private(set) var armed = false
    private var travelSinceFire = 0.0

    /// Stop any dwell in progress and require fresh head movement before the next one.
    mutating func disarm() {
        armed = false
        travelSinceFire = 0
        anchor = nil
    }

    /// Call every frame with the cursor position and how far head control moved it.
    mutating func update(now: TimeInterval, point p: CGPoint, headTravel: Double) -> Output {
        travelSinceFire += headTravel
        if !armed && travelSinceFire >= rearmDistance { armed = true }

        guard let a = anchor, hypot(p.x - a.x, p.y - a.y) <= radius else {
            anchor = p
            anchorTime = now
            return .idle
        }
        guard armed else { return .idle }

        let elapsed = now - anchorTime
        if elapsed >= dwellTime {
            armed = false
            travelSinceFire = 0
            anchor = nil
            return .fire(a)
        }
        if elapsed >= showDelay {
            return .progress((elapsed - showDelay) / (dwellTime - showDelay), a)
        }
        return .idle
    }
}
