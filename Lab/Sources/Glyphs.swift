import UIKit

/// The variants of the connection button's glyph, in the order of the menu.
enum ConnectGlyphs {
    static let all: [GlyphStyle] = [
        CurrentGlyph(),
        TunnelGlyph(light: .none),
        TunnelGlyph(light: .still),
        TunnelGlyph(light: .breathing),
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

/// The power mark opens into the logo's arch, its stroke goes in under it, and
/// arches run towards you inside, like the lights of a tunnel. Connected: the
/// arch turns green with one glow. Stopping: back into the power mark.
/// `light`: what stands at the end of the tunnel once connected.
struct TunnelGlyph: GlyphStyle {
    enum Light { case none, still, breathing }
    let light: Light

    var id: String {
        switch light {
        case .none: return "tunnel"
        case .still: return "tunnel.light"
        case .breathing: return "tunnel.breathing"
        }
    }

    var title: String {
        switch light {
        case .none: return "1 · Тоннель"
        case .still: return "1 · Тоннель + свет в конце"
        case .breathing: return "1 · Тоннель + свет дышит"
        }
    }

    var note: String {
        switch light {
        case .none: return "Как в макете: значок раскрывается в арку, внутри бегут огни; подключено — арка зелёная."
        case .still: return "Подключено: в глубине арки загорается маленькая арка и мягкий зелёный свет — свет в конце тоннеля."
        case .breathing: return "То же, но свет в глубине медленно дышит (раз в 3.2 с), пока VPN включён."
        }
    }

    func frame(_ phase: MockTunnel.Phase, _ e: Double, start: GlyphMemo, memo: inout GlyphMemo, traits: UITraitCollection) -> GlyphFrame {
        var a: CGFloat = 0, legs: CGFloat = 0, k: CGFloat = 0, glowIn: CGFloat = 0
        switch phase {
        case .off:
            break
        case .connecting:
            a = Ease.mix(start.a, 1, Ease.inOut(e / 0.45))
            legs = Ease.mix(start.legs, 1, Ease.out((e - 0.33) / 0.26))
        case .on:
            a = 1
            legs = 1
            k = Ease.out(e / 0.35)
            glowIn = Ease.out((e - 0.25) / 0.6)
        case .disconnecting:
            legs = start.legs * (1 - Ease.out(e / 0.22))
            a = start.a * (1 - Ease.inOut((e - 0.12) / 0.43))
            k = start.k * (1 - Ease.out(e / 0.3))
            glowIn = start.light * (1 - Ease.out(e / 0.25))
        }
        memo.a = a
        memo.legs = legs
        memo.k = k
        memo.light = glowIn

        let color = ink.blended(green, k, traits)
        var frame = GlyphFrame()
        let centre = -90 + 180 * a, gap = 60 + 120 * a
        frame.strokes.append(Stroke(path: Shape.arc(50, 52, 22, centre + gap / 2, centre - gap / 2 + 360), color: color, width: line))
        if legs > 0 {
            frame.strokes.append(Stroke(path: Shape.line(28, 52, 28, 52 + 22 * legs), color: color, width: line))
            frame.strokes.append(Stroke(path: Shape.line(72, 52, 72, 52 + 22 * legs), color: color, width: line))
        }
        let stemFade = 1 - min(1, a * 1.4)
        if stemFade > 0 {
            frame.strokes.append(Stroke(path: Shape.line(50, 24 + 28 * a, 50, 50 + 24 * a), color: color, width: line, opacity: stemFade))
        }
        // Lights of the tunnel, coming towards you.
        if phase == .connecting, e > 0.62 {
            for index in 0 ..< 3 {
                let q = CGFloat(((e - 0.62) / 0.95 + Double(index) / 3).truncatingRemainder(dividingBy: 1))
                let scale = 0.12 + 0.82 * q
                frame.strokes.append(Stroke(path: Shape.arch(scale: scale), color: ink, width: (3.2 * scale + 1) * 0.67, opacity: sin(.pi * q) * 0.75))
            }
        }
        // One glow round the arch when it turns green.
        if phase == .on, e < 0.7 {
            let q = CGFloat(e / 0.7)
            frame.strokes.append(Stroke(path: Shape.arch(scale: 1 + 0.3 * Ease.out(e / 0.7)), color: green, width: 2, opacity: 0.6 * (1 - q)))
        }
        // The light at the end of the tunnel.
        if light != .none, glowIn > 0 {
            var breath: CGFloat = 1
            if light == .breathing, phase == .on {
                breath = 0.72 + 0.28 * CGFloat(0.5 + 0.5 * cos(2 * .pi * max(0, e - 0.85) / 3.2))
            }
            frame.glows.append(Glow(center: CGPoint(x: 50, y: 63), radius: 15, color: green, opacity: 0.42 * glowIn * breath))
            frame.strokes.append(Stroke(path: Shape.arch(scale: 0.38), color: green, width: 2.2, opacity: 0.85 * glowIn * (0.6 + 0.4 * breath)))
        }
        return frame
    }
}

// MARK: - 2. Ring

/// The ring dims and a light stretch walks along it while connecting. Connected:
/// green rises from below with a soft edge and the button breathes once.
/// Stopping: the green runs down and out, the grey comes back — no refill.
struct RingFillGlyph: GlyphStyle {
    let id = "ring"
    let title = "2 · Кольцо (новая заливка)"
    let note = "Зелёный поднимается снизу с мягким краем; при отключении плавно стекает вниз, без повторной заливки."

    func frame(_ phase: MockTunnel.Phase, _ e: Double, start: GlyphMemo, memo: inout GlyphMemo, traits _: UITraitCollection) -> GlyphFrame {
        var level: CGFloat = 0, dim: CGFloat = 0, scale: CGFloat = 1
        var comet = start.comet, cometOpacity: CGFloat = 0
        var stemPulse: CGFloat = 0
        switch phase {
        case .off:
            break
        case .connecting:
            let fade = Ease.out(e / 0.3)
            dim = Ease.mix(start.width, 1, fade)
            let t = (e / 1.1).truncatingRemainder(dividingBy: 2)
            let u = e < 0.3 ? 0 : Ease.inOut(abs(t - 1) < 1 ? 1 - abs(t - 1) : 0)
            comet = -60 + 230 * u
            cometOpacity = fade
            stemPulse = fade * CGFloat(0.5 + 0.5 * sin(e / 0.18))
        case .on:
            dim = 1
            level = Ease.mix(start.level, 1, Ease.inOut(e / 0.75))
            cometOpacity = start.cometOpacity * (1 - Ease.out(e / 0.4))
            scale = 1 + 0.06 * sin(.pi * Ease.clamp((e - 0.6) / 0.5))
        case .disconnecting:
            let k = Ease.inOut(e / 0.6)
            level = start.level * (1 - k)
            dim = start.width * (1 - k)
            cometOpacity = start.cometOpacity * (1 - Ease.out(e / 0.25))
        }
        memo.level = level
        memo.width = dim
        memo.comet = comet
        memo.cometOpacity = cometOpacity

        var frame = GlyphFrame()
        frame.scale = scale
        let ring = Shape.arc(50, 52, 22, -60, 240)
        let stem = Shape.line(50, 24, 50, 50)
        frame.strokes.append(Stroke(path: ring, color: ink, width: line, opacity: 1 - 0.65 * dim))
        frame.strokes.append(Stroke(path: stem, color: ink, width: line, opacity: 1 - 0.55 * dim - 0.3 * stemPulse))
        if cometOpacity > 0 {
            frame.strokes.append(Stroke(path: Shape.arc(50, 52, 22, comet, comet + 70), color: ink, width: line, opacity: cometOpacity))
        }
        if level > 0 {
            frame.fill = [Stroke(path: ring, color: green, width: line), Stroke(path: stem, color: green, width: line)]
            // Level 0: the edge below the ring; 1: above the stroke's top.
            frame.fillEdge = 0.86 - 0.76 * level
            frame.fillFeather = 0.12
        }
        return frame
    }
}
