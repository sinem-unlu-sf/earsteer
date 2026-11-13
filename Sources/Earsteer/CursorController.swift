import AppKit
import ApplicationServices

/// Moves the cursor from head motion, scrolls on head tilt, and performs clicks and drags.
///
/// Head samples arrive at ~25 Hz. Each one is shaped (filter + acceleration)
/// into a pixel displacement, which a 120 Hz timer glides the cursor through.
final class CursorController {
    var shaper = MotionShaper()
    var scroller = TiltScroller()
    var tiltScroll = true
    var invertX = false
    var invertY = false
    var nodToClick = false
    /// Slow the cursor down while it's over a small button.
    var stickyButtons = true
    /// When a click lands just next to a small button, click the button instead.
    var clickAssist = true

    /// Log clicks and scrolls instead of performing them (cursor still moves).
    let dryRun: Bool

    var onLog: ((String) -> Void)?
    var onDragChange: ((Bool) -> Void)?
    var onScrollChange: ((Bool) -> Void)?
    /// Every output frame: time, cursor position, how far head control moved the
    /// cursor since the last frame, and whether something else (trackpad) moved it.
    var onFrame: ((_ now: TimeInterval, _ point: CGPoint, _ headTravel: Double, _ external: Bool) -> Void)?

    private(set) var isDragging = false
    var isScrolling: Bool { tiltScroll && scroller.isScrolling }

    // Output smoothing.
    private var timer: Timer?
    private var lastTick: TimeInterval = 0
    private var pos: CGPoint?            // sub-pixel virtual cursor position
    private var lastPosted: CGPoint?
    private var pendingX = 0.0, pendingY = 0.0
    private var drainVX = 0.0, drainVY = 0.0
    private var sampleInterval = 0.04
    private var headTravel = 0.0
    private var scrollAccum = 0.0

    // Aim tracking (for nod clicks).
    private var trail: [(time: TimeInterval, point: CGPoint)] = []
    private var lastStable: (time: TimeInterval, point: CGPoint)?

    // Sticky buttons.
    private var overSmallTarget = false
    private var axBusy = false
    private let axQueue = DispatchQueue(label: "earsteer.ax")

    // Nod detection.
    private var nodPhaseStart: TimeInterval?
    private var lastNodClick: TimeInterval = 0

    private var trustedCache: (value: Bool, checkedAt: TimeInterval) = (false, -100)

    init(dryRun: Bool) {
        self.dryRun = dryRun
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Cached Accessibility check, since the output path runs 120 times a second.
    private var trusted: Bool {
        let t = now
        if t - trustedCache.checkedAt > 2 { trustedCache = (AXIsProcessTrusted(), t) }
        return trustedCache.value
    }

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        reset()
        lastTick = now
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if isDragging { endDrag(at: currentCursorPosition()) }
        reset()
    }

    func reset() {
        shaper.reset()
        scroller.reset()
        pendingX = 0; pendingY = 0
        drainVX = 0; drainVY = 0
        pos = nil
        lastPosted = nil
        headTravel = 0
        scrollAccum = 0
        trail.removeAll()
        lastStable = nil
        nodPhaseStart = nil
    }

    // MARK: Head motion input (~25 Hz)

    func apply(_ d: HeadDelta) {
        if tiltScroll {
            let was = scroller.isScrolling
            scroller.update(roll: d.roll, dt: d.dt, now: now)
            if scroller.isScrolling != was {
                let deg = Int(scroller.tilt * 180 / .pi)
                onLog?(scroller.isScrolling
                       ? "Scroll \(scroller.velocity > 0 ? "down" : "up") (tilt \(deg)°)"
                       : "Scroll stopped")
                scrollAccum = 0
                onScrollChange?(scroller.isScrolling)
            }
            if scroller.isScrolling {
                // Freeze the pointer while scrolling; tilting drags yaw/pitch along a bit.
                shaper.reset()
                pendingX = 0; pendingY = 0
                drainVX = 0; drainVY = 0
                return
            }
        }

        let out = shaper.process(d)
        var dx = invertX ? -out.dx : out.dx
        var dy = invertY ? -out.dy : out.dy
        if stickyButtons && overSmallTarget && !isDragging {
            dx *= 0.4
            dy *= 0.4
        }

        sampleInterval = min(max(0.8 * sampleInterval + 0.2 * d.dt, 0.008), 0.1)
        pendingX += dx
        pendingY += dy
        // Spread this sample's movement evenly until the next sample arrives.
        drainVX = pendingX / sampleInterval
        drainVY = pendingY / sampleInterval

        if nodToClick { detectNod(pitchRate: d.pitchRate) }
        if stickyButtons { refreshTarget() }
    }

