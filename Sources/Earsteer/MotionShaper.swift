import Foundation

/// One Euro filter (Casiez et al. 2012): an adaptive low-pass filter.
/// When the signal moves slowly it filters hard (kills sensor jitter);
/// when it moves fast it barely filters (no lag on big sweeps).
struct OneEuroFilter {
    var minCutoff: Double
    var beta: Double
    var dCutoff: Double

    private var xPrev: Double?
    private var dxPrev: Double = 0

    init(minCutoff: Double, beta: Double, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    mutating func filter(_ x: Double, dt: Double) -> Double {
        guard let xp = xPrev, dt > 0 else {
            xPrev = x
            return x
        }
        let dx = (x - xp) / dt
        let aD = Self.alpha(cutoff: dCutoff, dt: dt)
        let dxHat = aD * dx + (1 - aD) * dxPrev
        let cutoff = minCutoff + beta * abs(dxHat)
        let a = Self.alpha(cutoff: cutoff, dt: dt)
        let xHat = a * x + (1 - a) * xp
        xPrev = xHat
        dxPrev = dxHat
        return xHat
    }

    mutating func reset() {
        xPrev = nil
        dxPrev = 0
    }
}

/// Converts raw head-angle changes into cursor pixel displacement.
///
/// Pipeline: integrate yaw/pitch -> One Euro filter -> soft dead zone ->
/// speed-dependent gain (pointer acceleration).
struct MotionShaper {
    /// Pixels per radian when the head moves fast (big sweeps across the screen).
    var maxGain: Double = 3200
    /// Gain for slow, careful movement as a fraction of `maxGain`.
    var precisionRatio: Double = 0.15
    /// Head speeds (rad/s) where the gain ramps from precise to full.
    var slowSpeed: Double = 0.06
    var fastSpeed: Double = 0.7
    /// Speeds below this (rad/s) are subtracted away, so resting tremor reads as zero.
    var deadZone: Double = 0.01

    private var yawFilter = OneEuroFilter(minCutoff: 0.8, beta: 6.0)
    private var pitchFilter = OneEuroFilter(minCutoff: 0.8, beta: 6.0)
    private var rawYaw = 0.0
    private var rawPitch = 0.0
    private var lastYaw: Double?
    private var lastPitch: Double?

    mutating func reset() {
        yawFilter.reset()
        pitchFilter.reset()
        rawYaw = 0
        rawPitch = 0
        lastYaw = nil
        lastPitch = nil
    }

    /// Returns cursor displacement in pixels (screen coordinates, y down)
    /// and the filtered head speed in rad/s.
    mutating func process(_ d: HeadDelta) -> (dx: Double, dy: Double, speed: Double) {
        rawYaw += d.yaw
        rawPitch += d.pitch
        let fy = yawFilter.filter(rawYaw, dt: d.dt)
        let fp = pitchFilter.filter(rawPitch, dt: d.dt)
        defer {
            lastYaw = fy
            lastPitch = fp
        }
        guard let ly = lastYaw, let lp = lastPitch, d.dt > 0 else { return (0, 0, 0) }

        var dYaw = fy - ly
        var dPitch = fp - lp
        let speed = hypot(dYaw, dPitch) / d.dt

        // Soft dead zone: shrink the motion vector by `deadZone` instead of a hard cutoff,
        // so there's no jump when you start moving.
        let live = max(0, speed - deadZone)
        let scale = speed > 0 ? live / speed : 0
        dYaw *= scale
        dPitch *= scale

        let g = gain(forSpeed: live)
        // Head turns left (yaw +) -> cursor left. Head looks up (pitch +) -> cursor up.
        return (-dYaw * g, -dPitch * g, live)
    }

    func gain(forSpeed speed: Double) -> Double {
        let t = min(max((speed - slowSpeed) / (fastSpeed - slowSpeed), 0), 1)
        let eased = t * t * (3 - 2 * t)
        return maxGain * (precisionRatio + (1 - precisionRatio) * eased)
    }
}

/// Head-tilt scrolling: tilt an ear toward a shoulder to scroll, like a joystick.
/// Small tilts (normal posture) do nothing; tilting further scrolls faster.
struct TiltScroller {
    /// Tilt (radians from your neutral posture) that starts scrolling...
    var startAngle = 12.0 * .pi / 180
    /// ...and the smaller tilt that stops it again (hysteresis, so it doesn't flicker).
    var stopAngle = 8.0 * .pi / 180
    /// Tilt at which scrolling reaches full speed.
    var fullAngle = 32.0 * .pi / 180
    /// Scroll speeds in pixels per second.
    var minSpeed = 80.0
    var maxSpeed = 2500.0
    /// How long the tilt must be held past `startAngle` before scrolling starts.
    var holdTime = 0.15
    var invert = false

    private(set) var neutral: Double?
    private(set) var isScrolling = false
    /// Positive = scroll down (content moves up), in pixels per second.
    private(set) var velocity = 0.0
    private(set) var tilt = 0.0
    private var overSince: TimeInterval?

    mutating func reset() {
        neutral = nil
        isScrolling = false
        velocity = 0
        tilt = 0
        overSince = nil
    }

    mutating func update(roll: Double, dt: Double, now: TimeInterval) {
        guard let n = neutral else {
            neutral = roll
            return
        }
        tilt = Self.wrap(roll - n)
        let mag = abs(tilt)

        if isScrolling {
            if mag < stopAngle {
                isScrolling = false
                overSince = nil
            }
        } else {
            // Slowly follow your natural head posture while not scrolling.
            if mag < stopAngle { neutral = n + tilt * min(dt / 4.0, 1) }
            if mag > startAngle {
                let since = overSince ?? now
                overSince = since
                if now - since >= holdTime { isScrolling = true }
            } else {
                overSince = nil
            }
        }

        if isScrolling {
            let t = min(max((mag - stopAngle) / (fullAngle - stopAngle), 0), 1)
            let speed = minSpeed + (maxSpeed - minSpeed) * t * t
            velocity = (tilt > 0 ? speed : -speed) * (invert ? -1 : 1)
        } else {
            velocity = 0
        }
    }

    private static func wrap(_ a: Double) -> Double {
        var x = a
        while x > .pi { x -= 2 * .pi }
        while x <= -.pi { x += 2 * .pi }
        return x
    }
}
