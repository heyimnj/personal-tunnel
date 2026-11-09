import NetworkExtension
import SwiftUI

/// The Material 3 Expressive "cookie": a circle with scalloped edges.
/// `depth` 0 is a circle, so the shape morphs smoothly when animated.
struct CookieShape: Shape {
    var lobes: Int = 9
    var depth: CGFloat

    var animatableData: CGFloat {
        get { depth }
        set { depth = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let base = radius * (1 - depth)
        var path = Path()
        let steps = 180
        for step in 0 ... steps {
            let angle = Double(step) / Double(steps) * 2 * .pi
            let wave = (cos(Double(lobes) * angle) + 1) / 2
            let r = base + radius * depth * CGFloat(wave)
            let point = CGPoint(x: center.x + r * CGFloat(cos(angle - .pi / 2)), y: center.y + r * CGFloat(sin(angle - .pi / 2)))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// The big power button on the home screen.
struct ConnectButton: View {
    let status: NEVPNStatus
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var spin = false
    @State private var pressed = false

    private var isOn: Bool { status == .connected }
    private var isBusy: Bool { status == .connecting || status == .disconnecting || status == .reasserting }

    var body: some View {
        Button(action: action) {
            ZStack {
                switch palette.appearance {
                case .material: materialBody
                case .modern: modernBody
                case .classic: classicBody
                }
                Image(systemName: "power")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 190, height: 190)
            .scaleEffect(pressed ? 0.94 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(PressReportingStyle(pressed: $pressed))
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: pressed)
        .animation(.easeInOut(duration: 0.35), value: status)
        .accessibilityLabel(isOn ? L("Отключить") : L("Подключить"))
        .onAppear { spin = isBusy }
        .onChange(of: isBusy) { _, busy in spin = busy }
    }

    private var iconColor: Color {
        switch palette.appearance {
        case .material: return isOn ? palette.onAccent : palette.onAccentContainer
        default: return isOn ? .white : palette.accent
        }
    }

    private var stateColor: Color {
        if isOn { return palette.accent }
        if isBusy { return palette.connecting }
        return palette.secondaryText.opacity(0.35)
    }

    // Classic: a solid disk with a progress ring.
    private var classicBody: some View {
        ZStack {
            Circle().fill(isOn ? palette.accent : palette.surface)
            Circle().stroke(stateColor, lineWidth: isOn ? 0 : 3)
            if isBusy {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(palette.connecting, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
            }
        }
        .shadow(color: isOn ? palette.accent.opacity(0.35) : .black.opacity(0.08), radius: isOn ? 22 : 10, y: 6)
    }

    // Modern: glass with an accent glow when connected.
    @ViewBuilder
    private var modernBody: some View {
        ZStack {
            Circle()
                .fill(isOn ? palette.accent.gradient : palette.surface.gradient)
                .shadow(color: isOn ? palette.accent.opacity(0.45) : .black.opacity(0.1), radius: isOn ? 30 : 12, y: 8)
            if !isOn {
                Circle()
                    .fill(Color.clear)
                    .glassSurface(in: Circle(), tint: isBusy ? palette.connecting.opacity(0.25) : nil, interactive: true)
            }
            if isBusy {
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(palette.connecting, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .padding(-8)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
            }
        }
    }

    // Material You: the cookie turns into a circle when connected and turns
    // slowly while connecting.
    private var materialBody: some View {
        CookieShape(depth: isOn ? 0 : 0.07)
            .fill(isOn ? palette.accent : palette.accentContainer)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(isBusy ? .linear(duration: 6).repeatForever(autoreverses: false) : .spring(response: 0.6, dampingFraction: 0.7), value: spin)
            .animation(.spring(response: 0.55, dampingFraction: 0.65), value: isOn)
    }
}

/// Reports the pressed state so the button can spring.
struct PressReportingStyle: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, value in
                pressed = value
            }
    }
}
