import UIKit

/// 3.6.6 (the owner, chosen in PT Lab 1.6 — «1 · Тоннель»): the connection
/// button's glyph. Off it is the power mark. Connecting, the ring opens into the
/// logo's arch — in every frame a true arc and a straight leg along its tangent,
/// both halves mirrored — the stroke falls in under it and is gone, and inner
/// arches come out of the depth one after another, like the lights of a tunnel.
/// Connected: the front light runs out past the arch as an echo and the arch
/// turns green (red while the server does not answer, breathing), the second
/// light takes the first place and a new one the second — the logo's stripes.
/// Stopping: the arches go back into the depth, the arch closes into the ring
/// and the stroke comes back up.
///
/// Drawn in a 100 × 100 box (the ring: radius 22 round (50, 52) = the old mark's
/// 18.5 pt) with a few shape layers, set every display frame only while it moves.
final class TunnelGlyph: UIView {
    enum Look: Equatable { case off, connecting, on, failing, stopping }

    static let size = CGSize(width: 84, height: 84)
    /// Line width in box units (2.5 pt, as the old mark).
    private static let line: CGFloat = 3.0
    private static let morphTime: Double = 0.45
    private static let lightsStart: Double = 0.25
    private static let step: Double = 0.36
    private static let onTime: Double = 0.7
    private static let stopTime: Double = 0.6

    private enum Phase { case off, connecting, on, stopping }

    /// What one frame left, for the next phase to start from.
    private struct Memo {
        var a: CGFloat = 0
        var k: CGFloat = 0
        var flow: CGFloat = 0
    }

    private(set) var look: Look = .off
    private var phase: Phase = .off
    private var started: CFTimeInterval = 0
    private var memo = Memo()
    private var start = Memo()
    /// The colour of the arch when up: green, or red while the server fails.
    private var accent: UIColor = .systemGreen
    private var accentFrom: UIColor = .systemGreen
    private var accentChanged: CFTimeInterval = 0
    private var still = false

