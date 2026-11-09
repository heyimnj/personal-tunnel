import SwiftUI
import TunnelKit

/// Name, link, refresh and device-identity settings of a subscription, with
/// what the panel reported and the servers it could not import.
struct SubscriptionEditorView: View {
    let subscriptionID: UUID

    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Subscription?
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let binding = Binding($draft) {
                form(binding)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(draft?.name ?? L("Подписка"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if draft == nil { draft = model.library.subscriptions.first { $0.id == subscriptionID } }
        }
        .onDisappear(perform: save)
    }

    private func save() {
        guard let draft, let current = model.library.subscriptions.first(where: { $0.id == subscriptionID }) else { return }
        var merged = current
        if merged.name != draft.name {
            merged.name = draft.name
            merged.hasCustomName = true
        }
        merged.url = draft.url?.nonEmptyText
        merged.isEnabled = draft.isEnabled
        merged.autoUpdate = draft.autoUpdate
        merged.updateIntervalHours = draft.updateIntervalHours
        merged.sendsDeviceInfo = draft.sendsDeviceInfo
        if merged != current { model.updateSubscription(merged) }
    }

    private func form(_ subscription: Binding<Subscription>) -> some View {
        StyledList {
            Section {
                TextField(L("Название"), text: subscription.name)
                    .font(appFont(.body))
                if subscription.wrappedValue.isRemote {
                    TextField(L("Ссылка подписки"), text: Binding(get: { subscription.wrappedValue.url ?? "" }, set: { subscription.wrappedValue.url = $0 }))
                        .font(appFont(.callout))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Toggle(L("Включена"), isOn: subscription.isEnabled)
            }

            if subscription.wrappedValue.isRemote {
                Section(header: HeaderText(L("Обновление")), footer: Text(intervalFooter(subscription.wrappedValue)).font(appFont(.caption))) {
                    Toggle(L("Обновлять автоматически"), isOn: subscription.autoUpdate)
                    Picker(L("Интервал"), selection: subscription.updateIntervalHours) {
                        ForEach([1, 3, 6, 12, 24, 48, 72, 168], id: \.self) { hours in
                            Text(hoursTitle(hours)).tag(hours)
                        }
                    }
                    .disabled(!subscription.wrappedValue.autoUpdate)
                    Button {
                        save()
                        Task { await model.refresh(subscriptionID) }
                    } label: {
                        HStack {
                            Label(L("Обновить сейчас"), systemImage: "arrow.clockwise")
                            Spacer()
                            if model.refreshing.contains(subscriptionID) { ProgressView() }
                        }
                    }
                }

                Section(header: HeaderText(L("Данные устройства")), footer: deviceFooter(subscription.wrappedValue.sendsDeviceInfo)) {
                    Toggle(L("Отправлять HWID, модель и версию iOS"), isOn: subscription.sendsDeviceInfo)
                    ForEach(previewHeaders(subscription.wrappedValue.sendsDeviceInfo), id: \.self) { header in
                        Text(header)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            let info = model.library.subscriptions.first { $0.id == subscriptionID }?.info ?? SubscriptionInfo()
            if info.totalBytes != nil || info.expiresAt != nil || info.deviceLimit != nil || info.announce != nil || info.supportURL != nil {
                Section(header: HeaderText(L("Сведения панели"))) {
                    if let used = info.usedBytes {
                        HStack {
                            Text(L("Трафик"))
                            Spacer()
                            Text(info.totalBytes.map { "\(Format.bytes(used)) / \(Format.bytes($0))" } ?? Format.bytes(used))
                                .foregroundStyle(.secondary)
                        }
                        if let fraction = info.usageFraction { UsageBar(fraction: fraction) }
                    }
                    if let expires = info.expiresAt {
                        HStack {
                            Text(L("Действует до"))
                            Spacer()
                            Text(Format.date(expires)).foregroundStyle(expires < Date() ? palette.failed : .secondary)
                        }
                    }
                    if let limit = info.deviceLimit {
                        HStack {
                            Text(L("Устройства"))
                            Spacer()
                            Text(info.devicesUsed.map { "\($0) / \(limit)" } ?? "\(limit)").foregroundStyle(.secondary)
                        }
                    }
                    if info.deviceLimitReached {
                        Text(L("Панель сообщает, что лимит устройств исчерпан."))
                            .foregroundStyle(palette.failed)
                    }
                    if let announce = info.announce {
                        Text(announce).font(appFont(.footnote))
                    }
                    if let support = info.supportURL, let url = URL(string: support) {
                        Link(destination: url) { Label(L("Поддержка"), systemImage: "questionmark.bubble") }
                    }
                    if let page = info.webPageURL, let url = URL(string: page) {
                        Link(destination: url) { Label(L("Страница подписки"), systemImage: "safari") }
                    }
                }
            }

            let skipped = model.library.subscriptions.first { $0.id == subscriptionID }?.skipped ?? []
            if !skipped.isEmpty {
                Section(header: HeaderText(L("Не импортировано: %d", skipped.count))) {
                    ForEach(Array(skipped.prefix(50).enumerated()), id: \.offset) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.element.name).font(appFont(.subheadline, weight: .medium)).lineLimit(1)
                            Text(localizedMessage(item.element.reason)).font(appFont(.caption)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label(L("Удалить подписку"), systemImage: "trash")
                }
            }
        }
        .confirmationDialog(L("Удалить «%@»?", subscription.wrappedValue.name), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Удалить"), role: .destructive) {
                model.deleteSubscription(subscriptionID)
                draft = nil
                dismiss()
            }
        }
    }

    private func hoursTitle(_ hours: Int) -> String {
        if hours < 24 { return plural(hours, "час", "часа", "часов", english: ("hour", "hours")) }
        return plural(hours / 24, "день", "дня", "дней", english: ("day", "days"))
    }

    private func intervalFooter(_ subscription: Subscription) -> String {
        if let hours = subscription.info.updateIntervalHours {
            return L("Панель просит обновлять раз в %@.", hoursTitle(hours))
        }
        if let updated = subscription.lastUpdated, updated.timeIntervalSince1970 > 0 {
            return L("Обновлено %@", Format.relative(updated))
        }
        return ""
    }

    private func previewHeaders(_ sends: Bool) -> [String] {
        SubscriptionFetcher.previewHeaders(device: DeviceIdentity.current, sendsDeviceInfo: sends)
            .sorted { $0.key < $1.key }
            .map { key, value in key == "X-HWID" ? "\(key): \(Redactor.mask(value))" : "\(key): \(value)" }
    }

    private func deviceFooter(_ sends: Bool) -> some View {
        Text(sends
            ? L("Панели Remnawave и Happ считают устройства по HWID. Он создаётся один раз и не связан с Apple ID. Заголовки уходят только первому запросу и не передаются при переадресации на другой адрес.")
            : L("Подписка запрашивается без данных устройства. Панель с лимитом устройств может отказать."))
            .font(appFont(.caption))
    }
}

/// Order, enable and delete subscriptions.
struct ManageSubscriptionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let enabled = model.library.subscriptions.filter(\.isEnabled)
        let disabled = model.library.subscriptions.filter { !$0.isEnabled }
        StyledList {
            Section(header: HeaderText(L("Подписки"))) {
                ForEach(enabled) { subscription in
                    row(subscription)
                }
                .onMove { source, destination in
                    move(within: enabled, source, destination)
                }
                .onDelete { offsets in
                    for index in offsets { model.deleteSubscription(enabled[index].id) }
                }
            }
            if !disabled.isEmpty {
                Section(header: HeaderText(L("Отключённые"))) {
                    ForEach(disabled) { subscription in
                        row(subscription)
                    }
                    .onDelete { offsets in
                        for index in offsets { model.deleteSubscription(disabled[index].id) }
                    }
                }
            }
        }
        .navigationTitle(L("Управление подписками"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    private func row(_ subscription: Subscription) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.name).font(appFont(.body)).lineLimit(1)
                Text(subscription.isRemote ? serversCount(subscription.servers.count) : L("Добавлены вручную") + " · " + serversCount(subscription.servers.count))
                    .font(appFont(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { subscription.isEnabled }, set: { model.setSubscriptionEnabled(subscription.id, $0) }))
                .labelsHidden()
        }
    }

    /// Moves inside the enabled section map back onto the full list.
    private func move(within visible: [Subscription], _ source: IndexSet, _ destination: Int) {
        var ids = visible.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        let others = model.library.subscriptions.filter { !ids.contains($0.id) }
        let reordered = ids.compactMap { id in model.library.subscriptions.first { $0.id == id } }
        model.library.subscriptions = reordered + others
    }
}
