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
        /// A tap on the tab: quick and without a bounce (3.5.7).
        static let quick = Feel(response: 0.36, damping: 1)
        /// 3.5.12 (the owner: going up in analytics by the tab was too fast): calmer,
        /// for analytics only.
        static let calm = Feel(response: 0.5, damping: 1)
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

    /// 3.5.8: a motion set off by a tap, already moving at its start (the owner:
    /// one from rest looked as if it lagged before it got going). The spring is
    /// given a share of the speed that would carry it straight there, so it
    /// leaves at once and slows into its end without a bounce.
    /// `lead`: the share of that speed it starts with (3.5.12: analytics starts gentler).
    func glide(from: CGFloat, to: CGFloat, feel: Feel, lead: CGFloat = 0.6, completion: (() -> Void)? = nil) {
        let omega = 2 * .pi / max(0.05, feel.response)
        run(from: from, to: to, velocity: lead * omega * (to - from), feel: feel, completion: completion)
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

/// Paces a finger-driven motion by the display (3.1.9).
///
/// A swipe used to move its views from the pan's touch events alone, and nothing
/// asked ProMotion for a high rate: the screen, idle at a low rate, came up to
/// 120 Hz only after the motion had begun, so the first swipe of a list looked
/// abrupt while later ones (the display already fast) were smooth. A screen
/// recording runs at 60 Hz and did not show it. The pacer starts at touch-down,
/// asks for 120 Hz, and applies the latest finger position once per frame.
final class FramePacer {
    private var link: CADisplayLink?
    private var idleSince: CFTimeInterval = 0
    /// Called every frame while running; returns false when nothing is pending.
    private let frame: () -> Bool
    /// How long the pacer stays up with nothing to draw (the touch has not moved yet).
    private let idleTimeout: CFTimeInterval

    init(idleTimeout: CFTimeInterval = 0.5, frame: @escaping () -> Bool) {
        self.idleTimeout = idleTimeout
        self.frame = frame
    }

    deinit { link?.invalidate() }

    var isRunning: Bool { link != nil }

    /// Brings the display to its full rate now, before the first movement.
    func start() {
        idleSince = CACurrentMediaTime()
        guard link == nil else { return }
        let link = CADisplayLink(target: Proxy(self), selector: #selector(Proxy.tick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        }
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        if frame() {
            idleSince = link.timestamp
        } else if link.timestamp - idleSince > idleTimeout {
            stop()
        }
    }

    private final class Proxy: NSObject {
        weak var owner: FramePacer?
        init(_ owner: FramePacer) {
            self.owner = owner
            super.init()
        }
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.tick(link)
        }
    }
}

/// 3.5.7 (the owner: going up by a tap on the tab was slow everywhere, and two
/// quick taps jerked): a list's way to its top on a quick per-frame spring, in
/// place of the system's animated offset (slow, and restarted from rest by a
/// second call). A finger on the list stops it where it is.
final class ScrollTopSpring: NSObject {
    private weak var scroll: UIScrollView?
    private lazy var spring = SpringDriver { [weak self] y in
        guard let scroll = self?.scroll else { return }
        scroll.contentOffset = CGPoint(x: scroll.contentOffset.x, y: y)
    }

    var isRunning: Bool { spring.isRunning }

    init(_ scroll: UIScrollView) {
        self.scroll = scroll
        super.init()
        scroll.panGestureRecognizer.addTarget(self, action: #selector(dragged(_:)))
    }

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { spring.stop() }
    }

    func run(feel: SpringDriver.Feel = .quick, lead: CGFloat = 0.6) {
        guard let scroll else { return }
        let top = -scroll.adjustedContentInset.top
        // A second call while on the way changes nothing.
        guard !spring.isRunning else { return }
        // A fling still running ends here; the spring goes on from where it shows.
        scroll.setContentOffset(scroll.contentOffset, animated: false)
        spring.glide(from: scroll.contentOffset.y, to: top, feel: feel, lead: lead)
    }
}

extension UIScrollView {
    private static var topSpringKey = 0

    private var topSpring: ScrollTopSpring {
        if let spring = objc_getAssociatedObject(self, &Self.topSpringKey) as? ScrollTopSpring { return spring }
        let spring = ScrollTopSpring(self)
        objc_setAssociatedObject(self, &Self.topSpringKey, spring, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return spring
    }

    /// Quickly to the top (see ScrollTopSpring).
    func springToTop(feel: SpringDriver.Feel = .quick, lead: CGFloat = 0.6) { topSpring.run(feel: feel, lead: lead) }

    /// On its way to the top after `springToTop`.
    var isSpringingToTop: Bool {
        (objc_getAssociatedObject(self, &Self.topSpringKey) as? ScrollTopSpring)?.isRunning ?? false
    }
}
