import SwiftUI
import TunnelKit

/// Routing, DNS and Network Extension options.
struct NetworkSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var customDNS = ""
    @AppStorage(SharedKey.includeAllNetworks, store: SharedContainer.defaults) private var includeAllNetworks = false
    @AppStorage(SharedKey.excludeLocalNetworks, store: SharedContainer.defaults) private var excludeLocalNetworks = true
    @AppStorage(SharedKey.excludeAPNs, store: SharedContainer.defaults) private var excludeAPNs = true
    @AppStorage(SharedKey.excludeCellularServices, store: SharedContainer.defaults) private var excludeCellular = true
    @AppStorage(SharedKey.excludeFromDeviceBackup, store: SharedContainer.defaults) private var excludeFromBackup = true

    var body: some View {
        @Bindable var model = model
        StyledList {
            Section(header: HeaderText(L("Маршрутизация")), footer: Text(L("Список рекламных доменов встроен в приложение и работает офлайн. Российские сайты и IP-адреса идут напрямую по встроенным спискам runetfreedom.")).font(appFont(.caption))) {
                Toggle(L("Блокировка рекламы"), isOn: $model.options.adBlocking)
                Toggle(L("Российские сайты напрямую"), isOn: $model.options.bypassRussia)
                Toggle(L("Локальные адреса напрямую"), isOn: $model.options.directLocalNetworks)
                Toggle("IPv6", isOn: $model.options.ipv6)
            }

            Section(header: HeaderText("DNS"), footer: Text(L("DNS-запросы идут через выбранный сервер. Адреса серверов и российские домены разрешаются системным DNS.")).font(appFont(.caption))) {
                Picker("DNS", selection: $model.options.dns) {
                    ForEach(DNSPreset.allCases, id: \.self) { preset in
                        Text(preset == .custom ? L("Свой") : preset.title).tag(preset)
                    }
                }
                if model.options.dns == .custom {
                    TextField("https://dns.example/dns-query", text: $customDNS)
                        .font(appFont(.callout))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(applyCustomDNS)
                    if !customDNS.isEmpty, ConfigBuilder.customDNSServer(customDNS) == nil {
                        Text(L("Формат: https://…, tls://…, quic://…, udp://… или IP-адрес."))
                            .font(appFont(.caption))
                            .foregroundStyle(.red)
                    }
                    Button(L("Применить"), action: applyCustomDNS)
                        .disabled(ConfigBuilder.customDNSServer(customDNS) == nil || customDNS == model.options.customDNS)
                }
            }

            Section(header: HeaderText(L("Туннель iOS")), footer: Text(L("«Весь трафик через VPN» не выпускает трафик мимо туннеля, пока он подключается или переподключается, но может мешать AirDrop, CarPlay и звонкам Wi-Fi. Изменения применяются при следующем подключении.")).font(appFont(.caption))) {
                Toggle(L("Весь трафик через VPN"), isOn: $includeAllNetworks)
                Toggle(L("Не трогать локальную сеть"), isOn: $excludeLocalNetworks)
                Toggle(L("Push-уведомления Apple мимо VPN"), isOn: $excludeAPNs)
                Toggle(L("Сотовые службы мимо VPN"), isOn: $excludeCellular)
            }
            .onChange(of: includeAllNetworks) { _, _ in applyProfile() }
            .onChange(of: excludeLocalNetworks) { _, _ in applyProfile() }
            .onChange(of: excludeAPNs) { _, _ in applyProfile() }
            .onChange(of: excludeCellular) { _, _ in applyProfile() }

            Section(header: HeaderText(L("Журнал ядра"))) {
                Picker(L("Уровень"), selection: $model.options.logLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
            }

            Section(footer: Text(L("Ссылки подписок, ключи серверов и локальная копия не попадают в резервную копию iPhone и iCloud.")).font(appFont(.caption))) {
                Toggle(L("Не сохранять ключи в копии iPhone/iCloud"), isOn: $excludeFromBackup)
                    .onChange(of: excludeFromBackup) { _, _ in LibraryStore.applyBackupExclusion() }
            }
        }
        .navigationTitle(L("Сеть"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { customDNS = model.options.customDNS }
    }

    private func applyCustomDNS() {
        guard ConfigBuilder.customDNSServer(customDNS) != nil else { return }
        model.options.customDNS = customDNS.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyProfile() {
        Task { await model.tunnel.applySettings() }
    }
}

/// Domains that always go direct or always through the proxy.
struct RoutingRulesView: View {
    @Environment(AppModel.self) private var model
    @State private var direct = ""
    @State private var proxied = ""

    var body: some View {
        StyledList {
            Section(header: HeaderText(L("Всегда напрямую")), footer: Text(L("По одному домену на строке, поддомены включаются: example.com охватывает www.example.com.")).font(appFont(.caption))) {
                TextEditor(text: $direct)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 120)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section(header: HeaderText(L("Всегда через VPN")), footer: Text(L("Сильнее правил обхода: домен из этого списка пойдёт через сервер, даже если он российский.")).font(appFont(.caption))) {
                TextEditor(text: $proxied)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 120)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section {
                Button(L("Сохранить правила"), action: save)
            }
        }
        .navigationTitle(L("Свои правила"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            direct = model.options.directDomains.joined(separator: "\n")
            proxied = model.options.proxyDomains.joined(separator: "\n")
        }
    }

    private func save() {
        func split(_ text: String) -> [String] {
            ConfigBuilder.normalizedDomains(text.components(separatedBy: CharacterSet(charactersIn: "\n,; ")))
        }
        var options = model.options
        options.directDomains = split(direct)
        options.proxyDomains = split(proxied)
        model.options = options
        direct = options.directDomains.joined(separator: "\n")
        proxied = options.proxyDomains.joined(separator: "\n")
        model.show(.success, L("Правила сохранены"))
    }
}

/// Automatic connection when the device joins a network.
struct OnDemandSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SharedKey.onDemand, store: SharedContainer.defaults) private var onDemand = false
    @State private var trusted: [String] = SharedContainer.defaults.stringArray(forKey: SharedKey.onDemandTrustedSSIDs) ?? []
    @State private var newSSID = ""

    var body: some View {
        StyledList {
            Section(footer: Text(L("iOS сама включает VPN при любом подключении к сети. Кнопка «Отключить» выключает этот режим, иначе туннель сразу поднимется снова.")).font(appFont(.caption))) {
                Toggle(L("Подключаться автоматически"), isOn: $onDemand)
                    .onChange(of: onDemand) { _, _ in save() }
            }
            Section(header: HeaderText(L("Доверенные Wi-Fi")), footer: Text(L("В этих сетях VPN не включается автоматически. Нужно точное имя сети (SSID).")).font(appFont(.caption))) {
                ForEach(trusted, id: \.self) { ssid in
                    Text(ssid)
                }
                .onDelete { offsets in
                    trusted.remove(atOffsets: offsets)
                    save()
                }
                HStack {
                    TextField(L("Имя сети"), text: $newSSID)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button(L("Добавить")) {
                        let value = newSSID.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty, !trusted.contains(value) else { return }
                        trusted.append(value)
                        newSSID = ""
                        save()
                    }
                    .disabled(newSSID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationTitle(L("По требованию"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save() {
        SharedContainer.defaults.set(trusted, forKey: SharedKey.onDemandTrustedSSIDs)
        Task { await model.tunnel.applySettings() }
    }
}
