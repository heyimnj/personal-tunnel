import Libbox
import SwiftUI
import TunnelKit

/// Checks that traffic flows: the VPN state, an HTTP request over the current
/// route and a URL test through the selected server.
struct ConnectionCheckView: View {
    @Environment(AppModel.self) private var model
    @State private var steps: [Step] = []
    @State private var running = false

    struct Step: Identifiable {
        let id = UUID()
        let title: String
        let ok: Bool?
        let detail: String
    }

    var body: some View {
        StyledList {
            Section(footer: Text(L("Запрос идёт на www.gstatic.com/generate_204 только по нажатию кнопки.")).font(appFont(.caption))) {
                Button(action: run) {
                    HStack {
                        Label(L("Проверить"), systemImage: "checkmark.seal")
                        Spacer()
                        if running { ProgressView() }
                    }
                }
                .disabled(running)
            }
            if !steps.isEmpty {
                Section(header: HeaderText(L("Результат"))) {
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: step.ok == nil ? "minus.circle" : (step.ok! ? "checkmark.circle.fill" : "xmark.octagon.fill"))
                                .foregroundStyle(step.ok == nil ? Color.secondary : (step.ok! ? Color.green : Color.red))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title).font(appFont(.body, weight: .medium))
                                Text(step.detail).font(appFont(.caption)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(L("Проверка соединения"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run() {
        running = true
        steps = []
        Task {
            let connected = model.tunnel.isConnected
            steps.append(Step(title: L("VPN"), ok: connected, detail: model.tunnel.status.title + (model.selectedServer.map { " · " + $0.displayName } ?? "")))

            var request = URLRequest(url: URL(string: Probe.testURL)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.httpMethod = "GET"
            let started = Date()
            var outcome = ""
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                outcome = "HTTP \(code), \(elapsed) " + L("мс")
                steps.append(Step(title: L("Доступ в интернет"), ok: code == 204, detail: outcome + (connected ? " · " + L("через VPN") : " · " + L("без VPN"))))
            } catch {
                outcome = L("ошибка сети")
                steps.append(Step(title: L("Доступ в интернет"), ok: false, detail: errorText(error)))
            }
            NetworkActivityLog.record(.describing(request, purpose: L("Проверка соединения"), outcome: outcome))

            if connected, let server = model.selectedServer {
                let tag = model.tunnelTag(for: server.id) ?? BuiltConfiguration.selectorTag
                let delay = await Probe.url(tag: tag, timeoutMilliseconds: 5000)
                steps.append(Step(
                    title: L("Сервер «%@»", server.displayName),
                    ok: delay != nil,
                    detail: delay.map { "generate_204: \($0) " + L("мс") } ?? L("сервер не ответил за 5 с")
                ))
            } else {
                steps.append(Step(title: L("Сервер"), ok: nil, detail: L("Подключите VPN, чтобы проверить сервер.")))
            }
            running = false
        }
    }
}

/// The live log of the core, redacted.
struct LogsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lines = model.core.logs
        ScrollViewReader { proxy in
            List(lines) { line in
                Text(line.message)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(color(line.level))
                    .textSelection(.enabled)
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                    .id(line.id)
            }
            .listStyle(.plain)
            .overlay {
                if lines.isEmpty {
                    Text(model.tunnel.isConnected ? L("Записей пока нет") : L("Журнал доступен, пока VPN подключён"))
                        .font(appFont(.subheadline))
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: model.core.logs.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .navigationTitle(L("Журнал ядра"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = model.core.logs.map(\.message).joined(separator: "\n")
                    model.show(.success, L("Журнал скопирован (без ключей и ссылок)"))
                } label: { Image(systemName: "doc.on.doc") }
                Button { model.core.clearLogs() } label: { Image(systemName: "trash") }
            }
        }
        .onAppear { model.core.wantsLogs = true }
        .onDisappear { model.core.wantsLogs = false }
    }

    private func color(_ level: Int32) -> Color {
        switch level {
        case ...2: return .red
        case 3: return .orange
        default: return .primary
        }
    }
}

/// Every request the app makes on its own, with masked values.
struct NetworkActivityView: View {
    @State private var entries: [NetworkActivityEntry] = []

    var body: some View {
        StyledList {
            Section(footer: Text(L("У приложения нет своего сервера. Само оно выходит в сеть, только чтобы обновить подписки, проверить соединение и измерить задержку. Ядро VPN делает запросы, которые задаёт конфигурация: DNS через выбранный сервер и проверку generate_204. Списки рекламы и обхода встроены и не скачиваются.")).font(appFont(.caption))) {
                if entries.isEmpty {
                    Text(L("Запросов пока не было")).foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(localizedMessage(entry.purpose)).font(appFont(.subheadline, weight: .semibold))
                            Spacer()
                            Text(entry.date, style: .time).font(appFont(.caption)).foregroundStyle(.secondary)
                        }
                        Text("\(entry.method) \(entry.target)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        ForEach(entry.headers, id: \.self) { header in
                            Text(header).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Text(localizedMessage(entry.outcome)).font(appFont(.caption)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle(L("Сетевая активность"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    NetworkActivityLog.clear()
                    entries = []
                } label: { Image(systemName: "trash") }
            }
        }
        .onAppear { entries = NetworkActivityLog.entries() }
    }
}
