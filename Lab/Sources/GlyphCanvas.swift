import UIKit

/// One line of a glyph, in a 100 × 100 box (the ring of the power mark has radius
/// 22 round (50, 52) — the size of the app's own mark).
struct Stroke {
    var path: CGPath
    var color: UIColor
    var width: CGFloat
    var opacity: CGFloat = 1
}

/// A soft round light: full colour in the middle, nothing at the edge.
struct Glow {
    var center: CGPoint
    var radius: CGFloat
    var color: UIColor
    var opacity: CGFloat
}

/// What a glyph shows in one frame.
struct GlyphFrame {
    var strokes: [Stroke] = []
    var glows: [Glow] = []
    /// Drawn over the strokes, shown only below `fillEdge` (0 top … 1 bottom of the box),
    /// with a soft edge of `fillFeather` either side.
    var fill: [Stroke] = []
    var fillEdge: CGFloat = 1
    var fillFeather: CGFloat = 0.12
    /// The whole glyph, round the middle of the box.
    var scale: CGFloat = 1
}

/// Values a glyph keeps from frame to frame, and the copy taken when the tunnel's
/// phase changed (so a new phase starts from where the old one stood).
struct GlyphMemo {
    var a: CGFloat = 0
    var legs: CGFloat = 0
    var k: CGFloat = 0
    var level: CGFloat = 0
    var head: CGFloat = 0
    var tail: CGFloat = 0
    var width: CGFloat = 0
    var light: CGFloat = 0
    var stripes: CGFloat = 0
    var comet: CGFloat = -60
    var cometOpacity: CGFloat = 0
}

protocol GlyphStyle {
    var id: String { get }
    var title: String { get }
    var note: String { get }
    func frame(_ phase: MockTunnel.Phase, _ elapsed: Double, start: GlyphMemo, memo: inout GlyphMemo, traits: UITraitCollection) -> GlyphFrame
}

/// Draws a `GlyphFrame` with plain shape layers, every display frame. A lab tool:
/// the shipped glyph would run the chosen motion as Core Animation instead.
final class GlyphCanvas: UIView {
    private let strokeHost = CALayer()
    private let glowHost = CALayer()
    private let fillHost = CALayer()
    private let fillMask = CAGradientLayer()
    private var strokeLayers: [CAShapeLayer] = []
    private var glowLayers: [CAGradientLayer] = []
    private var fillLayers: [CAShapeLayer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(glowHost)
        layer.addSublayer(strokeHost)
        layer.addSublayer(fillHost)
        fillMask.startPoint = CGPoint(x: 0.5, y: 0)
        fillMask.endPoint = CGPoint(x: 0.5, y: 1)
        fillMask.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
        fillHost.mask = fillMask
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for host in [strokeHost, glowHost, fillHost] { host.frame = bounds }
        fillMask.frame = bounds
        CATransaction.commit()
    }

    func render(_ frame: GlyphFrame) {
        let unit = bounds.width / 100
        guard unit > 0 else { return }
        // Box units to points, scaled round the middle of the box.
        let place = CGAffineTransform(translationX: bounds.midX, y: bounds.midY)
            .scaledBy(x: unit * frame.scale, y: unit * frame.scale)
            .translatedBy(x: -50, y: -50)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        draw(frame.strokes, into: strokeHost, pool: &strokeLayers, place: place, unit: unit * frame.scale)
        draw(frame.fill, into: fillHost, pool: &fillLayers, place: place, unit: unit * frame.scale)
        let edge = frame.fillEdge, feather = max(frame.fillFeather, 0.001)
        let low = min(max(edge - feather, 0), 1), high = min(max(edge + feather, low + 0.0001), 1)
        fillMask.locations = [0, NSNumber(value: Double(low)), NSNumber(value: Double(high)), 1]
        fillHost.isHidden = frame.fill.isEmpty
        while glowLayers.count < frame.glows.count {
            let glow = CAGradientLayer()
            glow.type = .radial
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            glowHost.addSublayer(glow)
            glowLayers.append(glow)
        }
        for (index, glow) in glowLayers.enumerated() {
            guard index < frame.glows.count else { glow.isHidden = true; continue }
            let item = frame.glows[index]
            let center = item.center.applying(place)
            let radius = item.radius * unit * frame.scale
            glow.isHidden = false
            glow.frame = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let color = item.color.resolvedColor(with: traitCollection)
            glow.colors = [color.withAlphaComponent(item.opacity).cgColor, color.withAlphaComponent(item.opacity * 0.45).cgColor, color.withAlphaComponent(0).cgColor]
            glow.locations = [0, 0.45, 1]
        }
        CATransaction.commit()
    }

    private func draw(_ strokes: [Stroke], into host: CALayer, pool: inout [CAShapeLayer], place: CGAffineTransform, unit: CGFloat) {
        while pool.count < strokes.count {
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            host.addSublayer(shape)
            pool.append(shape)
        }
        for (index, shape) in pool.enumerated() {
            guard index < strokes.count else { shape.isHidden = true; continue }
            let item = strokes[index]
            var transform = place
            shape.isHidden = false
            shape.path = item.path.copy(using: &transform)
            shape.lineWidth = item.width * unit
            shape.strokeColor = item.color.resolvedColor(with: traitCollection).cgColor
            shape.opacity = Float(max(0, min(1, item.opacity)))
        }
    }
}

// MARK: - Drawing helpers (box units, angles in degrees, clockwise on screen)

enum Ease {
    static func clamp(_ x: Double) -> CGFloat { CGFloat(max(0, min(1, x))) }
    static func out(_ x: Double) -> CGFloat { let t = clamp(x); return 1 - pow(1 - t, 3) }
    static func inOut(_ x: Double) -> CGFloat {
        let t = clamp(x)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// Soft at both ends, with no sharp middle (half a cosine).
    static func sine(_ x: Double) -> CGFloat { 0.5 - 0.5 * cos(.pi * clamp(x)) }

    static func mix(_ a: CGFloat, _ b: CGFloat, _ k: CGFloat) -> CGFloat { a + (b - a) * k }

    /// Piecewise-linear value at `t` through (times, values).
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

enum Shape {
    static func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ from: CGFloat, _ to: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard to - from > 0.3, r > 0.01 else { return path }
        let end = min(to, from + 359.6)
        path.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: from * .pi / 180, endAngle: end * .pi / 180, clockwise: false)
        return path
    }

    static func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x1, y: y1))
        path.addLine(to: CGPoint(x: x2, y: y2))
        return path
    }

    /// The logo's arch (∩) of the tunnel, scaled `scale` round the point it runs
    /// to, (50, 63): at 1 it is the opened power ring with its legs to y 74.
    static func arch(scale: CGFloat, legs: CGFloat = 1) -> CGPath {
        let r = 22 * scale
        let cy = 63 + (52 - 63) * scale
        let bottom = cy + (63 + (74 - 63) * scale - cy) * legs
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 50 - r, y: bottom))
        path.addLine(to: CGPoint(x: 50 - r, y: cy))
        path.addArc(center: CGPoint(x: 50, y: cy), radius: r, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
        path.addLine(to: CGPoint(x: 50 + r, y: bottom))
        return path
    }
}

extension UIColor {
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
