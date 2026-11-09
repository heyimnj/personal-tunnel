import NetworkExtension
import SwiftUI
import TunnelKit

// MARK: - Formatting

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .binary)
    }

    static func speed(_ bytesPerSecond: Int64) -> String {
        bytes(bytesPerSecond) + L("/с")
    }

    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppSettings.shared.effectiveLanguage == .en ? "en_US" : "ru_RU")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: AppSettings.shared.effectiveLanguage == .en ? "en_US" : "ru_RU")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

extension NEVPNStatus {
    var title: String {
        switch self {
        case .connected: return L("Подключено")
        case .connecting: return L("Подключение…")
        case .disconnecting: return L("Отключение…")
        case .reasserting: return L("Переподключение…")
        case .disconnected: return L("Отключено")
        case .invalid: return L("Не настроено")
        @unknown default: return L("Отключено")
        }
    }
}

// MARK: - Surfaces

extension View {
    /// The card surface of the current appearance.
    func card(_ palette: Palette, radius: CGFloat? = nil, color: Color? = nil) -> some View {
        background(color ?? palette.surface, in: RoundedRectangle(cornerRadius: radius ?? palette.cardRadius, style: .continuous))
    }

    /// Liquid Glass on iOS 26, a blur material before it.
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint), in: shape)
            } else {
                glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
            }
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        }
    }

    /// The screen background of the current appearance.
    func screenBackground(_ palette: Palette) -> some View {
        background(palette.background.ignoresSafeArea())
    }
}

// MARK: - Small pieces

/// A protocol, transport or security label.
struct TagLabel: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text)
            .font(appFont(.caption2, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(TagLabel.color(for: text))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(TagLabel.color(for: text).opacity(palette.scheme == .dark ? 0.22 : 0.12), in: Capsule())
    }

    static func color(for tag: String) -> Color {
        switch tag {
        case "VLESS": return .blue
        case "VMess": return .indigo
        case "Trojan": return .purple
        case "Shadowsocks": return .teal
        case "Hysteria2", "Hysteria": return .orange
        case "TUIC": return .pink
        case "WireGuard", "AmneziaWG": return .green
        case "Reality": return .mint
        case "TLS": return .cyan
        case "Vision": return .brown
        default: return .gray
        }
    }
}

/// Latency of a server: "84 мс", colour-coded, or a spinner while measured.
struct LatencyLabel: View {
    let record: LatencyRecord?
    let isTesting: Bool

    var body: some View {
        Group {
            if isTesting, record == nil {
                ProgressView().controlSize(.mini)
            } else if let record {
                if let value = record.milliseconds {
                    HStack(spacing: 2) {
                        if record.isUnstable {
                            Image(systemName: "waveform.path").font(.system(size: 9, weight: .bold))
                        }
                        Text("\(value) " + L("мс"))
                    }
                    .foregroundStyle(LatencyLabel.color(value, kind: record.latest.kind))
                } else {
                    Text(L("нет ответа")).foregroundStyle(.secondary)
                }
            } else {
                EmptyView()
            }
        }
        .font(appFont(.caption, monospacedDigits: true))
        .lineLimit(1)
        .fixedSize()
        .opacity(isTesting && record != nil ? 0.5 : 1)
    }

    static func color(_ milliseconds: Int, kind: LatencyKind) -> Color {
        let scale = kind == .tcp ? 0.6 : 1
        switch Double(milliseconds) * (1 / scale) {
        case ..<300: return Color(red: 0.2, green: 0.72, blue: 0.35)
        case ..<700: return .orange
        default: return .red
        }
    }
}

/// Flag of the server's country, or a globe.
struct FlagView: View {
    let server: Server
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let country = server.country {
                Text(country.flag).font(.system(size: size))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size + 6, height: size + 6)
    }
}

/// A transient message at the top of the screen.
struct BannerView: View {
    let banner: Banner
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(banner.text)
                .font(appFont(.subheadline))
                .foregroundStyle(palette.primaryText)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 16)
    }

    private var icon: String {
        switch banner.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch banner.kind {
        case .info: return palette.accent
        case .success: return palette.connected
        case .error: return palette.failed
        }
    }
}

/// A row with an icon in a tinted square (settings).
struct IconLabel: View {
    let title: String
    let systemImage: String
    var tint: Color? = nil
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.appearance == .material ? palette.onAccentContainer : .white)
                .frame(width: 30, height: 30)
                .background(iconBackground, in: iconShape)
            Text(title)
                .font(appFont(.body))
                .foregroundStyle(palette.primaryText)
        }
    }

    private var iconBackground: Color {
        palette.appearance == .material ? palette.accentContainer : (tint ?? palette.accent)
    }

    private var iconShape: AnyShape {
        palette.appearance == .material ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Settings list styled for the current appearance.
struct StyledList<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.palette) private var palette

    var body: some View {
        List {
            content
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(palette.background.ignoresSafeArea())
        .listRowSpacing(palette.appearance == .material ? 2 : 0)
        .environment(\.defaultMinListRowHeight, palette.appearance == .material ? 56 : 44)
    }
}

/// Section header text in the app font.
struct HeaderText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).font(appFont(.footnote, weight: .medium))
    }
}

/// A usage bar for subscription quota.
struct UsageBar: View {
    let fraction: Double
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.secondaryText.opacity(0.18))
                Capsule()
                    .fill(fraction > 0.9 ? palette.failed : palette.accent)
                    .frame(width: max(4, proxy.size.width * fraction))
            }
        }
        .frame(height: 4)
    }
}
