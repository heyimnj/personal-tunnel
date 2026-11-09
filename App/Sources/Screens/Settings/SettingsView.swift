import SwiftUI
import TunnelKit

enum SettingsRoute: Hashable {
    case appearance
    case colors
    case subscriptions
    case latency
    case network
    case rules
    case onDemand
    case check
    case logs
    case activity
    case backups
    case about
}

/// "Settings" tab. Every option appears once, in four groups.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [SettingsRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            StyledList {
                Section(header: HeaderText(L("Оформление и язык"))) {
                    NavigationLink(value: SettingsRoute.appearance) {
                        IconLabel(title: L("Оформление"), systemImage: "paintbrush.fill", tint: .indigo)
                    }
                    NavigationLink(value: SettingsRoute.colors) {
                        IconLabel(title: L("Цвета и шрифт"), systemImage: "textformat", tint: .pink)
                    }
                    LanguagePicker()
                }
                Section(header: HeaderText(L("Подписки и серверы"))) {
                    NavigationLink(value: SettingsRoute.subscriptions) {
                        IconLabel(title: L("Управление подписками"), systemImage: "list.bullet.rectangle.fill", tint: .blue)
                    }
                    NavigationLink(value: SettingsRoute.latency) {
                        IconLabel(title: L("Измерение задержки"), systemImage: "bolt.horizontal.fill", tint: .orange)
                    }
                }
                Section(header: HeaderText(L("Сеть и диагностика"))) {
                    NavigationLink(value: SettingsRoute.network) {
                        IconLabel(title: L("Сеть"), systemImage: "network", tint: .green)
                    }
                    NavigationLink(value: SettingsRoute.rules) {
                        IconLabel(title: L("Свои правила"), systemImage: "arrow.triangle.branch", tint: .teal)
                    }
                    NavigationLink(value: SettingsRoute.onDemand) {
                        IconLabel(title: L("Подключение по требованию"), systemImage: "wifi", tint: .cyan)
                    }
                    NavigationLink(value: SettingsRoute.check) {
                        IconLabel(title: L("Проверка соединения"), systemImage: "checkmark.seal.fill", tint: .mint)
                    }
                    NavigationLink(value: SettingsRoute.logs) {
                        IconLabel(title: L("Журнал ядра"), systemImage: "doc.text.fill", tint: .gray)
                    }
                    NavigationLink(value: SettingsRoute.activity) {
                        IconLabel(title: L("Сетевая активность приложения"), systemImage: "eye.fill", tint: .purple)
                    }
                }
                Section(header: HeaderText(L("Данные и о приложении"))) {
                    NavigationLink(value: SettingsRoute.backups) {
                        IconLabel(title: L("Резервные копии"), systemImage: "externaldrive.fill", tint: .brown)
                    }
                    NavigationLink(value: SettingsRoute.about) {
                        IconLabel(title: L("О приложении"), systemImage: "info.circle.fill", tint: .blue)
                    }
                }
            }
            .navigationTitle(L("Настройки"))
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .appearance: AppearanceSettingsView()
                case .colors: ColorsAndFontView()
                case .subscriptions: ManageSubscriptionsView()
                case .latency: LatencySettingsView()
                case .network: NetworkSettingsView()
                case .rules: RoutingRulesView()
                case .onDemand: OnDemandSettingsView()
                case .check: ConnectionCheckView()
                case .logs: LogsView()
                case .activity: NetworkActivityView()
                case .backups: BackupsView()
                case .about: AboutView()
                }
            }
        }
    }
}

