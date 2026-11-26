import UIKit

/// The variants of the connection button's glyph, in the order of the menu.
enum ConnectGlyphs {
    static let all: [GlyphStyle] = [
        CurrentGlyph(),
        ShippedTunnel(),
        RingFillGlyph(),
    ]

    static func style(_ id: String) -> GlyphStyle {
        all.first { $0.id == id } ?? all[1]
    }
}

/// «1 · Туннель» as the app has it (3.6.12): drawn by `TunnelGlyphView`, a copy of
/// the app's glyph, not by the canvas — the home screen shows that view for it.
struct ShippedTunnel: GlyphStyle {
    static let identifier = "tunnel.shipped"
    let id = ShippedTunnel.identifier
    let title = "1 · Туннель (как в 3.6.12)"
    let note = "Как в приложении: жёлтый при подключении и отключении, зелёный — подключено; плавно разворачивается при быстрых нажатиях."

    func frame(_: MockTunnel.Phase, _: Double, start _: GlyphMemo, memo _: inout GlyphMemo, traits _: UITraitCollection) -> GlyphFrame {
        GlyphFrame()
    }
}

/// Line width of the app's mark (2.5 pt at the app's size), in box units.
private let line: CGFloat = 3.0
private var green: UIColor { .systemGreen }
private var ink: UIColor { .label }

// MARK: - As in 3.6

/// The glyph as the app has it now (`SwitchGlyph`): yellow stretch running round
/// while connecting, closing into green when connected, leaving from its start.
struct CurrentGlyph: GlyphStyle {
    let id = "current"
    let title = "Сейчас (3.6)"
    let note = "Как в приложении: жёлтый отрезок бежит по кольцу, при подключении замыкается в зелёный."

    private let from: CGFloat = -54
    private let span: CGFloat = 288

    func frame(_ phase: MockTunnel.Phase, _ e: Double, start: GlyphMemo, memo: inout GlyphMemo, traits: UITraitCollection) -> GlyphFrame {
        let grey = UIColor.secondaryLabel
        var head: CGFloat = 0, tail: CGFloat = 0, opacity: CGFloat = 0
        var color = UIColor.systemYellow
        var stem = grey
        switch phase {
        case .off:
            break
        case .connecting:
            let t = CGFloat((e.truncatingRemainder(dividingBy: 1.2)) / 1.2)
            head = Ease.keys(t, [0, 0.2, 0.8, 1], [0, 0.28, 1, 1])
            tail = Ease.keys(t, [0, 0.2, 0.8, 1], [0, 0, 0.72, 1])
            opacity = Ease.out(e / 0.25)
            stem = grey.blended(.systemYellow, Ease.out(e / 0.45), traits)
        case .on:
            let k = Ease.out(e / 0.6)
            head = Ease.mix(start.head, 1, k)
            tail = Ease.mix(start.tail, 0, k)
            opacity = 1
            color = UIColor.systemYellow.blended(green, Ease.out(e / 0.45), traits)
            stem = color
        case .disconnecting:
            let k = Ease.inOut(e / 0.5)
            head = start.head
            tail = Ease.mix(start.tail, 1, k)
            opacity = 1 - k
            color = green
            stem = green.blended(grey, Ease.out(e / 0.45), traits)
        }
        memo.head = head
        memo.tail = tail
        var frame = GlyphFrame()
        frame.strokes.append(Stroke(path: Shape.arc(50, 52, 22, from, from + span), color: grey, width: line))
        frame.strokes.append(Stroke(path: Shape.line(50, 28.8, 50, 48.7), color: stem, width: line))
        if opacity > 0 {
            frame.strokes.append(Stroke(path: Shape.arc(50, 52, 22, from + span * tail, from + span * head), color: color, width: line, opacity: opacity))
        }
        return frame
    }
}

// MARK: - 1. Tunnel

