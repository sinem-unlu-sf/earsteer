import AppKit
import CoreMotion

/// Guided recording of raw AirPods motion while you tap teeth, clench, open your
/// mouth, move your head and talk. The CSV is used to design jaw-click detection.
final class JawRecorder: NSObject {
    private struct Step {
        let label: String
        let instruction: String
        let duration: Double
        /// Seconds between cues (flash + sound); 0 = no cues.
        let cueEvery: Double
    }

    private let steps: [Step] = [
        Step(label: "rest", instruction: "Face the screen and hold still.\nRelax your jaw.", duration: 6, cueEvery: 0),
        Step(label: "tap", instruction: "When the circle flashes,\ntap your teeth together ONCE.", duration: 13, cueEvery: 1.6),
        Step(label: "rest2", instruction: "Relax. Hold still.", duration: 3, cueEvery: 0),
        Step(label: "clench", instruction: "When the circle flashes,\nclench your jaw firmly for a moment, then relax.", duration: 15, cueEvery: 2.5),
        Step(label: "rest3", instruction: "Relax. Hold still.", duration: 3, cueEvery: 0),
        Step(label: "open", instruction: "When the circle flashes,\nopen your mouth wide, then close it.", duration: 13, cueEvery: 2.5),
        Step(label: "head", instruction: "Move your head around normally,\nlike you're pointing at things on screen.", duration: 8, cueEvery: 0),
        Step(label: "talk", instruction: "Talk out loud: count slowly from one to ten.", duration: 7, cueEvery: 0),
    ]

    /// HEADMOUSE_JAW_QUICK=1 shrinks every step to a tenth, for smoke-testing the recorder.
    private let timeScale = ProcessInfo.processInfo.environment["HEADMOUSE_JAW_QUICK"] == "1" ? 0.1 : 1.0

    var onLog: ((String) -> Void)?
    var onFinish: (() -> Void)?
    private(set) var isRecording = false

    private var window: NSWindow?
    private var titleLabel = NSTextField(labelWithString: "")
    private var stepLabel = NSTextField(labelWithString: "")
    private let flash = FlashView()
    private var timer: Timer?

    private var startUptime: TimeInterval = 0
    private var stepIndex = 0
    private var stepStart: TimeInterval = 0
    private var nextCue: TimeInterval = 0
    private var cueCount = 0
    private var lines: [String] = []
    private var fileURL: URL?

    func start() {
        guard !isRecording else { return }
        isRecording = true
        lines = ["kind,t,step,cue,qw,qx,qy,qz,roll,pitch,yaw,rx,ry,rz,ax,ay,az,gx,gy,gz,sensor,recv"]
        cueCount = 0
        stepIndex = -1
        showWindow()

        // 3-second countdown before the first step.
        startUptime = ProcessInfo.processInfo.systemUptime
        stepStart = startUptime + 3
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        onLog?("Jaw calibration started")
    }

    /// Feed every raw motion sample while recording.
    private var lastSampleAt: TimeInterval = -100

    func record(_ m: CMDeviceMotion) {
        lastSampleAt = ProcessInfo.processInfo.systemUptime
        guard isRecording, stepIndex >= 0, stepIndex < steps.count else { return }
        let q = m.attitude.quaternion
        let r = m.rotationRate, a = m.userAcceleration, g = m.gravity
        let sensor: String
        if #available(macOS 14.0, *) {
            switch m.sensorLocation {
            case .headphoneLeft: sensor = "left"
            case .headphoneRight: sensor = "right"
            default: sensor = "default"
            }
        } else {
            sensor = "unknown"
        }
        let f = { (x: Double) in String(format: "%.6f", x) }
        let cols: [String] = [
            "m", String(format: "%.4f", m.timestamp), steps[stepIndex].label, "\(cueCount)",
            f(q.w), f(q.x), f(q.y), f(q.z),
            f(m.attitude.roll), f(m.attitude.pitch), f(m.attitude.yaw),
            f(r.x), f(r.y), f(r.z), f(a.x), f(a.y), f(a.z), f(g.x), f(g.y), f(g.z), sensor,
            String(format: "%.4f", ProcessInfo.processInfo.systemUptime),
        ]
        lines.append(cols.joined(separator: ","))
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime

        if stepIndex < 0 {
            // Don't start until AirPods motion is actually streaming.
            if now - lastSampleAt > 0.5 {
                titleLabel.stringValue = "Waiting for AirPods motion…"
                stepLabel.stringValue = "Put both AirPods in and make sure they're connected to this Mac."
                stepStart = now + 3
                return
            }
            let left = stepStart - now
            if left > 0 {
                titleLabel.stringValue = "Get ready…"
                stepLabel.stringValue = "Starting in \(Int(ceil(left)))"
                return
            }
            beginStep(0, at: now)
        }

        let step = steps[stepIndex]
        if now - stepStart >= step.duration * timeScale {
            if stepIndex + 1 < steps.count {
                beginStep(stepIndex + 1, at: now)
            } else {
                finish()
            }
            return
        }

        if step.cueEvery > 0 && now >= nextCue {
            cueCount += 1
            // Cue rows use the same clock as motion timestamps (seconds since boot).
            lines.append("cue,\(String(format: "%.4f", now)),\(step.label),\(cueCount)" + String(repeating: ",", count: 18))
            flash.flash()
            NSSound(named: "Tink")?.play()
            nextCue = now + step.cueEvery * timeScale
        }
        let left = Int(ceil(step.duration * timeScale - (now - stepStart)))
        stepLabel.stringValue = "Step \(stepIndex + 1) of \(steps.count) · \(left) s"
    }

    private func beginStep(_ i: Int, at now: TimeInterval) {
        stepIndex = i
        stepStart = now
        nextCue = now + 1.0
        titleLabel.stringValue = steps[i].instruction
        lines.append("step,\(String(format: "%.4f", now)),\(steps[i].label),0" + String(repeating: ",", count: 18))
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        isRecording = false

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/HeadMouse-jaw-\(stamp.string(from: Date())).csv")
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            fileURL = url
            let samples = lines.filter { $0.hasPrefix("m,") }.count
            onLog?("Jaw calibration saved: \(url.path) (\(samples) samples)")
            titleLabel.stringValue = "Done! Thanks.\nRecorded \(samples) samples."
        } catch {
            onLog?("Couldn't save jaw calibration: \(error.localizedDescription)")
            titleLabel.stringValue = "Couldn't save the recording."
        }
        stepLabel.stringValue = "You can close this window."
        onFinish?()
    }

    // MARK: Window

    private func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "HeadMouse Jaw Calibration"
            w.isReleasedWhenClosed = false
            w.level = .floating

            let root = NSView(frame: w.contentRect(forFrameRect: w.frame))
            titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
            titleLabel.alignment = .center
            titleLabel.maximumNumberOfLines = 3
            titleLabel.frame = NSRect(x: 20, y: 190, width: 520, height: 90)
            stepLabel.font = .systemFont(ofSize: 14)
            stepLabel.textColor = .secondaryLabelColor
            stepLabel.alignment = .center
            stepLabel.frame = NSRect(x: 20, y: 20, width: 520, height: 24)
            flash.frame = NSRect(x: 230, y: 60, width: 100, height: 100)
            root.addSubview(titleLabel)
            root.addSubview(stepLabel)
            root.addSubview(flash)
            w.contentView = root
            window = w
        }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// A circle that lights up briefly on each cue.
private final class FlashView: NSView {
    private var litUntil: TimeInterval = 0

    func flash() {
        litUntil = ProcessInfo.processInfo.systemUptime + 0.35
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let lit = ProcessInfo.processInfo.systemUptime < litUntil
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 6, dy: 6))
        (lit ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor.withAlphaComponent(0.25)).setFill()
        path.fill()
    }
}