struct LanguagePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Picker(selection: $settings.language) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.title).tag(language)
            }
        } label: {
            IconLabel(title: L("Язык"), systemImage: "globe", tint: .blue)
        }
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        StyledList {
            Section(header: HeaderText(L("Стиль")), footer: Text(styleFooter(settings.appearance)).font(appFont(.caption))) {
                Picker(L("Стиль"), selection: $settings.appearance) {
                    ForEach(Appearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section(header: HeaderText(L("Тема"))) {
                Picker(L("Тема"), selection: $settings.theme) {
                    ForEach(ThemeMode.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                Toggle(L("Чёрный фон в тёмной теме"), isOn: $settings.amoled)
            }
            Section(header: HeaderText(L("Интерфейс"))) {
                Toggle(L("Скрыть подписи вкладок"), isOn: $settings.hideTabLabels)
                Toggle(L("Вибрация"), isOn: $settings.haptics)
            }
        }
        .navigationTitle(L("Оформление"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func styleFooter(_ appearance: Appearance) -> String {
        switch appearance {
        case .classic: return L("Системные списки iOS, серверы сгруппированы по подпискам.")
        case .modern: return L("Карточки и «жидкое стекло» iOS 26 (на iOS 17–25 — размытие). Подписки раскрываются в контейнер.")
        case .material: return L("Material 3 Expressive: тональная палитра из одного цвета, скруглённый шрифт, кнопка-«печенье».")
        }
    }
}

struct ColorsAndFontView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var fontError: String?

    private let presets = ["#3478F6", "#FA243C", "#34C759", "#FF9500", "#AF52DE", "#5856D6", "#00C7BE", "#FF2D55", "#8E8E93", "#6750A4"]

    var body: some View {
        @Bindable var settings = model.settings
        StyledList {
            Section(header: HeaderText(settings.appearance == .material ? L("Исходный цвет палитры") : L("Акцентный цвет")),
                    footer: Text(L("Цвет запоминается отдельно для каждого стиля. Цвета статуса подключения не меняются.")).font(appFont(.caption))) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                    ForEach(presets, id: \.self) { hex in
                        Button {
                            settings.setAccentHex(hex)
                            Haptics.selection()
                        } label: {
                            Circle()
                                .fill(Color(uiColor: UIColor(hex: hex) ?? .systemBlue))
                                .frame(width: 34, height: 34)
                                .overlay {
                                    if settings.accentHex.uppercased() == hex {
                                        Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
                ColorPicker(L("Свой цвет"), selection: Binding(
                    get: { Color(uiColor: UIColor(hex: settings.accentHex) ?? .systemBlue) },
                    set: { settings.setAccentHex($0.hexString) }
                ), supportsOpacity: false)
                Button(L("Цвет по умолчанию")) {
                    settings.setAccentHex(settings.appearance.defaultAccentHex)
                }
            }
            Section(header: HeaderText(L("Шрифт")), footer: Text(fontError ?? L("TTF или OTF из «Файлов». Шрифт применяется ко всему тексту и учитывает системный размер текста; значки и системные меню остаются системными.")).font(appFont(.caption)).foregroundStyle(fontError == nil ? Color.secondary : Color.red)) {
                HStack {
                    Text(L("Текущий"))
                    Spacer()
                    Text(settings.fontFile.isEmpty ? L("Системный") : (FontLibrary.displayName(for: settings.fontFile) ?? settings.fontFile))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button { importing = true } label: { Label(L("Выбрать файл шрифта"), systemImage: "doc.badge.plus") }
                if !settings.fontFile.isEmpty {
                    Button(L("Системный шрифт")) { settings.fontFile = "" }
                }
                Text(L("Пример текста: Personal Tunnel 1234567890"))
                    .font(appFont(.body))
            }
        }
        .navigationTitle(L("Цвета и шрифт"))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.font, .data]) { result in
            switch result {
            case let .success(url):
                do {
                    settings.fontFile = try FontLibrary.importFont(from: url)
                    fontError = nil
                    FontLibrary.applyAppearance(settings)
                } catch {
                    fontError = errorText(error)
                }
            case let .failure(error):
                fontError = errorText(error)
            }
        }
    }
}

// MARK: - Latency

struct LatencySettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        StyledList {
            Section(header: HeaderText(L("Режим")), footer: Text(modeFooter(settings.pingMode)).font(appFont(.caption))) {
                Picker(L("Режим"), selection: $settings.pingMode) {
                    Text(L("Основной")).tag(PingMode.primary)
                    Text(L("Классика")).tag(PingMode.classic)
                    Text(L("Альтернативный")).tag(PingMode.alternative)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section(footer: Text(L("По свежим URL-тестам выбирается сервер с минимальной задержкой, нестабильные пропускаются. Срабатывает при подключении и после проверки при включённом VPN.")).font(appFont(.caption))) {
                Toggle(L("Подключаться к лучшему серверу"), isOn: $settings.connectToBest)
                Toggle(L("Сортировать по задержке"), isOn: $settings.sortByLatency)
            }
            Section {
                Button(L("Сбросить результаты")) { model.latency.clear() }
            }
        }
        .navigationTitle(L("Измерение задержки"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func modeFooter(_ mode: PingMode) -> String {
        switch mode {
        case .primary:
            return L("Сначала TCP-соединение с сервером в обход VPN (1,5 с) — недоступные отсеиваются. Затем generate_204 через сам сервер (3 с), если подписка запущена в VPN. UDP-протоколы сразу проходят второй этап. Результаты хранятся 2,5 минуты.")
        case .classic:
            return L("При включённом VPN — только generate_204 через каждый сервер подписки, без VPN — TCP-соединение.")
        case .alternative:
            return L("Только время TCP-соединения с сервером в обход VPN. Hysteria, TUIC и WireGuard так не проверить.")
        }
    }
}