/// The power mark becomes the logo's arch. Each half of the ring flows into its
/// half of the arch point by point (equal steps along both lines), so the shape
/// stays even and mirrored all the way; the stroke falls in under it and is
/// gone. While connecting, inner arches come out of the depth one after another
/// (a conveyor). Connected: the front one runs out past the arch as an echo and
/// turns green with it, the second takes its place, a new one comes from the
/// middle. Stopping: the arches go back into the depth, the arch closes into the
/// ring and the stroke comes back up.
struct TunnelGlyph: GlyphStyle {
    /// A soft green light deep inside, once connected.
    let light: Bool

    var id: String { light ? "tunnel3.light" : "tunnel3" }
    var title: String { light ? "1 · Туннель + свет (старый)" : "1 · Туннель (старый)" }
    var note: String {
        light
            ? "То же, что «Туннель», и в глубине арки мягкий зелёный свет."
            : "Кольцо ровно перетекает в арку, палочка падает внутрь и исчезает, из глубины по одной выходят арки. Подключено — передняя уходит эхом, остальные встают на место."
    }

    private static let samples = 40
    private static let morphTime: Double = 0.45
    private static let step: Double = 0.36

    // Halves, from the top (u 0) to the end (u 1); the right half is the mirror.
    private static func ringHalf(_ u: CGFloat) -> CGPoint {
        let angle = (240 - 150 * u) * .pi / 180
        return CGPoint(x: 50 + 22 * cos(angle), y: 52 + 22 * sin(angle))
    }

    private static func archHalf(_ u: CGFloat, _ scale: CGFloat) -> CGPoint {
        let r = 22 * scale, cy = 63 - 11 * scale
        let arc = r * .pi / 2, leg = 22 * scale
        let d = u * (arc + leg)
        if d <= arc {
            let angle = 1.5 * .pi - d / r
            return CGPoint(x: 50 + r * cos(angle), y: cy + r * sin(angle))
        }
        return CGPoint(x: 50 - r, y: cy + (d - arc))
    }

    /// The inner lights start running this long into connecting.
    private static let lightsStart: Double = 0.25

    /// Conveyor places of the three lights `flow` steps in: each comes out of the
    /// depth in turn (none is shown before its time), then runs round.
    private static func places(_ flow: CGFloat) -> [CGFloat] {
        (0 ..< 3).compactMap { index in
            let p = flow - CGFloat(index)
            return p < 0 ? nil : p.truncatingRemainder(dividingBy: 3)
        }
    }

    private static func lightOpacity(_ p: CGFloat) -> CGFloat {
        Ease.keys(p, [0, 1, 2, 2.6, 3], [0, 0.55, 0.8, 0.45, 0])
    }

    /// The ring at `t` 0, the arch at 1 — in every frame a true arc of the circle
    /// (centre (50, 52), radius 22) and a straight leg along its tangent, so the
    /// ends stay round (1.6; the owner: a straight piece and then a bend).
    /// Each half: the arc from `a0` down to `a1`, then the leg; mirrored.
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

