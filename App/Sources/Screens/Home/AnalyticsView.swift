import Charts
import SwiftUI
import TunnelKit

/// Session statistics: speed over the last two minutes, totals, traffic by
/// route and the recent connections the core reports.
struct AnalyticsView: View {
    /// Height of the scroll view, to tell when the analytics are on screen.
    let viewportHeight: CGFloat

    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("Аналитика"))
                    .font(appFont(.title2, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                Spacer()
                if let date = model.tunnel.connectedDate {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(L("Сеанс") + " " + Format.duration(context.date.timeIntervalSince(date)))
                            .font(appFont(.footnote, monospacedDigits: true))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
            }
            .padding(.top, 16)

            speedChart
            totals
            routes
            connectionList
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        // The connection list costs the extension work: stream it only while
        // the analytics are actually on screen.
        .background {
            GeometryReader { proxy in
                let onScreen = proxy.frame(in: .global).minY < viewportHeight * 0.75
                Color.clear
                    .onAppear { model.core.wantsConnections = onScreen }
                    .onChange(of: onScreen) { _, visible in model.core.wantsConnections = visible }
            }
        }
        .onDisappear { model.core.wantsConnections = false }
    }

    private var speedChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L("Скорость за 2 минуты"), systemImage: "waveform.path.ecg")
                    .font(appFont(.subheadline, weight: .medium))
                Spacer()
                legend(L("Загрузка"), .cyan)
                legend(L("Отдача"), .pink)
            }
            .foregroundStyle(palette.primaryText)
            if model.core.history.isEmpty {
                Text(model.tunnel.isConnected ? L("Данные появятся через пару секунд") : L("Данные появятся после подключения"))
                    .font(appFont(.caption))
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                Chart(model.core.history) { sample in
                    LineMark(x: .value("t", sample.date), y: .value("down", Double(sample.down)), series: .value("s", "down"))
                        .foregroundStyle(.cyan)
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", sample.date), y: .value("up", Double(sample.up)), series: .value("s", "up"))
                        .foregroundStyle(.pink)
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let bytes = value.as(Double.self) {
                                Text(Format.speed(Int64(bytes))).font(appFont(.caption2))
                            }
                        }
                    }
                }
                .frame(height: 150)
                .accessibilityLabel(L("График скорости загрузки и отдачи"))
            }
        }
        .padding(14)
        .modifier(HomeCardBackground())
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(appFont(.caption2))
        }
    }

    private var totals: some View {
        let status = model.core.status
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            tile(L("Получено"), status.map { Format.bytes($0.downlinkTotal) } ?? "—", icon: "arrow.down.circle", color: .cyan)
            tile(L("Отправлено"), status.map { Format.bytes($0.uplinkTotal) } ?? "—", icon: "arrow.up.circle", color: .pink)
            tile(L("Сегодня"), Format.bytes(DailyTraffic.today()), icon: "calendar", color: palette.accent)
            tile(L("Соединения"), status.map { "\($0.connections)" } ?? "—", icon: "point.3.connected.trianglepath.dotted", color: .orange)
            tile(L("Память VPN"), status.map { Format.bytes($0.memory) } ?? "—", icon: "memorychip", color: .purple)
            tile(L("Сервер"), model.selectedServer?.displayName ?? "—", icon: "server.rack", color: .green)
        }
    }

    private func tile(_ title: String, _ value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(appFont(.caption, weight: .medium))
                .foregroundStyle(color)
                .lineLimit(1)
            Text(value)
                .font(appFont(.headline, monospacedDigits: true))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .modifier(HomeCardBackground(small: true))
    }

    private struct RouteShare: Identifiable {
        let id: String
        let bytes: Int64
    }

    private var routeShares: [RouteShare] {
        var totals: [String: Int64] = [:]
        for connection in model.core.connections {
            let route: String
            switch connection.outboundType {
            case "direct": route = L("Напрямую")
            case "block": route = L("Заблокировано")
            default: route = connection.outbound
            }
            totals[route, default: 0] += connection.upload + connection.download
        }
        return totals.map { RouteShare(id: $0.key, bytes: $0.value) }.sorted { $0.bytes > $1.bytes }.prefix(6).map { $0 }
    }

    private var routes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("Маршруты соединений"), systemImage: "chart.pie")
                .font(appFont(.subheadline, weight: .medium))
                .foregroundStyle(palette.primaryText)
            let shares = routeShares
            if shares.isEmpty {
                Text(L("Данные соединений пока недоступны"))
                    .font(appFont(.caption))
                    .foregroundStyle(palette.secondaryText)
            } else {
                let total = max(1, shares.reduce(0) { $0 + $1.bytes })
                ForEach(shares) { share in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(share.id).lineLimit(1)
                            Spacer()
                            Text(Format.bytes(share.bytes)).monospacedDigit()
                        }
                        .font(appFont(.caption))
                        .foregroundStyle(palette.primaryText)
                        UsageBar(fraction: Double(share.bytes) / Double(total))
                    }
                }
                Text(L("По соединениям, которые ядро показало за время наблюдения."))
                    .font(appFont(.caption2))
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(HomeCardBackground())
    }

    private var connectionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("Соединения"), systemImage: "list.bullet.rectangle")
                .font(appFont(.subheadline, weight: .medium))
                .foregroundStyle(palette.primaryText)
            if model.core.connections.isEmpty {
                Text(L("Данные соединений пока недоступны"))
                    .font(appFont(.caption))
                    .foregroundStyle(palette.secondaryText)
            } else {
                ForEach(model.core.connections.prefix(40)) { connection in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(connection.isClosed ? Color.gray : palette.connected)
                            .frame(width: 7, height: 7)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connection.destination)
                                .font(appFont(.callout))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(connection.network.uppercased()) · \(connection.outbound) · ↓ \(Format.bytes(connection.download)) ↑ \(Format.bytes(connection.upload))")
                                .font(appFont(.caption2, monospacedDigits: true))
                                .foregroundStyle(palette.secondaryText)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(HomeCardBackground())
    }
}
