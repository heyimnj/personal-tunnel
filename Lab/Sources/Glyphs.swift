import UIKit

/// The variants of the connection button's glyph, in the order of the menu.
enum ConnectGlyphs {
    static let all: [GlyphStyle] = [
        CurrentGlyph(),
        TunnelGlyph(light: false),
        TunnelGlyph(light: true),
        RingFillGlyph(),
    ]

    static func style(_ id: String) -> GlyphStyle {
        all.first { $0.id == id } ?? all[1]
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

/// The power mark opens into the logo's arch in one line (the legs grow out of
/// the arc's own ends), its stroke goes in under it, and arches run towards you
/// inside, like the lights of a tunnel. Connected: the arch turns green, one echo
/// runs outside it, and two smaller arches stay inside — the logo's stripes.
/// Stopping: the stripes go in, the legs draw up, the arch closes back.
struct TunnelGlyph: GlyphStyle {
    /// A soft green light deep inside, once connected.
    let light: Bool

    var id: String { light ? "tunnel2.light" : "tunnel2" }
    var title: String { light ? "1 · Тоннель + свет" : "1 · Тоннель" }
    var note: String {
        light
            ? "То же, что «Тоннель», и в глубине арки мягкий зелёный свет."
            : "Значок одной линией раскрывается в арку; подключено — арка зелёная, эхо снаружи и две арки внутри, как полоски логотипа."
    }

    private static let stripeScale: [CGFloat] = [0.7, 0.44]
    private static let stripeOpacity: [CGFloat] = [0.8, 0.55]
    private static let stripeWidth: [CGFloat] = [line * 0.9, line * 0.78]

    func frame(_ phase: MockTunnel.Phase, _ e: Double, start: GlyphMemo, memo: inout GlyphMemo, traits: UITraitCollection) -> GlyphFrame {
        var a: CGFloat = 0, legs: CGFloat = 0, k: CGFloat = 0, stripes: CGFloat = 0
        switch phase {
        case .off:
            break
        case .connecting:
            a = Ease.mix(start.a, 1, Ease.sine(e / 0.6))
            legs = Ease.mix(start.legs, 1, Ease.out((e - 0.42) / 0.35))
        case .on:
            a = 1
            legs = 1
            k = Ease.out(e / 0.35)
            stripes = Ease.out((e - 0.12) / 0.55)
        case .disconnecting:
            stripes = start.stripes * (1 - Ease.out(e / 0.25))
            k = start.k * (1 - Ease.out(e / 0.35))
            legs = start.legs * (1 - Ease.inOut((e - 0.1) / 0.3))
            a = start.a * (1 - Ease.sine((e - 0.25) / 0.5))
        }
        memo.a = a
        memo.legs = legs
        memo.k = k
        memo.stripes = stripes

        let color = ink.blended(green, k, traits)
        var frame = GlyphFrame()
        // The arc and its legs in one line, so there is no seam where they meet.
        let centre = -90 + 180 * a, gap = 60 + 120 * a
        let from = (centre + gap / 2) * .pi / 180, to = (centre - gap / 2 + 360) * .pi / 180
        let p0 = CGPoint(x: 50 + 22 * cos(from), y: 52 + 22 * sin(from))
        let p1 = CGPoint(x: 50 + 22 * cos(to), y: 52 + 22 * sin(to))
        let body = CGMutablePath()
        if legs > 0.001 {
            body.move(to: CGPoint(x: p0.x, y: p0.y + 22 * legs))
            body.addLine(to: p0)
        } else {
            body.move(to: p0)
        }
        body.addArc(center: CGPoint(x: 50, y: 52), radius: 22, startAngle: from, endAngle: to, clockwise: false)
        if legs > 0.001 { body.addLine(to: CGPoint(x: p1.x, y: p1.y + 22 * legs)) }
        frame.strokes.append(Stroke(path: body, color: color, width: line))

        let stemFade = 1 - min(1, a * 1.4)
        if stemFade > 0 {
            frame.strokes.append(Stroke(path: Shape.line(50, 24 + 28 * a, 50, 50 + 24 * a), color: color, width: line, opacity: stemFade))
        }
        // Lights of the tunnel, coming towards you, once the arch stands.
        if phase == .connecting, e > 0.75 {
            for index in 0 ..< 3 {
                let q = CGFloat(((e - 0.75) / 0.95 + Double(index) / 3).truncatingRemainder(dividingBy: 1))
                let scale = 0.12 + 0.82 * q
                let appear = Ease.out((e - 0.75) / 0.3)
                frame.strokes.append(Stroke(path: Shape.arch(scale: scale), color: ink, width: (3.2 * scale + 1) * 0.67, opacity: sin(.pi * q) * 0.75 * appear))
            }
        }
        // The stripes: two smaller arches that come out of the depth and stay.
        if stripes > 0 {
            for index in 0 ..< Self.stripeScale.count {
                let own: CGFloat
                if phase == .on {
                    own = Ease.out((e - 0.12 - 0.09 * Double(index)) / 0.5)
                } else {
                    own = stripes
                }
                guard own > 0 else { continue }
                let scale = 0.12 + (Self.stripeScale[index] - 0.12) * own
                frame.strokes.append(Stroke(path: Shape.arch(scale: scale), color: color, width: Self.stripeWidth[index], opacity: Self.stripeOpacity[index] * own))
            }
        }
        // One echo round the arch when it turns green.
        if phase == .on, e < 0.7 {
            let q = CGFloat(e / 0.7)
            frame.strokes.append(Stroke(path: Shape.arch(scale: 1 + 0.3 * Ease.out(e / 0.7)), color: green, width: 2, opacity: 0.6 * (1 - q)))
        }
        if light, stripes > 0 {
            frame.glows.append(Glow(center: CGPoint(x: 50, y: 63), radius: 15, color: green, opacity: 0.38 * stripes))
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
