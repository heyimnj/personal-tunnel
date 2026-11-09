import NetworkExtension
import SwiftUI
import TunnelKit

/// "Connection" tab: the power button and the current server, with
/// analytics one swipe down.
struct HomeView: View {
    let openServers: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var page: Int? = 0

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ConnectionPage(openServers: openServers, showAnalytics: { withAnimation { page = 1 } })
                        .frame(height: proxy.size.height)
                        .id(0)
                    AnalyticsView(isVisible: page == 1)
                        .frame(minHeight: proxy.size.height)
                        .id(1)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .scrollIndicators(.hidden)
        }
        .screenBackground(palette)
    }
}

private struct ConnectionPage: View {
    let openServers: () -> Void
    let showAnalytics: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 12)
            statusBlock
            Spacer(minLength: 24)
            ConnectButton(status: model.tunnel.status) {
                model.toggleConnection()
            }
            .disabled(model.selectedServer == nil && !model.tunnel.isActive)
            Spacer(minLength: 24)
            if let error = model.tunnelError, !model.tunnel.isActive {
                Text(error)
                    .font(appFont(.footnote))
                    .foregroundStyle(palette.failed)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
            }
            serverCard
                .padding(.horizontal, 16)
            trafficRow
                .padding(.horizontal, 16)
                .padding(.top, 10)
            Button(action: showAnalytics) {
                VStack(spacing: 2) {
                    Text(L("Аналитика")).font(appFont(.caption, weight: .medium))
                    Image(systemName: "chevron.compact.down").font(.system(size: 22, weight: .medium))
                }
                .foregroundStyle(palette.secondaryText)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var header: some View {
        HStack {
            Text("Personal Tunnel")
                .font(appFont(.title2, weight: .bold))
                .foregroundStyle(palette.primaryText)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var statusBlock: some View {
        VStack(spacing: 6) {
            Text(model.tunnel.status.title)
                .font(appFont(.title3, weight: .semibold))
                .foregroundStyle(statusColor)
                .contentTransition(.opacity)
            if let date = model.tunnel.connectedDate {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Format.duration(context.date.timeIntervalSince(date)))
                        .font(appFont(.subheadline, monospacedDigits: true))
                        .foregroundStyle(palette.secondaryText)
                }
            } else {
                Text(model.selectedServer == nil ? L("Добавьте подписку или сервер") : L("Нажмите, чтобы подключиться"))
                    .font(appFont(.subheadline))
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.tunnel.status)
    }

    private var statusColor: Color {
        switch model.tunnel.status {
        case .connected: return palette.connected
        case .connecting, .reasserting, .disconnecting: return palette.connecting
        default: return model.tunnelError == nil ? palette.primaryText : palette.failed
        }
    }

    @ViewBuilder
    private var serverCard: some View {
        Button(action: openServers) {
            HStack(spacing: 12) {
                if let server = model.selectedServer {
                    FlagView(server: server, size: 26)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.displayName)
                            .font(appFont(.headline))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            ForEach(server.protocolTags, id: \.self) { TagLabel(text: $0) }
                            if let subscription = model.selectedSubscription {
                                Text(subscription.name)
                                    .font(appFont(.caption))
                                    .foregroundStyle(palette.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    LatencyLabel(record: model.latency.record(server.id), isTesting: model.latency.testing.contains(server.id))
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(palette.accent)
                    Text(L("Выбрать сервер"))
                        .font(appFont(.headline))
                        .foregroundStyle(palette.primaryText)
                    Spacer()
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
            }
            .padding(14)
            .modifier(HomeCardBackground())
        }
        .buttonStyle(.plain)
    }

    private var trafficRow: some View {
        HStack(spacing: 10) {
            trafficTile(icon: "arrow.down", title: L("Загрузка"), value: model.core.status.map { Format.speed($0.downlink) } ?? "—", color: .cyan)
            trafficTile(icon: "arrow.up", title: L("Отдача"), value: model.core.status.map { Format.speed($0.uplink) } ?? "—", color: .pink)
            trafficTile(icon: "calendar", title: L("Сегодня"), value: Format.bytes(DailyTraffic.today()), color: palette.accent)
        }
    }

    private func trafficTile(icon: String, title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(appFont(.caption))
                .foregroundStyle(color)
                .lineLimit(1)
            Text(value)
                .font(appFont(.subheadline, weight: .semibold, monospacedDigits: true))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .modifier(HomeCardBackground(small: true))
    }
}

/// Glass in Modern, tonal cards in Material You, grouped cells in Classic.
struct HomeCardBackground: ViewModifier {
    var small = false
    @Environment(\.palette) private var palette

    @ViewBuilder
    func body(content: Content) -> some View {
        let radius: CGFloat = small ? (palette.appearance == .material ? 20 : 16) : palette.cardRadius
        switch palette.appearance {
        case .modern:
            content.glassSurface(in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        case .material:
            content.card(palette, radius: radius)
        case .classic:
            content.card(palette, radius: small ? 12 : 14)
        }
    }
}
