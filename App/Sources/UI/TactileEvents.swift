import CoreHaptics
import UIKit

/// 3.5.12 (the owner: «ты Haptics убрал практически из приложения»): the touch
/// language of 1.5.0 (`HapticManager`) — every touch anywhere answers as it lands
/// and as it lifts, and the connection, the switches and the tabs have patterns
/// of their own. The same pulses (time, intensity, sharpness) as 1.5.0.
///
/// Patterns play on their own queue, never on the main thread: a cold haptic
/// engine once cost the main thread frames mid-swipe (3.1.7).
enum Tactile {
    enum Event: Hashable {
        case touchDown, touchUp, navigation, toggleOn, toggleOff
        case vpnConnecting, vpnConnected, vpnDisconnecting, vpnDisconnected, vpnSwitched, error
    }

    private typealias Pulse = (time: TimeInterval, intensity: Float, sharpness: Float)

    private static let queue = DispatchQueue(label: "personaltunnel.haptics", qos: .userInitiated)
    /// Owned by `queue`.
    private static var engine: CHHapticEngine?
    private static var engineFailed = false
    private static let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    // Main thread only.
    private static var lastPlayed: [Event: CFTimeInterval] = [:]
    private static var lastAny: CFTimeInterval = 0
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let notice = UINotificationFeedbackGenerator()

    static func play(_ event: Event) {
        guard Prefs.hapticsEnabled else { return }
        // As 1.5.0: the same event at most every 0.12 s, any two 35 ms apart
        // (a touch's own pulses excepted).
        let now = CACurrentMediaTime()
        guard now - (lastPlayed[event] ?? 0) >= 0.12 else { return }
        let touch = event == .touchDown || event == .touchUp
        if !touch, now - lastAny < 0.035 { return }
        lastPlayed[event] = now
        lastAny = now
        let pulses: [Pulse]
        let fallback: () -> Void
        switch event {
        case .touchDown: pulses = [(0, 0.18, 0.12), (0.055, 0.30, 0.28)]; fallback = { soft.impactOccurred(intensity: 0.30) }
        case .touchUp: pulses = []; fallback = { light.impactOccurred(intensity: 0.20) }
        case .navigation: pulses = []; fallback = { light.impactOccurred(intensity: 0.48) }
        case .toggleOn: pulses = [(0, 0.32, 0.30), (0.065, 0.58, 0.62)]; fallback = { light.impactOccurred(intensity: 0.62) }
        case .toggleOff: pulses = [(0, 0.50, 0.55), (0.075, 0.24, 0.25)]; fallback = { soft.impactOccurred(intensity: 0.45) }
        case .vpnConnecting: pulses = [(0, 0.30, 0.24), (0.11, 0.44, 0.36), (0.22, 0.60, 0.48)]; fallback = { medium.impactOccurred(intensity: 0.55) }
        case .vpnConnected: pulses = [(0, 0.42, 0.35), (0.08, 0.70, 0.66), (0.18, 0.92, 0.82)]; fallback = { notice.notificationOccurred(.success) }
        case .vpnDisconnecting: pulses = [(0, 0.58, 0.58), (0.105, 0.36, 0.34)]; fallback = { medium.impactOccurred(intensity: 0.48) }
        case .vpnDisconnected: pulses = [(0, 0.66, 0.72), (0.12, 0.24, 0.28)]; fallback = { soft.impactOccurred(intensity: 0.58) }
        case .vpnSwitched: pulses = [(0, 0.44, 0.38), (0.085, 0.76, 0.72)]; fallback = { notice.notificationOccurred(.success) }
        case .error: pulses = []; fallback = { notice.notificationOccurred(.error) }
        }
        // Reduce Motion: one plain pulse, as 1.5.0 did.
        guard !pulses.isEmpty, supported, !UIAccessibility.isReduceMotionEnabled else {
            fallback()
            return
        }
        queue.async {
            if playPattern(pulses) { return }
            DispatchQueue.main.async { fallback() }
        }
    }

    /// Wakes the engine ahead of the first touch.
    static func warmUp() {
        guard Prefs.hapticsEnabled, supported else { return }
        queue.async { _ = startedEngine() }
    }

    /// On `queue`.
    private static func startedEngine() -> CHHapticEngine? {
        if let engine { return engine }
        guard !engineFailed else { return nil }
        do {
            let made = try CHHapticEngine()
            made.isAutoShutdownEnabled = true
            made.playsHapticsOnly = true
            made.resetHandler = { queue.async { try? engine?.start() } }
            made.stoppedHandler = { _ in }
            try made.start()
            engine = made
            return made
        } catch {
            engineFailed = true
            return nil
        }
    }

    /// On `queue`; false: play the fallback instead.
    private static func playPattern(_ pulses: [Pulse]) -> Bool {
        guard let engine = startedEngine() else { return false }
        let events = pulses.map { pulse in
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: pulse.intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: pulse.sharpness),
            ], relativeTime: pulse.time)
        }
        do {
            try engine.start()
            let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            return false
        }
    }
}

/// 1.5.0's `hapticTouchSurface` over the whole app: the first finger down and
/// the last one up answer, wherever they are.
final class TactileWindow: UIWindow {
    private var touching = false

    override func sendEvent(_ event: UIEvent) {
        super.sendEvent(event)
        guard event.type == .touches, let touches = event.allTouches, !touches.isEmpty else { return }
        let down = touches.contains { $0.phase != .ended && $0.phase != .cancelled }
        if down, !touching {
            touching = true
            Tactile.play(.touchDown)
        } else if !down, touching {
            touching = false
            Tactile.play(.touchUp)
        }
    }
}

extension UISwitch {
    /// 1.5.0's `hapticToggle`: on and off answer differently.
    func addTactileToggle() {
        addAction(UIAction { [weak self] _ in Tactile.play(self?.isOn == true ? .toggleOn : .toggleOff) }, for: .valueChanged)
    }
}
