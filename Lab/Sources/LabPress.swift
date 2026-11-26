import UIKit

/// The variants of the press response on Home's two big buttons.
enum PressStyle: String, CaseIterable {
    case v363, v365, wave

    var title: String {
        switch self {
        case .v363: return "Как в 3.6.3"
        case .v365: return "Как в 3.6.5"
        case .wave: return "Волна (новый)"
        }
    }

    var note: String {
        switch self {
        case .v363: return "Пятно под пальцем; отпустил — растекается за 0.4 с. За пальцем не идёт."
        case .v365: return "Растекается за 0.18 с (выглядит как заливка), идёт за пальцем с короткой задержкой."
        case .wave: return "Пятно заметнее; отпустил — бежит волна: край темнее середины, 0.42 с. За пальцем тянется след."
        }
    }
}

/// The app's `TapControl` with `ripple` (3.6.5), copied for the lab with the
/// variants side by side. The surface sinks under the finger and springs back;
/// a soft spot grows under the finger and, on release, spreads over the plate.
class LabTapControl: UIControl {
    var style: PressStyle = .wave
    var pressScale: CGFloat = 0.985
    /// Corner radius the spot is clipped to; nil makes a capsule or circle.
    var rippleCornerRadius: CGFloat?
    private var clip: UIView?
    private var shade: CAGradientLayer?
    private var shadeReach: CGFloat = 1
    private var drift = CGPoint.zero
    private var lastGhost: CFTimeInterval = 0
    private var lastGhostPoint = CGPoint.zero

    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted else { return }
            if isHighlighted {
                UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
                    self.transform = CGAffineTransform(scaleX: self.pressScale, y: self.pressScale)
                }
            } else {
                UIView.animate(withDuration: 0.9, delay: 0, usingSpringWithDamping: 0.42, initialSpringVelocity: 0.6,
                               options: [.beginFromCurrentState, .allowUserInteraction]) {
                    self.transform = .identity
                }
            }
        }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        drift = .zero
        spread(from: touch.location(in: self))
        return super.beginTracking(touch, with: event)
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let going = super.continueTracking(touch, with: event)
        guard style != .v363, let shade else { return going }
        let point = touch.location(in: self)
        let previous = touch.previousLocation(in: self)
        drift = CGPoint(x: drift.x * 0.6 + (point.x - previous.x) * 0.4, y: drift.y * 0.6 + (point.y - previous.y) * 0.4)
        let outX = max(0, -point.x, point.x - bounds.width)
        let outY = max(0, -point.y, point.y - bounds.height)
        let out = hypot(outX, outY)
        let fadeOver = max(shade.bounds.width / 2 * (style == .wave ? 0.9 : 0.7), 30)
        let opacity = Float(max(0, 1 - out / fadeOver))
        if style == .wave { leaveGhost(of: shade, towards: point) }
        CATransaction.begin()
        // 3.6.5: a touch of lag (0.09 s); the wave lags more, so it reads as liquid.
        CATransaction.setAnimationDuration(style == .wave ? 0.16 : 0.09)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        shade.position = point
        shade.opacity = opacity
        CATransaction.commit()
        return going
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        let inside = isTouchInside
        super.endTracking(touch, with: event)
        release(inside ? .spread : (style == .v363 ? .fade : .runOff))
    }

    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        release(style == .v363 ? .fade : .retract)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let clip else { return }
        clip.frame = bounds
        clip.layer.cornerRadius = rippleCornerRadius ?? min(bounds.width, bounds.height) / 2
        bringSubviewToFront(clip)
    }

    private var ink: UIColor { UIColor.label.resolvedColor(with: traitCollection) }

    /// The spot's colours: `depth` at the middle, half of it at 55 %, none at the edge.
    private func spotColors(_ depth: CGFloat) -> [CGColor] {
        [ink.withAlphaComponent(depth).cgColor, ink.withAlphaComponent(depth / 2).cgColor, ink.withAlphaComponent(0).cgColor]
    }

    private func spread(from point: CGPoint) {
        let host: UIView
        if let clip { host = clip } else {
            host = UIView(frame: bounds)
            host.isUserInteractionEnabled = false
            host.clipsToBounds = true
            host.layer.cornerCurve = .continuous
            host.layer.cornerRadius = rippleCornerRadius ?? min(bounds.width, bounds.height) / 2
            addSubview(host)
            clip = host
        }
        bringSubviewToFront(host)
        release(.fade)
        let corners = [CGPoint.zero, CGPoint(x: bounds.width, y: 0), CGPoint(x: 0, y: bounds.height), CGPoint(x: bounds.width, y: bounds.height)]
        let farthest = corners.map { hypot($0.x - point.x, $0.y - point.y) }.max() ?? 1
        let radius = min(farthest, max(bounds.height, 44)) * 0.9
        let shade = CAGradientLayer()
        shade.type = .radial
        // The wave's spot is deeper, so the press is plainly seen.
        shade.colors = spotColors(style == .wave ? 0.09 : 0.07)
        shade.locations = [0, 0.55, 1]
        shade.startPoint = CGPoint(x: 0.5, y: 0.5)
        shade.endPoint = CGPoint(x: 1, y: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        shade.position = point
        host.layer.addSublayer(shade)
        CATransaction.commit()
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.2
        grow.toValue = 1
        grow.duration = 0.5
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
        shade.add(grow, forKey: "spread")
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = 0.12
        shade.add(appear, forKey: "appear")
        self.shade = shade
        shadeReach = farthest * 1.08 / radius
        lastGhost = 0
        lastGhostPoint = point
    }

    /// The wave's trail: where the spot was a moment ago, a fainter copy stays and
    /// melts away, so the moving finger leaves a short wake.
    private func leaveGhost(of shade: CAGradientLayer, towards point: CGPoint) {
        let now = CACurrentMediaTime()
        guard now - lastGhost > 0.035, hypot(point.x - lastGhostPoint.x, point.y - lastGhostPoint.y) > 3, let host = clip else { return }
        lastGhost = now
        lastGhostPoint = point
        let ghost = CAGradientLayer()
        ghost.type = .radial
        ghost.colors = shade.colors
        ghost.locations = shade.locations
        ghost.startPoint = shade.startPoint
        ghost.endPoint = shade.endPoint
        let from = shade.presentation()?.position ?? shade.position
        let opacity = (shade.presentation()?.opacity ?? shade.opacity) * 0.45
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.bounds = shade.bounds
        ghost.position = from
        ghost.opacity = 0
        host.layer.insertSublayer(ghost, below: shade)
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity
        fade.toValue = 0
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 0.95
        shrink.toValue = 0.7
        let group = CAAnimationGroup()
        group.animations = [fade, shrink]
        group.duration = 0.42
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ghost.add(group, forKey: "ghost")
        CATransaction.commit()
    }

    private enum End { case spread, runOff, retract, fade }

    private func release(_ end: End) {
        guard let shade else { return }
        self.shade = nil
        let current = shade.presentation()?.opacity ?? shade.opacity
        let scale = (shade.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
        CATransaction.begin()
        CATransaction.setCompletionBlock { shade.removeFromSuperlayer() }
        shade.removeAnimation(forKey: "spread")
        let group = CAAnimationGroup()
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        switch end {
        case .fade:
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = current
            fade.toValue = 0
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.animations = [fade]
            group.duration = 0.5
        case .retract:
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = scale
            shrink.toValue = scale * 0.25
            shrink.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.75, 0.4)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [current, current * 0.7, 0]
            fade.keyTimes = [0, 0.3, 1]
            group.animations = [shrink, fade]
            group.duration = 0.3
        case .runOff:
            let from = shade.presentation()?.position ?? shade.position
            let length = max(hypot(drift.x, drift.y), 0.001)
            let run = min(shade.bounds.width * (style == .wave ? 0.8 : 0.6), max(40, length * (style == .wave ? 8 : 6)))
            let to = CGPoint(x: from.x + drift.x / length * run, y: from.y + drift.y / length * run)
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(cgPoint: from)
            move.toValue = NSValue(cgPoint: to)
            move.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.6, 0.4, 1)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = current
            fade.toValue = 0
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            group.animations = [move, fade]
            group.duration = style == .wave ? 0.42 : 0.32
            shade.position = to
        case .spread:
            switch style {
            case .v363:
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = scale
                grow.toValue = max(scale, shadeReach)
                grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.8, 0.25, 1)
                let deepen = CABasicAnimation(keyPath: "colors")
                deepen.fromValue = shade.colors
                deepen.toValue = spotColors(0.11)
                deepen.duration = 0.4 * 0.35
                deepen.fillMode = .forwards
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [current, 1, 0.8, 0]
                fade.keyTimes = [0, 0.12, 0.55, 1]
                group.animations = [grow, deepen, fade]
                group.duration = 0.4
            case .v365:
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = scale
                grow.toValue = max(scale, shadeReach)
                grow.duration = 0.18
                grow.fillMode = .forwards
                grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.05, 0.9, 0.2, 1)
                let deepen = CABasicAnimation(keyPath: "colors")
                deepen.fromValue = shade.colors
                deepen.toValue = spotColors(0.14)
                deepen.duration = 0.18 * 0.6
                deepen.fillMode = .forwards
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [current, 1, 1, 0]
                fade.keyTimes = [0, 0.08, 0.45, 1]
                group.animations = [grow, deepen, fade]
                group.duration = 0.48
            case .wave:
                // A wave, not a flood: the spot runs out to the edges while its middle
                // empties, so the darker front is what moves; then it is gone.
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = scale
                grow.toValue = max(scale, shadeReach * 1.05)
                grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.15, 0.55, 0.3, 1)
                let hollow = CAKeyframeAnimation(keyPath: "colors")
                let first: [Any] = shade.colors ?? (spotColors(0.09) as [Any])
                let middle: [Any] = [ink.withAlphaComponent(0.055).cgColor, ink.withAlphaComponent(0.105).cgColor, ink.withAlphaComponent(0).cgColor]
                let last: [Any] = [ink.withAlphaComponent(0).cgColor, ink.withAlphaComponent(0.095).cgColor, ink.withAlphaComponent(0).cgColor]
                hollow.values = [first, middle, last]
                hollow.keyTimes = [0, 0.3, 1]
                let place = CABasicAnimation(keyPath: "locations")
                place.fromValue = [0, 0.55, 1]
                place.toValue = [0, 0.82, 1]
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [current, 1, 1, 0]
                fade.keyTimes = [0, 0.1, 0.6, 1]
                group.animations = [grow, hollow, place, fade]
                group.duration = 0.42
            }
        }
        shade.opacity = 0
        shade.add(group, forKey: "release")
        CATransaction.commit()
    }
}
