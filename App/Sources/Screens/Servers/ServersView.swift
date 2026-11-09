import SwiftUI
import TunnelKit
import UniformTypeIdentifiers

enum ServersRoute: Hashable {
    case server(UUID)
    case subscription(UUID)
    case manage
}

enum ServersSheet: Identifiable {
    case add
    case scanner

    var id: String {
        switch self {
        case .add: return "add"
        case .scanner: return "scanner"
        }
    }
}

/// "Servers" tab.
struct ServersView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var path: [ServersRoute] = []
    @State private var sheet: ServersSheet?
    @State private var importingFile = false
    @State private var visible: Set<UUID> = []

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(L("Серверы"))
                .toolbar { toolbar }
                .navigationDestination(for: ServersRoute.self) { route in
                    switch route {
                    case let .server(id): ServerDetailView(serverID: id)
                    case let .subscription(id): SubscriptionEditorView(subscriptionID: id)
                    case .manage: ManageSubscriptionsView()
                    }
                }
                .refreshable { await model.refreshAll() }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .add: AddSheet()
            case .scanner: QRScannerSheet { text in
                    sheet = nil
                    Task { await model.importContent(text) }
                }
            }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.json, .yaml, .plainText, .data, .item]) { result in
            guard case let .success(url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let name = url.deletingPathExtension().lastPathComponent
                Task { await model.importContent(text, sourceName: name) }
            } else {
                model.show(.error, L("Не удалось прочитать файл."))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.library.subscriptions.allSatisfy({ $0.servers.isEmpty && !$0.isRemote }) {
            EmptyServersView(add: { sheet = .add }, paste: paste, scan: { sheet = .scanner })
                .screenBackground(palette)
        } else if palette.appearance == .classic {
            ClassicServerList(path: $path, visible: $visible)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    latencyCaption
                        .padding(.horizontal, 6)
                    LazyVStack(spacing: 12) {
                        ForEach(model.library.subscriptions) { subscription in
                            SubscriptionCard(subscription: subscription, path: $path, visible: $visible)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .screenBackground(palette)
        }
    }

    private var latencyCaption: some View {
        Group {
            if model.latency.isRunning {
                Text(L("Проверка задержки: %d из %d", model.latency.completed, model.latency.total))
            } else if let date = model.latency.lastFinished {
                Text(L("Задержка измерена %@", Format.relative(date)))
            } else {
                Text(model.tunnel.isConnected ? L("Задержка проверяется через сервер") : L("Без VPN доступна только TCP-проверка"))
            }
        }
        .font(appFont(.caption))
        .foregroundStyle(palette.secondaryText)
        .lineLimit(1)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                model.testLatency(subscriptionID: nil, visible: visible)
            } label: {
                if model.latency.isRunning {
                    Image(systemName: "stop.circle.fill")
                } else {
                    Image(systemName: "bolt.horizontal.circle")
                }
            }
            .accessibilityLabel(model.latency.isRunning ? L("Остановить проверку") : L("Проверить задержку"))

            Menu {
                Button { sheet = .add } label: { Label(L("Добавить подписку"), systemImage: "link.badge.plus") }
                Button(action: paste) { Label(L("Вставить из буфера"), systemImage: "doc.on.clipboard") }
                Button { sheet = .scanner } label: { Label(L("Сканировать QR-код"), systemImage: "qrcode.viewfinder") }
                Button { importingFile = true } label: { Label(L("Импорт из файла"), systemImage: "doc.badge.plus") }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(L("Добавить"))

            Menu {
                Toggle(isOn: Binding(get: { model.settings.sortByLatency }, set: { value in
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { model.settings.sortByLatency = value }
                })) {
                    Label(L("Сортировать по задержке"), systemImage: "arrow.up.arrow.down")
                }
                Button {
                    Task { await model.refreshAll() }
                } label: { Label(L("Обновить все подписки"), systemImage: "arrow.clockwise") }
                Button { path.append(.manage) } label: { Label(L("Управление подписками"), systemImage: "list.bullet") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            model.show(.error, L("В буфере обмена нет текста."))
            return
        }
        Task { await model.importContent(text) }
    }
}

// MARK: - Empty state

private struct EmptyServersView: View {
    let add: () -> Void
    let paste: () -> Void
    let scan: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(palette.accent)
            Text(L("Серверов пока нет"))
                .font(appFont(.title3, weight: .semibold))
            Text(L("Добавьте ссылку подписки или вставьте ссылки серверов (vless://, vmess://, trojan://, ss://, hy2://, tuic://, wireguard://)."))
                .font(appFont(.subheadline))
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            VStack(spacing: 10) {
                Button(action: add) {
                    Label(L("Добавить подписку"), systemImage: "link.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(action: paste) {
                    Label(L("Вставить из буфера"), systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button(action: scan) {
                    Label(L("Сканировать QR-код"), systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .font(appFont(.body, weight: .medium))
            .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
    }
}

// MARK: - Modern and Material You

/// A subscription that expands into a container holding its servers.
struct SubscriptionCard: View {
    let subscription: Subscription
    @Binding var path: [ServersRoute]
    @Binding var visible: Set<UUID>

    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var confirmDelete = false

    private var expanded: Bool { model.settings.expandedSubscriptions.contains(subscription.id.uuidString) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                LazyVStack(spacing: 6) {
                    ForEach(model.orderedServers(subscription)) { server in
                        ServerRow(server: server, path: $path)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(rowBackground(server), in: RoundedRectangle(cornerRadius: palette.innerRadius, style: .continuous))
                            .onAppear { visible.insert(server.id) }
                            .onDisappear { visible.remove(server.id) }
                    }
                    if subscription.servers.isEmpty {
                        Text(subscription.lastError ?? L("В подписке нет серверов"))
                            .font(appFont(.footnote))
                            .foregroundStyle(palette.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(expanded ? palette.container : palette.surface, in: RoundedRectangle(cornerRadius: expanded ? palette.cardRadius : palette.collapsedRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: expanded ? palette.cardRadius : palette.collapsedRadius, style: .continuous))
        .opacity(subscription.isEnabled ? 1 : 0.55)
        .confirmationDialog(L("Удалить «%@»?", subscription.name), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Удалить"), role: .destructive) { model.deleteSubscription(subscription.id) }
        }
    }

    private func rowBackground(_ server: Server) -> Color {
        server.id == model.library.selectedServerID ? palette.accentContainer : palette.inner
    }

    private var header: some View {
        Button {
            Haptics.light()
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                if expanded {
                    model.settings.expandedSubscriptions.remove(subscription.id.uuidString)
                } else {
                    model.settings.expandedSubscriptions.insert(subscription.id.uuidString)
                }
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(subscription.name)
                        .font(appFont(.headline))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if expanded {
                        SubscriptionSubtitle(subscription: subscription)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 8)
                if model.refreshing.contains(subscription.id) {
                    ProgressView().controlSize(.small)
                }
                Text("\(subscription.servers.count)")
                    .font(appFont(.subheadline, weight: .medium, monospacedDigits: true))
                    .foregroundStyle(subscriptionHasSelection ? palette.accent : palette.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(minHeight: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            SubscriptionMenu(subscription: subscription, path: $path, confirmDelete: $confirmDelete)
        }
    }

    private var subscriptionHasSelection: Bool {
        subscription.servers.contains { $0.id == model.library.selectedServerID }
    }
}

/// "Valid until …", quota and last error under the subscription name.
struct SubscriptionSubtitle: View {
    let subscription: Subscription
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = subscription.lastError {
                Text(error)
                    .foregroundStyle(palette.failed)
                    .lineLimit(2)
            } else if let expires = subscription.info.expiresAt {
                Text(L("Действует до %@", Format.date(expires)))
                    .foregroundStyle(expires < Date() ? palette.failed : palette.secondaryText)
            } else if let updated = subscription.lastUpdated, subscription.isRemote {
                Text(L("Обновлено %@", Format.relative(updated)))
                    .foregroundStyle(palette.secondaryText)
            }
            if let fraction = subscription.info.usageFraction, let used = subscription.info.usedBytes, let total = subscription.info.totalBytes {
                HStack(spacing: 6) {
                    UsageBar(fraction: fraction).frame(width: 80)
                    Text("\(Format.bytes(used)) / \(Format.bytes(total))")
                        .foregroundStyle(palette.secondaryText)
                }
            }
        }
        .font(appFont(.caption))
        .lineLimit(1)
    }
}

/// The context menu of a subscription.
struct SubscriptionMenu: View {
    let subscription: Subscription
    @Binding var path: [ServersRoute]
    @Binding var confirmDelete: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(subscription.name)
        if subscription.isRemote {
            Button {
                Task { await model.refresh(subscription.id) }
            } label: { Label(L("Обновить"), systemImage: "arrow.clockwise") }
        }
        Button {
            model.testLatency(subscriptionID: subscription.id)
        } label: { Label(L("Проверить задержку"), systemImage: "bolt.horizontal") }
        Button {
            path.append(.subscription(subscription.id))
        } label: { Label(L("Изменить"), systemImage: "pencil") }
        if let url = subscription.url {
            Button {
                UIPasteboard.general.string = url
                model.show(.success, L("Ссылка подписки скопирована"))
            } label: { Label(L("Скопировать ссылку"), systemImage: "doc.on.doc") }
        }
        if let support = subscription.info.supportURL, let url = URL(string: support) {
            Link(destination: url) { Label(L("Поддержка"), systemImage: "questionmark.bubble") }
        }
        Button {
            model.setSubscriptionEnabled(subscription.id, !subscription.isEnabled)
        } label: {
            Label(subscription.isEnabled ? L("Отключить") : L("Включить"), systemImage: subscription.isEnabled ? "pause.circle" : "play.circle")
        }
        Divider()
        Button(role: .destructive) {
            confirmDelete = true
        } label: { Label(L("Удалить"), systemImage: "trash") }
    }
}

// MARK: - Server row

struct ServerRow: View {
    let server: Server
    @Binding var path: [ServersRoute]
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    private var isSelected: Bool { server.id == model.library.selectedServerID }

    var body: some View {
        Button {
            model.select(server)
        } label: {
            HStack(spacing: 10) {
                FlagView(server: server)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(server.displayName)
                            .font(appFont(.body, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected && palette.appearance == .material ? palette.onAccentContainer : palette.primaryText)
                            .lineLimit(1)
                        if server.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.yellow)
                        }
                    }
                    HStack(spacing: 4) {
                        ForEach(server.protocolTags, id: \.self) { TagLabel(text: $0) }
                        if server.descriptor.allowsInsecure {
                            Image(systemName: "exclamationmark.shield")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .accessibilityLabel(L("Проверка сертификата отключена"))
                        }
                    }
                }
                Spacer(minLength: 6)
                LatencyLabel(record: model.latency.record(server.id), isTesting: model.latency.testing.contains(server.id))
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(palette.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            ServerMenu(server: server, path: $path)
        }
    }
}

/// The context menu of a server.
struct ServerMenu: View {
    let server: Server
    @Binding var path: [ServersRoute]
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(server.name)
        Button {
            model.select(server)
        } label: { Label(L("Выбрать"), systemImage: "checkmark.circle") }
        Button {
            model.toggleFavorite(server.id)
        } label: {
            Label(server.isFavorite ? L("Убрать из избранного") : L("В избранное"), systemImage: server.isFavorite ? "star.slash" : "star")
        }
        Button {
            path.append(.server(server.id))
        } label: { Label(L("Подробнее"), systemImage: "info.circle") }
        if let link = server.link {
            Button {
                UIPasteboard.general.string = link
                model.show(.success, L("Ссылка скопирована"))
            } label: { Label(L("Скопировать ссылку"), systemImage: "doc.on.doc") }
        }
        Divider()
        Button(role: .destructive) {
            model.deleteServer(server.id)
        } label: { Label(L("Удалить"), systemImage: "trash") }
    }
}

// MARK: - Classic

struct ClassicServerList: View {
    @Binding var path: [ServersRoute]
    @Binding var visible: Set<UUID>
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var deleting: Subscription?

    var body: some View {
        List {
            ForEach(model.library.subscriptions) { subscription in
                Section {
                    ForEach(model.orderedServers(subscription)) { server in
                        ServerRow(server: server, path: $path)
                            .onAppear { visible.insert(server.id) }
                            .onDisappear { visible.remove(server.id) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { model.deleteServer(server.id) } label: { Label(L("Удалить"), systemImage: "trash") }
                                Button { path.append(.server(server.id)) } label: { Label(L("Подробнее"), systemImage: "info.circle") }
                            }
                            .swipeActions(edge: .leading) {
                                Button { model.toggleFavorite(server.id) } label: { Label(L("Избранное"), systemImage: server.isFavorite ? "star.slash" : "star") }
                                    .tint(.yellow)
                            }
                    }
                    if subscription.servers.isEmpty {
                        Text(subscription.lastError ?? L("В подписке нет серверов"))
                            .font(appFont(.footnote))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text(subscription.name).lineLimit(1)
                        Spacer()
                        if model.refreshing.contains(subscription.id) { ProgressView().controlSize(.mini) }
                        Menu {
                            SubscriptionMenu(subscription: subscription, path: $path, confirmDelete: Binding(get: { deleting?.id == subscription.id }, set: { value in deleting = value ? subscription : nil }))
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    .font(appFont(.footnote, weight: .semibold))
                } footer: {
                    SubscriptionSubtitle(subscription: subscription)
                }
            }
        }
        .listStyle(.insetGrouped)
        .confirmationDialog(L("Удалить «%@»?", deleting?.name ?? ""), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L("Удалить"), role: .destructive) {
                if let deleting { model.deleteSubscription(deleting.id) }
                deleting = nil
            }
        }
    }
}
