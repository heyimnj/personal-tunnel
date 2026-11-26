import UIKit

/// 3.6.6 (the owner, chosen in PT Lab — «1 · Туннель»): the connection button's
/// glyph. Off it is the power mark. Connecting, the ring opens into the logo's
/// arch — in every frame a true arc and a straight leg along its tangent, both
/// halves mirrored — the stroke falls in under it and is gone, and inner arches
/// come out of the depth one after another, like the lights of a tunnel.
/// Connected: the front light runs out past the arch as an echo, the second
/// takes the first place and a new one the second — the logo's stripes.
/// Stopping: the arches go back into the depth, the arch closes into the ring
/// and the stroke comes back up.
///
/// Colours, as the mark had them since 3.5 beta 4 (the owner): yellow while the
/// tunnel comes up or goes down or changes server (3.6.14 beta 1: a yellow stretch
/// running along the mark), green when it is up and the
/// server answers, red (breathing) when it does not, grey when off.
///
/// 3.6.7 (the owner: quick connect/disconnect jerked): no phase is replayed from
/// a snapshot any more. Every part — the opening of the arch, the colour, each
/// light's place and presence — is a value that springs towards its target and
/// keeps its speed, so a change of mind half way simply turns the motion round.
///
/// Drawn in a 100 × 100 box (the ring: radius 22 round (50, 52)) with a few
/// shape layers, set every display frame only while something moves.
final class TunnelGlyph: UIView {
    enum Look: Equatable { case off, connecting, on, failing, stopping }

    static let size = CGSize(width: 84, height: 84)
    /// Line width in box units (2.5 pt).
    private static let line: CGFloat = 3.0
    /// Lights run one place per this many seconds while connecting.
    private static let step: CGFloat = 0.36

    /// A critically damped spring: no overshoot, speed kept across target changes.
    private struct Spring {
        var x: CGFloat
        var v: CGFloat = 0
        var target: CGFloat
        let omega: CGFloat

        init(_ value: CGFloat, omega: CGFloat) {
            x = value
            target = value
            self.omega = omega
        }

        mutating func step(_ dt: CGFloat) {
            var left = dt
            while left > 0 {
                let h = min(left, 1 / 240)
                let a = omega * omega * (target - x) - 2 * omega * v
                v += a * h
                x += v * h
                left -= h
            }
        }

        var settled: Bool { abs(target - x) < 0.0005 && abs(v) < 0.002 }

        mutating func snap() {
            x = target
            v = 0
        }
    }

    private struct Light {
        /// Place: 0 depth, 1 small arch, 2 first arch, 3 the arch itself, 4 gone outside.
        var p: Spring
        /// Presence: 1 shown, 0 gone.
        var alive: Spring
        /// Moving with the conveyor (connecting) rather than springing to a place.
        var running = true
        /// Running out past the arch (the echo when connected).
        var echo = false
        var retiring = false

        init(at place: CGFloat) {
            p = Spring(place, omega: 9)
            alive = Spring(1, omega: 12)
        }
    }

    private enum Mode { case idle, conveyor, settled }

    private(set) var look: Look = .off
    private var mode: Mode = .idle
    /// 0: the power ring, 1: the arch.
    private var opening = Spring(0, omega: 10)
    /// The colour as RGBA springs.
    private var tint = [Spring(0, omega: 9), Spring(0, omega: 9), Spring(0, omega: 9), Spring(1, omega: 9)]
    private var tintSet = false
    private var lights: [Light] = []
    private var still = false

