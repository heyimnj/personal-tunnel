import UIKit

/// One value driven by a damped spring, stepped by the display (up to 120 Hz).
///
/// Used where a motion is handed between the finger and an animation: the pager
/// of Home and the swipe of server rows. Unlike a Core Animation spring, the value
/// is real on every frame, so a touch that catches it takes it from where it is on
/// screen, and its speed carries over in both directions (finger → spring through
/// `velocity`, spring → finger because nothing jumps to a model value).
final class SpringDriver {
    /// The system's springs by response (seconds per oscillation) and damping ratio.
    struct Feel {
        var response: CGFloat
        var damping: CGFloat

        /// Settles without a bounce: closing, coming back.
        static let smooth = Feel(response: 0.38, damping: 1)
        /// A hint of overshoot as it lands: opening.
        static let snappy = Feel(response: 0.36, damping: 0.84)
        /// Page changes: long, calm, no bounce.
        static let page = Feel(response: 0.46, damping: 0.94)
    }

    private(set) var value: CGFloat = 0
    private(set) var velocity: CGFloat = 0
    private(set) var target: CGFloat = 0
    private var feel = Feel.smooth
    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval = 0
    private var completion: (() -> Void)?
    /// Every step: the new value.
    private let apply: (CGFloat) -> Void

    var isRunning: Bool { link != nil }

    init(apply: @escaping (CGFloat) -> Void) {
        self.apply = apply
    }

    deinit { link?.invalidate() }

    /// Springs from `from` to `to`; `velocity` in value units per second. With
    /// Reduce Motion the value is set at once.
    func run(from: CGFloat, to: CGFloat, velocity: CGFloat = 0, feel: Feel, completion: (() -> Void)? = nil) {
        value = from
        target = to
        self.velocity = velocity
        self.feel = feel
        self.completion = completion
        if UIAccessibility.isReduceMotionEnabled || (abs(to - from) < 0.5 && abs(velocity) < 1) {
            finish()
            return
        }
        guard link == nil else { return }
        let link = CADisplayLink(target: Proxy(self), selector: #selector(Proxy.tick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        }
        lastTime = CACurrentMediaTime()
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Stops where it is (a finger took over); no completion.
    func stop() {
        link?.invalidate()
        link = nil
        completion = nil
    }

    private func finish() {
        link?.invalidate()
        link = nil
        value = target
        velocity = 0
        apply(value)
        let done = completion
        completion = nil
        done?()
    }

    fileprivate func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        var left = CGFloat(min(max(0, now - lastTime), 1.0 / 30))
        lastTime = now
        let omega = 2 * .pi / max(0.05, feel.response)
        let stiffness = omega * omega
        let damping = 2 * feel.damping * omega
        // Semi-implicit Euler in small steps: stable for every response we use.
        while left > 0 {
            let h = min(left, 1.0 / 480)
            velocity += (stiffness * (target - value) - damping * velocity) * h
            value += velocity * h
            left -= h
        }
        if abs(target - value) < 0.25, abs(velocity) < 6 {
            finish()
        } else {
            apply(value)
        }
    }

    /// The display link holds its target strongly; this keeps the driver free.
    private final class Proxy: NSObject {
        weak var owner: SpringDriver?
        init(_ owner: SpringDriver) {
            self.owner = owner
            super.init()
        }
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.step(link)
        }
    }
}
