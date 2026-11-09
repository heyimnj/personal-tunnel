import AppIntents
import SwiftUI
import TunnelKit
import WidgetKit

@main
struct PersonalTunnelWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        TunnelControl()
    }
}

// MARK: - Home screen and Lock Screen

struct StatusEntry: TimelineEntry {
    let date: Date
    let isOn: Bool
    let serverName: String
    let flag: String
    let today: Int64
}

struct StatusProvider: TimelineProvider {
    func placeholder(in _: Context) -> StatusEntry {
        StatusEntry(date: Date(), isOn: true, serverName: "Germany", flag: "🇩🇪", today: 0)
    }

    func getSnapshot(in _: Context, completion: @escaping (StatusEntry) -> Void) {
        Task { completion(await StatusProvider.entry()) }
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        Task {
            let entry = await StatusProvider.entry()
            completion(Timeline(entries: [entry], policy: .after(Date(timeIntervalSinceNow: 15 * 60))))
        }
    }

    static func entry() async -> StatusEntry {
        let defaults = SharedContainer.defaults
        return StatusEntry(
            date: Date(),
            isOn: await TunnelSwitch.isOn(),
            serverName: defaults.string(forKey: SharedKey.activeServerName) ?? "",
            flag: defaults.string(forKey: SharedKey.activeServerFlag) ?? "",
            today: DailyTraffic.today(defaults)
        )
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.personaltunnelapp.widget.status", provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Personal Tunnel")
        .description(Text("Состояние VPN и кнопка подключения."))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct StatusWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Button(intent: ToggleTunnelIntent()) {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: entry.isOn ? "lock.shield.fill" : "power")
                        .font(.system(size: 20, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label(entry.isOn ? "Подключено" : "Отключено", systemImage: entry.isOn ? "lock.shield.fill" : "lock.open")
                    .font(.headline)
                Text(entry.flag + " " + entry.serverName).font(.caption).lineLimit(1)
            }
        case .systemMedium:
            HStack(spacing: 16) {
                statusColumn
                Spacer()
                toggleButton(size: 64)
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: entry.isOn ? "lock.shield.fill" : "lock.open")
                        .foregroundStyle(entry.isOn ? Color.green : Color.secondary)
                    Spacer()
                    toggleButton(size: 40)
                }
                Spacer(minLength: 0)
                statusColumn
            }
        }
    }

    private var statusColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.isOn ? "Подключено" : "Отключено")
                .font(.headline)
                .foregroundStyle(entry.isOn ? Color.green : Color.primary)
            Text(entry.serverName.isEmpty ? "Сервер не выбран" : entry.flag + " " + entry.serverName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if entry.today > 0 {
                Text("Сегодня " + ByteCountFormatter.string(fromByteCount: entry.today, countStyle: .binary))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func toggleButton(size: CGFloat) -> some View {
        Button(intent: ToggleTunnelIntent()) {
            Image(systemName: "power")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(entry.isOn ? Color.white : Color.accentColor)
                .frame(width: size, height: size)
                .background(entry.isOn ? Color.green : Color.accentColor.opacity(0.15), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Control Center

struct TunnelControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.personaltunnelapp.widget.ServiceToggle", provider: TunnelControlProvider()) { isOn in
            ControlWidgetToggle("Personal Tunnel", isOn: isOn, action: SetTunnelIntent()) { on in
                Label(on ? "Подключено" : "Отключено", systemImage: on ? "lock.shield.fill" : "lock.open")
            }
        }
        .displayName("Personal Tunnel")
        .description("Включает и выключает VPN.")
    }
}

struct TunnelControlProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        await TunnelSwitch.isOn()
    }
}