    private let body = CAShapeLayer()
    private let stem = CAShapeLayer()
    private var arches: [CAShapeLayer] = []
    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for item in [body, stem] { layer.addSublayer(item) }
        for _ in 0 ..< 3 {
            let arch = CAShapeLayer()
            layer.addSublayer(arch)
            arches.append(arch)
        }
        for item in [body, stem] + arches {
            item.fillColor = nil
            item.lineCap = .round
            item.lineJoin = .round
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { Self.size }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in [body, stem] + arches { item.frame = bounds }
        CATransaction.commit()
        render()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        render()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopLink() } else { runIfMoving() }
    }

    // MARK: State

    func show(_ next: Look, animated: Bool) {
        let previous = look
        look = next
        still = !animated || UIAccessibility.isReduceMotionEnabled
        let now = CACurrentMediaTime()
        if next == .on || next == .failing {
            let colour: UIColor = next == .failing ? .systemRed : .systemGreen
            if colour != accent {
                accentFrom = previous == .on || previous == .failing ? accent : colour
                accent = colour
                accentChanged = now
            }
        }
        switch next {
        case .off:
            // A stop already under way finishes on its own; anything else stops now.
            if phase == .on || phase == .connecting { begin(.stopping, now) }
        case .stopping:
            if phase == .on || phase == .connecting { begin(.stopping, now) }
        case .connecting:
            if phase != .connecting { begin(.connecting, now) }
        case .on, .failing:
            if phase != .on { begin(.on, now) }
        }
        if still, phase != .connecting {
            // No motion: the end of the phase at once.
            started = now - 10
            accentChanged = now - 10
            if phase == .stopping { phase = .off }
        }
        updatePulse()
        render()
        runIfMoving()
    }

    private func begin(_ next: Phase, _ now: CFTimeInterval) {
        start = memo
        phase = next
        started = now
    }

    /// Red breathes softly, so a hung server is noticed.
    private func updatePulse() {
        let pulsing = look == .failing && !UIAccessibility.isReduceMotionEnabled
        if pulsing, layer.animation(forKey: "pulse") == nil {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1
            breathe.toValue = 0.45
            breathe.duration = 1.1
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.beginTime = CACurrentMediaTime() + 0.6
            layer.add(breathe, forKey: "pulse")
        } else if !pulsing {
            layer.removeAnimation(forKey: "pulse")
        }
    }

    // MARK: Motion

    private var moving: Bool {
        let elapsed = CACurrentMediaTime() - started
        switch phase {
        case .off: return false
        case .connecting: return !still
        case .on: return elapsed < Self.onTime || CACurrentMediaTime() - accentChanged < 0.5
        case .stopping: return true
        }
    }

    private func runIfMoving() {
        guard window != nil, moving, link == nil else { return }
        let link = CADisplayLink(target: TunnelGlyphTicker(self), selector: #selector(TunnelGlyphTicker.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick() {
        render()
        if !moving { stopLink() }
    }

    // MARK: Drawing

    private func render() {
        let unit = bounds.width / 100
        guard unit > 0 else { return }
        let now = CACurrentMediaTime()
        var e = now - started
        if phase == .stopping, e >= Self.stopTime {
            phase = .off
            memo = Memo()
            start = Memo()
        }
        if phase == .connecting, still { e = Self.morphTime + Self.step * 2 + Self.lightsStart }

        var t: CGFloat = 0, k: CGFloat = 0, flow: CGFloat = 0
        var lights: [(p: CGFloat, opacity: CGFloat)] = []
        switch phase {
        case .off:
            break
        case .connecting:
            t = Ease.mix(start.a, 1, Ease.sine(e / Self.morphTime))
            flow = CGFloat(max(0, e - Self.lightsStart) / Self.step)
            lights = Self.places(flow).map { (p: $0, opacity: Self.lightOpacity($0)) }
        case .on:
            t = Ease.mix(start.a, 1, Ease.sine(e / 0.3))
            k = Ease.mix(start.k, 1, Ease.out(e / 0.3))
            lights = Self.settle(from: start.flow, e)
        case .stopping:
            k = start.k * (1 - Ease.out(e / 0.3))
            t = start.a * (1 - Ease.sine((e - 0.1) / Self.morphTime))
            let fade = 1 - Ease.out(e / 0.28)
            if start.k > 0 {
                lights = [(p: 1 * fade, opacity: 0.55 * fade), (p: 2 * fade, opacity: 0.8 * fade)]
            } else {
                lights = Self.places(start.flow).map { (p: $0, opacity: Self.lightOpacity($0) * fade) }
            }
        }
        memo = Memo(a: t, k: k, flow: flow)

        let ink = UIColor.label.resolvedColor(with: traitCollection)
        let shift = Ease.out((now - accentChanged) / 0.45)
        let up = accentFrom.blended(accent, shift, traitCollection)
        let colour = ink.blended(up, k, traitCollection).cgColor
        let place = CGAffineTransform(scaleX: unit, y: unit)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var transform = place
        body.path = Self.body(t).copy(using: &transform)
        body.lineWidth = Self.line * unit
        body.strokeColor = colour
        let stroke = 1 - min(1, t * 1.4)
        stem.isHidden = stroke <= 0
        stem.path = Self.segment(50, 24 + 28 * t, 50, 50 + 24 * t).copy(using: &transform)
        stem.lineWidth = Self.line * unit
        stem.strokeColor = colour
        stem.opacity = Float(stroke)
        for (index, arch) in arches.enumerated() {
            guard index < lights.count, lights[index].opacity > 0.001 else { arch.isHidden = true; continue }
            let scale = Self.scale(lights[index].p)
            arch.isHidden = false
            arch.path = Self.arch(scale).copy(using: &transform)
            arch.lineWidth = Self.width(scale) * unit
            arch.strokeColor = colour
            arch.opacity = Float(min(1, lights[index].opacity))
        }
        CATransaction.commit()
    }

    /// Connected: where the lights go from where they stood. With all three out,
    /// the front one runs out as the echo (place 4), the others step to 2 and 1.
    /// Connected before they were all out: the two front ones go to 2 and 1, and
    /// an echo of the arch itself runs out.
    private static func settle(from flow: CGFloat, _ e: Double) -> [(p: CGFloat, opacity: CGFloat)] {
        let opacity: (CGFloat) -> CGFloat = { Ease.keys($0, [0, 1, 2, 3, 4], [0, 0.55, 0.8, 0.65, 0]) }
        let move = Ease.out(e / 0.45)
        if flow >= 2 {
            let r = flow - floor(flow)
            let back = r + (1 - r) * move
            let middle = r + 1 + (1 - r) * move
            let front = r + 2 + (2 - r) * Ease.out(e / 0.6)
            return [(p: back, opacity: opacity(back)), (p: middle, opacity: opacity(middle)), (p: front, opacity: opacity(front))]
        }
        let out = places(flow).sorted(by: >)
        var result: [(p: CGFloat, opacity: CGFloat)] = []
        for (index, target) in [CGFloat(2), 1].enumerated() {
            let from = index < out.count ? out[index] : 0
            let p = from + (target - from) * move
            result.append((p: p, opacity: opacity(p)))
        }
        let echo = 3 + Ease.out(e / 0.6)
        result.append((p: echo, opacity: e < 0.6 ? 0.6 * (4 - echo) : 0))
        return result
    }

    // MARK: Shapes (box units)

    /// Conveyor places of the three lights `flow` steps in: each comes out of
    /// the depth in turn, then runs round (0 depth, 1 small, 2 first, 3 the arch).
    private static func places(_ flow: CGFloat) -> [CGFloat] {
        (0 ..< 3).compactMap { index in
            let p = flow - CGFloat(index)
            return p < 0 ? nil : p.truncatingRemainder(dividingBy: 3)
        }
    }

    private static func lightOpacity(_ p: CGFloat) -> CGFloat {
        Ease.keys(p, [0, 1, 2, 2.6, 3], [0, 0.55, 0.8, 0.45, 0])
    }

    private static func scale(_ p: CGFloat) -> CGFloat {
        Ease.keys(p, [0, 1, 2, 3, 4], [0.12, 0.44, 0.7, 1.0, 1.3])
    }

    private static func width(_ scale: CGFloat) -> CGFloat { line * (0.6 + 0.3 * min(scale, 1)) }

    /// The ring at `t` 0, the arch at 1: each half a true arc from `a0` down to
    /// `a1` and a leg along its tangent; the right half is the mirror.
    private static func body(_ t: CGFloat) -> CGPath {
        let a0 = (240 + 30 * t) * .pi / 180
        let a1 = (90 + 90 * t) * .pi / 180
        let end = CGPoint(x: 50 + 22 * cos(a1), y: 52 + 22 * sin(a1))
        let leg = 22 * t
        let half = CGMutablePath()
        half.addArc(center: CGPoint(x: 50, y: 52), radius: 22, startAngle: a0, endAngle: a1, clockwise: true)
        if leg > 0.01 { half.addLine(to: CGPoint(x: end.x + sin(a1) * leg, y: end.y - cos(a1) * leg)) }
        let path = CGMutablePath()
        path.addPath(half)
        path.addPath(half, transform: CGAffineTransform(translationX: 100, y: 0).scaledBy(x: -1, y: 1))
        return path
    }

    /// The arch (∩) scaled `scale` round the point it runs to, (50, 63).
    private static func arch(_ scale: CGFloat) -> CGPath {
        let r = 22 * scale
        let cy = 63 + (52 - 63) * scale
        let bottom = 63 + (74 - 63) * scale
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 50 - r, y: bottom))
        path.addLine(to: CGPoint(x: 50 - r, y: cy))
        path.addArc(center: CGPoint(x: 50, y: cy), radius: r, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
        path.addLine(to: CGPoint(x: 50 + r, y: bottom))
        return path
    }

    private static func segment(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x1, y: y1))
        path.addLine(to: CGPoint(x: x2, y: y2))
        return path
    }

    private enum Ease {
        static func clamp(_ x: Double) -> CGFloat { CGFloat(max(0, min(1, x))) }
        static func out(_ x: Double) -> CGFloat { let t = clamp(x); return 1 - pow(1 - t, 3) }
        static func sine(_ x: Double) -> CGFloat { 0.5 - 0.5 * cos(.pi * clamp(x)) }
        static func mix(_ a: CGFloat, _ b: CGFloat, _ k: CGFloat) -> CGFloat { a + (b - a) * k }

        static func keys(_ t: CGFloat, _ times: [CGFloat], _ values: [CGFloat]) -> CGFloat {
            guard let first = times.first, t > first else { return values[0] }
            for index in 1 ..< times.count where t <= times[index] {
                let span = times[index] - times[index - 1]
                let k = span > 0 ? (t - times[index - 1]) / span : 1
                return values[index - 1] + (values[index] - values[index - 1]) * k
            }
            return values[values.count - 1]
        }
    }
}

/// Holds the glyph weakly for its display link (which retains its target).
private final class TunnelGlyphTicker: NSObject {
    weak var owner: TunnelGlyph?
    init(_ owner: TunnelGlyph) { self.owner = owner }

    @objc func tick(_ link: CADisplayLink) {
        guard let owner else { link.invalidate(); return }
        owner.tick()
    }
}

private extension UIColor {
    /// `self` turned towards `other` by `k` (0 … 1), in the given traits.
    func blended(_ other: UIColor, _ k: CGFloat, _ traits: UITraitCollection) -> UIColor {
        let t = max(0, min(1, k))
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        resolvedColor(with: traits).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.resolvedColor(with: traits).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
    }
}