    /// Both halves, each `t` of the way from `from` to `to`.
    private static func morph(_ from: (CGFloat) -> CGPoint, _ to: (CGFloat) -> CGPoint, _ t: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for mirrored in [false, true] {
            for index in 0 ... samples {
                let u = CGFloat(index) / CGFloat(samples)
                let a = from(u), b = to(u)
                var x = a.x + (b.x - a.x) * t
                let y = a.y + (b.y - a.y) * t
                if mirrored { x = 100 - x }
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
        return path
    }

    /// Conveyor places: 0 the depth (unseen), 1 the small arch, 2 the first
    /// arch, 3 the arch itself, 4 an echo outside, gone.
    private static func scale(_ p: CGFloat) -> CGFloat {
        Ease.keys(p, [0, 1, 2, 3, 4], [0.12, 0.44, 0.7, 1.0, 1.3])
    }

    private static func width(_ scale: CGFloat) -> CGFloat { line * (0.6 + 0.3 * min(scale, 1)) }

    func frame(_ phase: MockTunnel.Phase, _ e: Double, start: GlyphMemo, memo: inout GlyphMemo, traits: UITraitCollection) -> GlyphFrame {
        var frame = GlyphFrame()
        var t: CGFloat = 0, k: CGFloat = 0, flow: CGFloat = 0
        // Inner arches to draw: conveyor place and opacity.
        var arches: [(p: CGFloat, opacity: CGFloat)] = []

        switch phase {
        case .off:
            break
        case .connecting:
            t = Ease.mix(start.a, 1, Ease.sine(e / Self.morphTime))
            flow = CGFloat(max(0, e - Self.lightsStart) / Self.step)
            arches = Self.places(flow).map { (p: $0, opacity: Self.lightOpacity($0)) }
        case .on:
            t = 1
            k = Ease.out(e / 0.3)
            // The front light runs out past the arch as an echo; the second takes the
            // first place, the third the second (out of the depth if it was there).
            let r = start.flow - floor(start.flow)
            let settle = Ease.out(e / 0.45)
            let back = r + (1 - r) * settle
            let middle = r + 1 + (1 - r) * settle
            let front = r + 2 + (2 - r) * Ease.out(e / 0.6)
            arches.append((back, Ease.keys(back, [0, 1], [0, 0.55])))
            arches.append((middle, Ease.keys(middle, [1, 2], [0.55, 0.8])))
            if front < 4 {
                arches.append((front, front <= 3 ? Ease.keys(front, [2, 3], [0.8, 0.7]) : 0.6 * (4 - front)))
            }
        case .disconnecting:
            k = start.k * (1 - Ease.out(e / 0.3))
            t = start.a * (1 - Ease.sine((e - 0.1) / Self.morphTime))
            let fade = 1 - Ease.out(e / 0.28)
            if start.k > 0 {
                // The two arches go back into the depth.
                arches.append((1 * fade, 0.55 * fade))
                arches.append((2 * fade, 0.8 * fade))
            } else {
                arches = Self.places(start.flow).map { (p: $0, opacity: Self.lightOpacity($0) * fade) }
            }
        }
        memo.a = t
        memo.k = k
        memo.flow = flow

        let color = ink.blended(green, k, traits)
        frame.strokes.append(Stroke(path: Self.body(t), color: color, width: line))
        // The stroke falls in under the arch and is gone (back up when stopping).
        let stroke = 1 - min(1, t * 1.4)
        if stroke > 0 {
            frame.strokes.append(Stroke(path: Shape.line(50, 24 + 28 * t, 50, 50 + 24 * t), color: color, width: line, opacity: stroke))
        }
        for item in arches where item.opacity > 0.001 {
            let scale = Self.scale(item.p)
            frame.strokes.append(Stroke(path: Shape.arch(scale: scale), color: color, width: Self.width(scale), opacity: item.opacity))
        }
        if light, k > 0 {
            frame.glows.append(Glow(center: CGPoint(x: 50, y: 63), radius: 15, color: green, opacity: 0.38 * k))
        }
        return frame
    }
}

// MARK: - 2. Ring

/// One way round the whole mark: the ring from the right of its gap, clockwise
/// to the left of it, a hop to the stroke's foot, up the stroke, a hop back to
/// the ring's right end. Route units are box units along the line.
private enum Route {
    static let ringLength: CGFloat = 22 * 300 * .pi / 180
    static let hop: CGFloat = 7
    static let stemLength: CGFloat = 26
    static let stemStart = ringLength + hop
    static let total = ringLength + hop + stemLength + hop
    static let stemMiddle = stemStart + stemLength / 2

    static var ring: CGPath { Shape.arc(50, 52, 22, -60, 240) }
    static var stem: CGPath { Shape.line(50, 24, 50, 50) }

    /// The parts of the route between `from` and `to` (any numbers, up to a full
    /// way round) that lie on the ring and on the stroke.
    static func paths(_ from: CGFloat, _ to: CGFloat) -> [CGPath] {
        guard to - from > 0.01 else { return [] }
        if to - from >= total - 0.01 { return [ring, stem] }
        var at = from.truncatingRemainder(dividingBy: total)
        if at < 0 { at += total }
        var left = to - from
        var result: [CGPath] = []
        while left > 0.001 {
            let piece = min(left, total - at)
            result += pieces(at, at + piece)
            left -= piece
            at = 0
        }
        return result
    }

    private static func pieces(_ a: CGFloat, _ b: CGFloat) -> [CGPath] {
        var out: [CGPath] = []
        let r0 = max(a, 0), r1 = min(b, ringLength)
        if r1 - r0 > 0.05 { out.append(Shape.arc(50, 52, 22, -60 + r0 / 22 * 180 / .pi, -60 + r1 / 22 * 180 / .pi)) }
        let s0 = max(a, stemStart), s1 = min(b, stemStart + stemLength)
        if s1 - s0 > 0.05 { out.append(Shape.line(50, 50 - (s0 - stemStart), 50, 50 - (s1 - stemStart))) }
        return out
    }
}

/// Connecting: the ring dims and a light stretch flows round the whole mark —
/// round the ring, into the stroke's foot, up it, and on into the ring's other
/// end. Connected: green spreads both ways from where the stretch stood until
/// the mark is whole, and the button breathes once. Stopping: the green leaves
/// from the middle of the stroke, both ways along the same route.
struct RingFillGlyph: GlyphStyle {
    let id = "ring2"
    let title = "2 · Кольцо (перетекание)"
    let note = "Полоска бежит по всему значку и палочке; зелёный растекается от неё, а уходит с палочки."

    private static let stretch: CGFloat = 34
    private static let lap: Double = 1.5

    func frame(_ phase: MockTunnel.Phase, _ e: Double, start: GlyphMemo, memo: inout GlyphMemo, traits _: UITraitCollection) -> GlyphFrame {
        var dim: CGFloat = 0, level: CGFloat = 0, scale: CGFloat = 1
        var head = start.comet, stretchOpacity: CGFloat = 0
        var greenPaths: [CGPath] = []
        let total = Route.total
        switch phase {
        case .off:
            break
        case .connecting:
            dim = Ease.mix(start.width, 1, Ease.out(e / 0.3))
            head = (Self.stretch + total * CGFloat(e / Self.lap)).truncatingRemainder(dividingBy: total)
            stretchOpacity = Ease.out(e / 0.25)
        case .on:
            dim = 1
            level = Ease.inOut(e / 0.7)
            let centre = start.comet - Self.stretch / 2
            let half = Self.stretch / 2 + (total / 2 - Self.stretch / 2) * level
            greenPaths = Route.paths(centre - half, centre + half)
            stretchOpacity = start.cometOpacity * (1 - Ease.out(e / 0.5))
            scale = 1 + 0.06 * sin(.pi * Ease.clamp((e - 0.62) / 0.5))
        case .disconnecting:
            let k = Ease.inOut(e / 0.6)
            dim = start.width * (1 - k)
            level = start.level * (1 - k)
            if start.level > 0 {
                // The colour leaves from the middle of the stroke, both ways.
                let gone = total / 2 * k
                greenPaths = Route.paths(Route.stemMiddle + gone, Route.stemMiddle - gone + total)
            }
            stretchOpacity = start.cometOpacity * (1 - Ease.out(e / 0.3))
        }
        memo.width = dim
        memo.level = level
        memo.comet = head
        memo.cometOpacity = stretchOpacity

        var frame = GlyphFrame()
        frame.scale = scale
        frame.strokes.append(Stroke(path: Route.ring, color: ink, width: line, opacity: 1 - 0.65 * dim))
        frame.strokes.append(Stroke(path: Route.stem, color: ink, width: line, opacity: 1 - 0.65 * dim))
        if stretchOpacity > 0 {
            for path in Route.paths(head - Self.stretch, head) {
                frame.strokes.append(Stroke(path: path, color: ink, width: line, opacity: stretchOpacity))
            }
        }
        for path in greenPaths {
            frame.strokes.append(Stroke(path: path, color: green, width: line))
        }
        return frame
    }
}