    // MARK: Output (120 Hz)

    private func tick() {
        let t = now
        let dt = min(t - lastTick, 0.05)
        lastTick = t

        // Did the trackpad/mouse move the cursor since our last move?
        let actual = currentCursorPosition()
        var external = false
        if let lp = lastPosted {
            if hypot(actual.x - lp.x, actual.y - lp.y) > 4 {
                external = true
                pos = actual
                lastPosted = actual
            }
        } else {
            lastPosted = actual
        }

        let mx = step(pending: pendingX, want: drainVX * dt)
        let my = step(pending: pendingY, want: drainVY * dt)
        pendingX -= mx
        pendingY -= my
        if mx != 0 || my != 0 { move(dx: mx, dy: my) }

        if isScrolling {
            scrollAccum += scroller.velocity * dt
            let whole = scrollAccum.rounded(.towardZero)
            if whole != 0 {
                scrollAccum -= whole
                postScroll(pixelsDown: whole)
            }
        }

        trackStability(at: t)
        onFrame?(t, pos ?? actual, headTravel, external)
        headTravel = 0
    }

    /// Take `want` out of `pending` without overshooting it.
    private func step(pending: Double, want: Double) -> Double {
        pending >= 0 ? min(max(want, 0), pending) : max(min(want, 0), pending)
    }

    private func move(dx: Double, dy: Double) {
        let actual = currentCursorPosition()
        var p = pos ?? actual
        p = clamp(CGPoint(x: p.x + dx, y: p.y + dy), near: actual)
        if let old = pos { headTravel += hypot(p.x - old.x, p.y - old.y) } else { headTravel += hypot(dx, dy) }
        pos = p
        lastPosted = p
        postMove(to: p)
    }

    /// Remembers the most recent point where the cursor was held still.
    private func trackStability(at t: TimeInterval) {
        let p = currentCursorPosition()
        trail.append((t, p))
        while let first = trail.first, t - first.time > 1.5 { trail.removeFirst() }

        guard let oldest = trail.first, t - oldest.time >= 0.1 else { return }
        var maxDist = 0.0
        for entry in trail.reversed() {
            if t - entry.time > 0.12 { break }
            maxDist = max(maxDist, hypot(entry.point.x - p.x, entry.point.y - p.y))
        }
        if maxDist < 3 { lastStable = (t, p) }
    }

    private func aimPoint() -> CGPoint {
        let current = currentCursorPosition()
        guard let s = lastStable, now - s.time < 0.9,
              hypot(s.point.x - current.x, s.point.y - current.y) < 40 else { return current }
        return s.point
    }

    // MARK: Clicks and drags

    /// Left click (`count` 2 = double-click) at `p`, snapped onto a nearby small button.
    func click(at point: CGPoint, count: Int = 1) {
        if isDragging {
            endDrag(at: point)
            return
        }
        let p = assisted(point)
        jump(to: p)
        for n in 1...max(count, 1) {
            postButton(down: .leftMouseDown, up: .leftMouseUp, button: .left, at: p, clickCount: Int64(n))
        }
        onLog?(count >= 2 ? "Double-click at \(fmt(p))" : "Click at \(fmt(p))")
    }

    func rightClick(at point: CGPoint) {
        if isDragging { endDrag(at: point) }
        let p = assisted(point)
        jump(to: p)
        postButton(down: .rightMouseDown, up: .rightMouseUp, button: .right, at: p)
        onLog?("Right-click at \(fmt(p))")
    }

    /// Pick up at `p`, or drop at `p` if already dragging.
    func toggleDrag(at point: CGPoint) {
        if isDragging {
            endDrag(at: point)
            return
        }
        let p = assisted(point)
        jump(to: p)
        postButton(down: .leftMouseDown, up: nil, button: .left, at: p)
        isDragging = true
        onLog?("Drag start at \(fmt(p))")
        onDragChange?(true)
    }