    private let body = CAShapeLayer()
    private let stem = CAShapeLayer()
    /// 3.6.14 beta 1 (the owner): while the tunnel comes up, goes down or changes
    /// server, a yellow stretch runs along the mark — as the 3.5 mark's ran round its
    /// ring — instead of the whole mark turning yellow. Up, it fades and the mark is
    /// green (red if the server does not answer); it never runs while the tunnel stands.
    private let runner = CAShapeLayer()
    private var runnerShown = Spring(0, omega: 10)
    private var archLayers: [CAShapeLayer] = []
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for item in [body, stem, runner] {
            item.fillColor = nil
            item.lineCap = .round
            item.lineJoin = .round
            layer.addSublayer(item)
        }
        runner.opacity = 0
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { Self.size }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in [body, stem, runner] + archLayers { item.frame = bounds }
        CATransaction.commit()
        render()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        // A theme change is not a motion: the colour goes there at once.
        setTint(for: look, snap: true)
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
        switch next {
        case .off, .stopping:
            opening.target = 0
            mode = .idle
            for index in lights.indices { retire(&lights[index]) }
        case .connecting:
            opening.target = 1
            if mode != .conveyor {
                mode = .conveyor
                for index in lights.indices where !lights[index].retiring {
                    lights[index].running = true
                    lights[index].echo = false
                }
            }
        case .on, .failing:
            opening.target = 1
            if mode != .settled {
                mode = .settled
                settleLights(echoArch: previous == .connecting || previous == .off || previous == .stopping)
            }
        }
        setTint(for: next, snap: still || !tintSet)
        tintSet = true
        runnerShown.target = (next == .connecting || next == .stopping) && !UIAccessibility.isReduceMotionEnabled ? 1 : 0
        if still { snapAll() }
        updatePulse()
        render()
        runIfMoving()
    }

    private func retire(_ light: inout Light) {
        light.retiring = true
        light.running = false
        light.echo = false
        light.p.target = 0
        light.alive.target = 0
    }

    /// Connected: the front light (if it is past the first place) runs out as the
    /// echo; the next two take the first and the small place; any others go back.
    /// Missing ones come out of the depth. With no light out front, an echo of the
    /// arch itself runs out.
    private func settleLights(echoArch: Bool) {
        var active = lights.indices.filter { !lights[$0].retiring }.sorted { lights[$0].p.x > lights[$1].p.x }
        var echoed = false
        if let front = active.first, lights[front].p.x >= 2.15 {
            lights[front].echo = true
            lights[front].running = false
            lights[front].p.target = 4
            active.removeFirst()
            echoed = true
        }
        for (rank, index) in active.enumerated() {
            lights[index].running = false
            if rank < 2 {
                lights[index].p.target = rank == 0 ? 2 : 1
            } else {
                retire(&lights[index])
            }
        }
        for target in [CGFloat(2), 1].dropFirst(min(active.count, 2)) {
            var light = Light(at: 0)
            light.running = false
            light.p.target = target
            lights.append(light)
        }
        if !echoed, echoArch {
            var echo = Light(at: 3)
            echo.running = false
            echo.echo = true
            echo.p.target = 4
            lights.append(echo)
        }
    }

    private func setTint(for look: Look, snap: Bool) {
        let colour: UIColor
        switch look {
        case .off: colour = .label
        // 3.6.14 beta 1: the mark keeps its plain colour; the yellow runs along it.
        case .connecting, .stopping: colour = .label
        case .on: colour = .systemGreen
        case .failing: colour = .systemRed
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.resolvedColor(with: traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        for (index, value) in [r, g, b, a].enumerated() {
            tint[index].target = value
            if snap { tint[index].snap() }
        }
    }

    private func snapAll() {
        opening.snap()
        runnerShown.snap()
        for index in tint.indices { tint[index].snap() }
        switch mode {
        case .idle:
            lights.removeAll()
        case .conveyor:
            // No motion: two still arches inside.
            lights = [CGFloat(2), 1].map { place in
                var light = Light(at: place)
                light.running = false
                return light
            }
        case .settled:
            lights.removeAll { $0.echo || $0.retiring }
            for index in lights.indices {
                lights[index].p.snap()
                lights[index].alive.snap()
            }
        }
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
        if mode == .conveyor, !still { return true }
        if !opening.settled || !runnerShown.settled || tint.contains(where: { !$0.settled }) { return true }
        return lights.contains { !$0.p.settled || !$0.alive.settled || $0.running }
    }

    private func runIfMoving() {
        guard window != nil, moving, link == nil else { return }
        let link = CADisplayLink(target: TunnelGlyphTicker(self), selector: #selector(TunnelGlyphTicker.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = CACurrentMediaTime()
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(max(now - lastTick, 0), 0.05))
        lastTick = now
        advance(dt)
        render()
        if !moving { stopLink() }
    }

    private func advance(_ dt: CGFloat) {
        opening.step(dt)
        runnerShown.step(dt)
        for index in tint.indices { tint[index].step(dt) }
        for index in lights.indices {
            if lights[index].running {
                lights[index].p.x += dt / Self.step
                lights[index].p.v = 1 / Self.step
                lights[index].p.target = lights[index].p.x
            } else {
                lights[index].p.step(dt)
            }
            lights[index].alive.step(dt)
        }
        lights.removeAll { light in
            (light.running && light.p.x >= 3) || (light.echo && light.p.x >= 3.97)
                || (light.retiring && light.alive.x < 0.01)
        }
        // A new light comes out of the depth once the arch stands and the last
        // one has moved a place on.
        if mode == .conveyor, opening.x > 0.55 {
            let nearest = lights.filter { $0.running }.map(\.p.x).min() ?? .infinity
            if nearest >= 1 { lights.append(Light(at: 0)) }
        }
    }

    // MARK: Drawing

    private func render() {
        let unit = bounds.width / 100
        guard unit > 0 else { return }
        let t = max(0, min(1, opening.x))
        let colour = UIColor(red: tint[0].x, green: tint[1].x, blue: tint[2].x, alpha: max(0, min(1, tint[3].x))).cgColor
        var transform = CGAffineTransform(scaleX: unit, y: unit)

        while archLayers.count < lights.count {
            let arch = CAShapeLayer()
            arch.fillColor = nil
            arch.lineCap = .round
            arch.lineJoin = .round
            arch.frame = bounds
            layer.addSublayer(arch)
            archLayers.append(arch)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.path = Self.body(t).copy(using: &transform)
        body.lineWidth = Self.line * unit
        body.strokeColor = colour
        let shown = max(0, min(1, runnerShown.x))
        runner.isHidden = shown < 0.01
        if !runner.isHidden {
            runner.path = Self.runnerPath(t).copy(using: &transform)
            runner.lineWidth = Self.line * unit
            runner.strokeColor = UIColor.systemYellow.resolvedColor(with: traitCollection).cgColor
            runner.opacity = Float(shown)
            startRunning()
        } else {
            runner.removeAnimation(forKey: "run")
        }
        let stroke = 1 - min(1, t * 1.4)
        stem.isHidden = stroke <= 0
        stem.path = Self.segment(50, 24 + 28 * t, 50, 50 + 24 * t).copy(using: &transform)
        stem.lineWidth = Self.line * unit
        stem.strokeColor = colour
        stem.opacity = Float(stroke)
        for (index, arch) in archLayers.enumerated() {
            guard index < lights.count else { arch.isHidden = true; continue }
            let light = lights[index]
            let place = max(0, light.p.x)
            let shown = (light.echo ? Self.echoOpacity(place) : Self.lightOpacity(place)) * max(0, min(1, light.alive.x))
            guard shown > 0.001 else { arch.isHidden = true; continue }
            let scale = Self.scale(place)
            arch.isHidden = false
            arch.path = Self.arch(scale).copy(using: &transform)
            arch.lineWidth = Self.width(scale) * unit
            arch.strokeColor = colour
            arch.opacity = Float(min(1, shown))
        }
        CATransaction.commit()
    }

    // MARK: Shapes (box units)

    private static func lightOpacity(_ p: CGFloat) -> CGFloat {
        keys(p, [0, 1, 2, 2.6, 3], [0, 0.55, 0.8, 0.45, 0])
    }

    private static func echoOpacity(_ p: CGFloat) -> CGFloat {
        keys(p, [0, 1, 2, 2.6, 3, 4], [0, 0.55, 0.8, 0.55, 0.6, 0])
    }

    private static func scale(_ p: CGFloat) -> CGFloat {
        keys(p, [0, 1, 2, 3, 4], [0.12, 0.44, 0.7, 1.0, 1.3])
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

    /// The mark as one way for the runner: up the left half from its foot over
    /// the top (across the ring's gap) and down the right half to its foot.
    private static func runnerPath(_ t: CGFloat) -> CGPath {
        let a0 = (240 + 30 * t) * .pi / 180
        let a1 = (90 + 90 * t) * .pi / 180
        let leg = 22 * t
        let point = { (angle: CGFloat) in CGPoint(x: 50 + 22 * cos(angle), y: 52 + 22 * sin(angle)) }
        let left = point(a1)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left.x + sin(a1) * leg, y: left.y - cos(a1) * leg))
        path.addLine(to: left)
        path.addArc(center: CGPoint(x: 50, y: 52), radius: 22, startAngle: a1, endAngle: a0, clockwise: false)
        // The right half mirrors the left: angle θ ↔ π − θ.
        let r0 = .pi - a0, r1 = .pi - a1
        path.move(to: point(r0))
        path.addArc(center: CGPoint(x: 50, y: 52), radius: 22, startAngle: r0, endAngle: r1, clockwise: false)
        let right = point(r1)
        path.addLine(to: CGPoint(x: right.x - sin(a1) * leg, y: right.y - cos(a1) * leg))
        return path
    }

    /// A quarter of the way runs from one foot to the other, as the 3.5 mark's
    /// stretch ran round its ring (1.2 s a lap).
    private func startRunning() {
        guard runner.animation(forKey: "run") == nil else { return }
        let head = CAKeyframeAnimation(keyPath: "strokeEnd")
        head.values = [0, 0.28, 1, 1]
        head.keyTimes = [0, 0.2, 0.8, 1]
        let tail = CAKeyframeAnimation(keyPath: "strokeStart")
        tail.values = [0, 0, 0.72, 1]
        tail.keyTimes = [0, 0.2, 0.8, 1]
        let run = CAAnimationGroup()
        run.animations = [head, tail]
        run.duration = 1.2
        run.repeatCount = .infinity
        run.isRemovedOnCompletion = false
        runner.add(run, forKey: "run")
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

    private static func keys(_ t: CGFloat, _ times: [CGFloat], _ values: [CGFloat]) -> CGFloat {
        guard let first = times.first, t > first else { return values[0] }
        for index in 1 ..< times.count where t <= times[index] {
            let span = times[index] - times[index - 1]
            let k = span > 0 ? (t - times[index - 1]) / span : 1
            return values[index - 1] + (values[index] - values[index - 1]) * k
        }
        return values[values.count - 1]
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
