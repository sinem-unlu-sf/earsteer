import Foundation
import CoreMotion

/// A single frame of head motion, expressed as the change since the previous frame.
struct HeadDelta {
    /// Change in yaw (turning head left/right), radians. Positive = turned left.
    let yaw: Double
    /// Change in pitch (nodding up/down), radians. Positive = looked up.
    let pitch: Double
    /// Instantaneous pitch rate, rad/s (used for nod detection).
    let pitchRate: Double
    /// Absolute head roll (tilting an ear toward a shoulder), radians. Used for scrolling.
    var roll: Double = 0
    /// Seconds since previous frame.
    let dt: Double
}

/// Wraps CMHeadphoneMotionManager and emits per-frame deltas of the head attitude.
final class HeadTracker: NSObject, CMHeadphoneMotionManagerDelegate {
    private let manager = CMHeadphoneMotionManager()
    private var lastYaw: Double?
    private var lastPitch: Double?
    private var lastTimestamp: TimeInterval?

    var onDelta: ((HeadDelta) -> Void)?
    /// Every raw sample, for calibration recording.
    var onRawMotion: ((CMDeviceMotion) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onStatus: ((String) -> Void)?

    private(set) var isConnected = false

    override init() {
        super.init()
        manager.delegate = self
    }

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    var authorizationDescription: String {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .notDetermined: return "not asked yet"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    func start() {
        guard manager.isDeviceMotionAvailable else {
            onStatus?("Headphone motion not available on this Mac")
            return
        }
        resetReference()
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                self.onStatus?("Motion error: \(error.localizedDescription)")
                return
            }
            guard let motion else { return }
            self.handle(motion)
        }
        onStatus?("Listening for AirPods motion (\(authorizationDescription))")
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        resetReference()
    }

    /// Forget the previous frame so the next one produces a zero delta
    /// (avoids a cursor jump after a pause or reconnect).
    func resetReference() {
        lastYaw = nil
        lastPitch = nil
        lastTimestamp = nil
    }

    private func handle(_ motion: CMDeviceMotion) {
        onRawMotion?(motion)
        let yaw = motion.attitude.yaw
        let pitch = motion.attitude.pitch
        let t = motion.timestamp

        defer {
            lastYaw = yaw
            lastPitch = pitch
            lastTimestamp = t
        }

        guard let ly = lastYaw, let lp = lastPitch, let lt = lastTimestamp else { return }
        let dt = t - lt
        guard dt > 0, dt < 0.5 else { return }   // drop stale frames after a stall

        let delta = HeadDelta(
            yaw: wrapAngle(yaw - ly),
            pitch: wrapAngle(pitch - lp),
            pitchRate: motion.rotationRate.x,
            roll: motion.attitude.roll,
            dt: dt
        )
        onDelta?(delta)
    }

    /// Keep an angle difference in (-pi, pi] so a wrap at +/-pi doesn't fling the cursor.
    private func wrapAngle(_ a: Double) -> Double {
        var x = a
        while x > .pi { x -= 2 * .pi }
        while x <= -.pi { x += 2 * .pi }
        return x
    }

    // MARK: CMHeadphoneMotionManagerDelegate

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        isConnected = true
        resetReference()
        onConnectionChange?(true)
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        isConnected = false
        resetReference()
        onConnectionChange?(false)
    }
}