    func endDrag(at p: CGPoint) {
        guard isDragging else { return }
        jump(to: p)
        postButton(down: .leftMouseUp, up: nil, button: .left, at: p)
        isDragging = false
        onLog?("Drop at \(fmt(p))")
        onDragChange?(false)
    }

    /// Put the cursor exactly at `p` and drop any movement still gliding.
    private func jump(to p: CGPoint) {
        pendingX = 0; pendingY = 0
        drainVX = 0; drainVY = 0
        pos = p
        lastPosted = p
        postMove(to: p)
    }

    /// If `p` just misses a small button, return that button's center.
    private func assisted(_ p: CGPoint) -> CGPoint {
        guard clickAssist, trusted, AX.clickable(at: p) == nil else { return p }
        for radius in [5.0, 10.0, 16.0] {
            for i in 0..<8 {
                let a = Double(i) * .pi / 4
                let probe = CGPoint(x: p.x + radius * cos(a), y: p.y + radius * sin(a))
                if let f = AX.smallTarget(at: probe) {
                    let center = CGPoint(x: f.midX, y: f.midY)
                    onLog?("Click assist: snapped \(fmt(p)) -> \(fmt(center))")
                    return center
                }
            }
        }
        return p
    }

    private func refreshTarget() {
        guard trusted, !axBusy else { return }
        axBusy = true
        let p = currentCursorPosition()
        axQueue.async { [weak self] in
            let small = AX.smallTarget(at: p) != nil
            DispatchQueue.main.async {
                self?.overSmallTarget = small
                self?.axBusy = false
            }
        }
    }

    // MARK: Nod to click

    /// A nod is a quick downward pitch followed by a return upward within ~0.5 s.
    private func detectNod(pitchRate: Double) {
        let t = now
        let threshold = 1.6 // rad/s
        if t - lastNodClick < 0.8 { return }

        if let start = nodPhaseStart {
            if t - start > 0.5 {
                nodPhaseStart = nil
            } else if pitchRate > threshold * 0.6 {
                nodPhaseStart = nil
                lastNodClick = t
                click(at: aimPoint())
            }
        } else if pitchRate < -threshold {
            nodPhaseStart = t
        }
    }

    // MARK: Low-level events

    private func currentCursorPosition() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func postMove(to p: CGPoint) {
        if trusted,
           let ev = CGEvent(mouseEventSource: nil,
                            mouseType: isDragging ? .leftMouseDragged : .mouseMoved,
                            mouseCursorPosition: p, mouseButton: .left) {
            ev.post(tap: .cghidEventTap)
        } else {
            // Works without Accessibility, but apps won't see hover.
            CGWarpMouseCursorPosition(p)
        }
    }

    private func postScroll(pixelsDown: Double) {
        if dryRun || !trusted { return }
        // Positive wheel values scroll toward the top of the content.
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: Int32(-pixelsDown), wheel2: 0, wheel3: 0) else { return }
        ev.post(tap: .cghidEventTap)
    }

    private func postButton(down: CGEventType, up: CGEventType?, button: CGMouseButton,
                            at p: CGPoint, clickCount: Int64 = 1) {
        if dryRun {
            onLog?("[dry run] would post \(down.rawValue)\(up.map { "+\($0.rawValue)" } ?? "") at \(fmt(p))")
            return
        }
        guard trusted else {
            onLog?("Can't click: Earsteer needs Accessibility permission")
            return
        }
        for type in [down, up].compactMap({ $0 }) {
            guard let ev = CGEvent(mouseEventSource: nil, mouseType: type,
                                   mouseCursorPosition: p, mouseButton: button) else { continue }
            ev.setIntegerValueField(.mouseEventClickState, value: clickCount)
            ev.post(tap: .cghidEventTap)
        }
    }

    /// Keep the cursor inside the display it's on (or the one the target lands in).
    private func clamp(_ target: CGPoint, near current: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let bounds = ids.map { CGDisplayBounds($0) }

        if bounds.contains(where: { $0.contains(target) }) { return target }

        let home = bounds.first(where: { $0.contains(current) }) ?? bounds.first ?? CGDisplayBounds(CGMainDisplayID())
        return CGPoint(
            x: min(max(target.x, home.minX), home.maxX - 1),
            y: min(max(target.y, home.minY), home.maxY - 1)
        )
    }

    private func fmt(_ p: CGPoint) -> String { "(\(Int(p.x)), \(Int(p.y)))" }
}
