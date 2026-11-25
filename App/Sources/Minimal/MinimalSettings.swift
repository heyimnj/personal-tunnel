import CoreText
import UniformTypeIdentifiers
import TunnelCore
import UIKit

/// Settings root (3.5: five groups by what they do; 1.5.0 had four).
final class MinimalSettingsViewController: FormViewController {
    init() {
        super.init(title: L("Настройки"))
        largeTitle = true
    }

    private func push(_ controller: UIViewController) {
        navigationController?.pushViewController(controller, animated: true)
    }

    override func build() -> [FormSection] {
        // 3.5 (the owner's choice): grouped by what they do; the network page
        // («Сеть и безопасность») is split into its parts.
        // 3.5.23 (the owner): «Язык» is in «Внешний вид»; «Обновление подписок» in
        // «Управление подписками»; «Сетевая активность» is gone (HWID went to
        // «Конфиденциальность», the rest is said there); «Подключение» and
        // «Резервные копии» together; «Конфиденциальность» between the log and
        // «О приложении»; the app lock is gone (shown only while it is on, to turn it off).
        var security: [FormRow] = []
        if Prefs.appLock {
            security.append(.symbol("lock", .toggle(title: L("Блокировка приложения"), get: { Prefs.appLock }, set: { [weak self] in Prefs.appLock = $0; self?.rebuild() })))
        }
        return [
            FormSection([
                .link(symbol: "paintpalette", title: L("Внешний вид")) { [weak self] in self?.push(AppearanceViewController()) },
            ]),
            FormSection([
                .link(symbol: "folder", title: L("Управление подписками")) { [weak self] in self?.push(SubscriptionsViewController()) },
            ]),
            FormSection(security + [
                .link(symbol: "wifi", title: L("Подключение")) { [weak self] in self?.push(NetworkSettingsViewController(.connection)) },
                .link(symbol: "externaldrive.badge.icloud", title: L("Резервные копии")) { [weak self] in self?.push(BackupViewController()) },
            ]),
            FormSection(footer: AboutViewController.version, [
                .link(symbol: "doc.text.magnifyingglass", title: L("Журнал службы")) { [weak self] in self?.push(ServiceLogViewController()) },
                .link(symbol: "hand.raised", title: L("Конфиденциальность")) { [weak self] in self?.push(PrivacyViewController()) },
                .link(symbol: "info.circle", title: L("О приложении")) { [weak self] in self?.push(AboutViewController()) },
            ]),
        ]
    }
}

/// «Внешний вид». 3.5.23 (the owner): every colour in «Цвета» — each opens the
/// colour panel with its own «Сбросить»; nothing applies until the ✓ at the top
/// right (it shows while something is changed); «Сбросить всё» at the bottom. The
/// card background's density is under «Фон»; the background is a colour, not a switch.
final class AppearanceViewController: ColorsViewController {
    init() { super.init(title: L("Внешний вид"), background: true) }

    override func build() -> [FormSection] {
        [
            FormSection([
                .picker(title: L("Интерфейс"), options: [("modern", L("Современный")), ("classic", L("Классика"))], get: { Prefs.style.rawValue },
                        set: { Prefs.style = InterfaceStyle(rawValue: $0) ?? .minimal }),
                .picker(title: L("Оформление"), options: [("system", L("Системная")), ("light", L("Светлая")), ("dark", L("Тёмная"))], get: { Prefs.theme }, set: { Prefs.theme = $0 }),
                // 3.5.23 (the owner): the language is here, not a page of its own.
                .picker(title: L("Язык"), options: [("system", L("Системный")), ("ru", "Русский"), ("en", "English")], get: { Prefs.language }, set: { Prefs.language = $0 }),
                .note(L("Системный — язык устройства: русский на русском iPhone, иначе английский.")),
            ]),
            FormSection(L("Цвета"), colorRows()),
            FormSection(L("Фон"), [
                .toggle(title: L("AMOLED — чёрный фон в тёмной теме"), get: { Prefs.amoled }, set: { Prefs.amoled = $0 }),
                .note(L("Фон главной и аналитики в тёмной теме: чёрный, а без AMOLED — тёмно-серый. Свой цвет фона задаётся в «Цветах».")),
                // 3.5 beta 2 (the owner): how solid the analytics cards are.
                .slider(title: L("Плотность карточек аналитики"), get: { Prefs.cardFill }, set: { Prefs.cardFill = $0 }),
            ]),
            fontSection(),
            FormSection([
                .picker(title: L("Панель серверов"), options: [("header", L("Заголовок слева")), ("bottom", L("Действия снизу")), ("search", L("Поиск в шапке"))],
                        get: { Prefs.serversLayout }, set: { Prefs.serversLayout = $0 }),
                .note(L("«Заголовок слева» — заголовок и кнопки сверху; «Действия снизу» — кнопки в панели внизу; «Поиск в шапке» — поиск сверху, сортировка сегментами.")),
            ]),
            FormSection([
                .link(symbol: "drop", title: L("Стекло и прозрачность")) { [weak self] in self?.navigationController?.pushViewController(GlassSettingsViewController(), animated: true) },
                .toggle(title: L("Только иконки вкладок"), get: { Prefs.hideTabLabels }, set: { Prefs.hideTabLabels = $0 }),
                .toggle(title: L("Акцентная активная точка"), get: { Prefs.accentDots }, set: { Prefs.accentDots = $0 }),
            ]),
            FormSection([
                .button(title: L("Сбросить всё"), destructive: true) { [weak self] in self?.confirmResetAll() },
            ]),
        ]
    }

    private func confirmResetAll() {
        let alert = UIAlertController(title: L("Сбросить всё?"), message: L("Цвета, фон, шрифт, стекло и прозрачность вернутся к исходным."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("Сбросить"), style: .destructive) { [weak self] _ in self?.resetAll() })
        present(alert, animated: true)
    }

    private func resetAll() {
        discardChanges()
        Prefs.setAccentHex(nil)
        Prefs.customBackground = false
        Prefs.textHex = nil
        Prefs.panelHex = nil
        Prefs.cardHex = nil
        Prefs.cardFill = Prefs.defaultCardFill
        Prefs.amoled = true
        Prefs.fontName = ""
        Prefs.fontFile = nil
        Prefs.glassStyle = Prefs.defaultGlassStyle
        for key in [Prefs.glassOpacityKey, Prefs.buttonOpacityKey, Prefs.serverOpacityKey] { Prefs.setOpacity(Prefs.defaultOpacity, key) }
        rebuild()
    }
}

/// The glass and its transparency (3.5: its own page, it was on «Внешний вид»).
final class GlassSettingsViewController: FormViewController {
    init() { super.init(title: L("Стекло и прозрачность")) }

    override func build() -> [FormSection] {
        func slider(_ title: String, _ key: String) -> FormRow {
            .slider(title: title, get: { Prefs.opacity(key) }, set: { Prefs.setOpacity($0, key) })
        }
        return [
            FormSection([
                .picker(title: L("Стекло"), options: [("clear", L("Чистое")), ("regular", L("Блюр")), ("tinted", "Tinted")], get: { Prefs.glassStyle }, set: { Prefs.glassStyle = $0 }),
                .toggle(title: L("Непрозрачные панели настроек"), get: { Prefs.solidSettings }, set: { Prefs.solidSettings = $0 }),
            ]),
            FormSection(L("Прозрачность стекла"), [
                slider(L("Весь интерфейс"), Prefs.glassOpacityKey),
                slider(L("Кнопка подключения"), Prefs.buttonOpacityKey),
                slider(L("Выбранный сервер"), Prefs.serverOpacityKey),
            ]),
        ]
    }
}

final class LanguageViewController: FormViewController {
    init() { super.init(title: L("Язык")) }

    override func build() -> [FormSection] {
        [FormSection(footer: L("Системный — язык устройства: русский на русском iPhone, иначе английский."), [
            .check(title: L("Системный"), selected: { Prefs.language == "system" }, action: { Prefs.language = "system" }),
            .check(title: "Русский", selected: { Prefs.language == "ru" }, action: { Prefs.language = "ru" }),
            .check(title: "English", selected: { Prefs.language == "en" }, action: { Prefs.language = "en" }),
        ])]
    }
}

/// The network settings, one part per page (3.5: they were one long page,
/// «Сеть и безопасность»; the app lock went to the settings root).
final class NetworkSettingsViewController: FormViewController {
    enum Part {
        case updates, connection, routing, ping

        var title: String {
            switch self {
            case .updates: return L("Обновление подписок")
            case .connection: return L("Подключение")
            case .routing: return L("Маршрутизация и DNS")
            case .ping: return L("Пинг")
            }
        }
    }

    private let part: Part

    init(_ part: Part) {
        self.part = part
        super.init(title: part.title)
    }

    private var modeNote: String {
        switch Prefs.pingMode {
        case "classic":
            return L("Классика: активный узел проверяется по HTTPS раз в минуту. Список: generate_204 по HTTPS через каждый узел, до 8 одновременно, ожидание до 5 с; без VPN — то же ядром приложения, 4 с, до 10 одновременно. Не уложившийся по времени узел сразу проверяется ещё раз.")
        case "alternative":
            return L("Альтернативный: короткая HTTP-проверка через узел, до 12 одновременно, ожидание до 2,5 с; без VPN — ядром приложения. HTTP-проверка не подтверждает доступность HTTPS-сайтов.")
        default:
            return L("Основной: generate_204 через каждый узел подключённой подписки (4 с), до 20 одновременно. Серверы остальных подписок и все серверы без VPN проверяет ядро приложения: generate_204 через каждый сервер (4 с), до 10 одновременно; с VPN их задержка включает туннель. Не уложившийся по времени узел сразу проверяется ещё раз. Результаты хранятся 2,5 минуты, при открытии списка проверяются только устаревшие.")
        }
    }

    private func pingSections() -> [FormSection] {
        [
            FormSection(L("Пинг"), [
                .picker(title: L("Режим пинга"), options: [("primary", L("Основной")), ("classic", L("Классика")), ("alternative", L("Альтернативный"))], get: { Prefs.pingMode }, set: { Prefs.pingMode = $0 }),
                .note(modeNote),
            ] + (Prefs.autoPingAvailable ? [
                .toggle(title: L("Автопинг"), get: { Prefs.autoPing }, set: { Prefs.autoPing = $0 }),
                .note(L("Задержка серверов проверяется сама при открытии приложения и после обновления подписки.")),
            ] : [])),
        ]
    }

    private func routingSections() -> [FormSection] {
        let changed = { App.shared.networkSettingsChanged() }
        return [
            FormSection(L("Маршрутизация и DNS"), [
                .link(symbol: nil, title: L("Блокировка рекламы")) { [weak self] in self?.navigationController?.pushViewController(AdBlockViewController(), animated: true) },
                .toggle(title: L("Обход российских сайтов"), get: { Prefs.bypassRussia }, set: { Prefs.bypassRussia = $0; changed() }),
                .note(L("Российские сайты открываются мимо VPN, с вашим настоящим IP. Сайт, который подгружает что-то с российского адреса, может увидеть настоящий IP рядом с IP VPN.")),
                .toggle(title: L("Без QUIC через VPN"), get: { Prefs.blockQUIC }, set: { Prefs.blockQUIC = $0; changed() }),
                .note(L("Видео и сайты, которые идут через VPN, грузятся по обычному HTTPS вместо QUIC: так туннель тратит заметно меньше батареи. Звонки, игры и сайты мимо VPN не затрагиваются.")),
                .toggle(title: L("Не пускать мимо VPN"), get: { Prefs.secureDNS }, set: { Prefs.secureDNS = $0; App.shared.tunnel.applySettings() }),
                // 3.5.23 (the owner did not remember what it is for).
                .note(L("iOS не даёт приложениям обойти VPN для адресов, которые идут через туннель: например, отправить DNS-запрос напрямую в сеть Wi-Fi или оператора. Защищает от утечек DNS. С Kill switch и так всё идёт через VPN. Действует со следующего подключения.")),
                .toggle(title: L("Локальная сеть"), get: { Prefs.localNetwork }, set: { Prefs.localNetwork = $0; changed() }),
                .note(L("Принтеры, AirPlay, роутер и другие устройства домашней сети доступны мимо VPN. После изменения переподключите VPN.")),
            ]),
            FormSection(L("DNS вне туннеля"), [
                .picker(title: L("Резолверы"), options: DirectResolvers.presets.map { preset -> (value: String, title: String) in (preset.id, Prefs.resolverTitle(preset.id)) },
                        get: { Prefs.directResolvers }, set: { Prefs.directResolvers = $0; changed() }),
                .note(L("Адреса серверов находятся вне туннеля, по DNS over HTTPS через выбранные резолверы, а если сеть его не пропускает — обычным DNS через них же. Российские сайты при обходе — через Яндекс.")),
            ]),
        ]
    }

    override func build() -> [FormSection] {
        switch part {
        case .ping: return pingSections()
        case .routing: return routingSections()
        case .updates: return [
            FormSection([
                .toggle(title: L("Автообновление подписок"), get: { Prefs.autoUpdateSubscriptions }, set: { Prefs.autoUpdateSubscriptions = $0 }),
                .picker(title: L("Время обновления"), options: Prefs.subscriptionUpdateOptions,
                        get: { String(Prefs.subscriptionUpdateHour) }, set: { Prefs.subscriptionUpdateHour = Int($0) ?? SubscriptionSchedule.everyDay }),
                .note(L("Подписки обновляются сами раз в 24 часа или каждый день в выбранное время — при первом открытии приложения после него (и пока оно открыто). Выключено — только вручную.")),
            ]),
        ]
        // 3.5 beta 4 (the owner): «Маршрутизация и DNS» and «Пинг» are sections of
        // this page, not pages of their own.
        case .connection: return [
            FormSection([
                .toggle(title: L("Автоподключение в неизвестных Wi-Fi"), get: { Prefs.autoConnect }, set: { Prefs.autoConnect = $0; App.shared.tunnel.applySettings() }),
                .note(L("VPN включается сам при подключении к Wi-Fi не из «Моих сетей». В своих сетях и по сотовой связи сам не включается. Выключили VPN кнопкой в неизвестной сети — в ней он не включится сам, пока вы снова не включите его.")),
                .link(symbol: nil, title: L("Мои сети")) { [weak self] in self?.navigationController?.pushViewController(TrustedNetworksViewController(), animated: true) },
                .toggle(title: L("Kill switch"), get: { Prefs.killSwitch }, set: { Prefs.killSwitch = $0; App.shared.tunnel.applySettings() }),
                .note(L("Пока VPN включён, но не подключён (переподключение, сбой), приложения не выходят в интернет напрямую. Исключения iOS: push-уведомления Apple и службы оператора (звонки, SMS) iOS может пускать мимо VPN. При большом трафике (видео) тратит больше батареи: каждый пакет обрабатывает ядро туннеля. Действует со следующего подключения.")),
            ]),
        ] + routingSections() + pingSections()
        }
    }
}

/// «Цвета и шрифт» (Classic's page) and the base of «Внешний вид». 3.5.23 (the
/// owner): a colour changes nothing until the ✓ at the top right — it shows while
/// something waits — and the colour panel has «Сбросить» for its own part.
class ColorsViewController: FormViewController {
    enum Part: Hashable { case accent, background, text, panel, cards }
    enum Change { case color(UIColor), reset }

    private let withBackground: Bool
    private var pending: [Part: Change] = [:] { didSet { showSave() } }
    private lazy var saveItem: UIBarButtonItem = {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
        config.baseBackgroundColor = Theme.accent
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.save() })
        button.accessibilityLabel = L("Сохранить")
        button.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
        return UIBarButtonItem(customView: button)
    }()

    init() {
        withBackground = false
        super.init(title: L("Цвета и шрифт"))
    }

    init(title: String, background: Bool) {
        withBackground = background
        super.init(title: title)
    }

    override func build() -> [FormSection] {
        [FormSection(L("Цвета"), colorRows() + [
            .toggle(title: L("AMOLED — чёрный фон в тёмной теме"), get: { Prefs.amoled }, set: { Prefs.amoled = $0 }),
        ]), fontSection()]
    }

    /// One row a part; a tap opens the colour panel with «Сбросить».
    func colorRows() -> [FormRow] {
        var parts: [(Part, String)] = [(.accent, L("Акцентный цвет"))]
        if withBackground { parts.append((.background, L("Цвет фона"))) }
        parts += [(.text, L("Цвет текста")), (.panel, L("Цвет панелей"))]
        if withBackground { parts.append((.cards, L("Цвет карточек аналитики"))) }
        return parts.map { part, title in
            .paint(title: title, get: { [weak self] in self?.shown(part) ?? .clear }, set: { [weak self] in self?.pending[part] = .color($0) },
                   reset: { [weak self] in self?.pending[part] = .reset })
        }
    }

    /// The part's colour as it would be saved: the change waiting, or what is stored.
    private func shown(_ part: Part) -> UIColor {
        switch pending[part] {
        case let .color(color)?: return color
        case .reset?: return Self.standard(part, traits: traitCollection)
        case nil: return Self.stored(part, traits: traitCollection)
        }
    }

    private static func stored(_ part: Part, traits: UITraitCollection) -> UIColor {
        switch part {
        case .accent: return Theme.accent
        case .background: return Prefs.customBackground ? (UIColor(hex: Prefs.backgroundColors.first) ?? standard(part, traits: traits)) : standard(part, traits: traits)
        case .text: return Theme.text
        case .panel: return Theme.panel
        case .cards: return UIColor(hex: Prefs.cardHex) ?? standard(part, traits: traits)
        }
    }

    private static func standard(_ part: Part, traits: UITraitCollection) -> UIColor {
        switch part {
        case .accent: return UIColor(hex: Prefs.style == .classic ? "3478F6" : "FA243C") ?? .systemRed
        case .background: return Theme.background.resolvedColor(with: traits)
        case .text: return UIColor.label.resolvedColor(with: traits)
        case .panel: return UIColor(red: 0.15, green: 0.17, blue: 0.21, alpha: 1)
        case .cards: return UIColor.secondarySystemBackground.resolvedColor(with: traits)
        }
    }

    private func showSave() {
        var items = (navigationItem.rightBarButtonItems ?? []).filter { $0 !== saveItem }
        if !pending.isEmpty { items.insert(saveItem, at: 0) }
        navigationItem.setRightBarButtonItems(items, animated: true)
    }

    private func save() {
        Haptics.result(true)
        let changes = pending
        pending = [:]
        for (part, change) in changes {
            let hex: String? = { if case let .color(color) = change { return color.hexString }; return nil }()
            switch part {
            case .accent: Prefs.setAccentHex(hex)
            case .background:
                if let hex { Prefs.backgroundColors = [hex] }
                Prefs.customBackground = hex != nil
            case .text: Prefs.textHex = hex
            case .panel: Prefs.panelHex = hex
            case .cards: Prefs.cardHex = hex
            }
        }
        rebuild()
    }

    func discardChanges() { pending = [:] }

    /// The font: import, its name, and «Сбросить шрифт» while one is imported.
    func fontSection() -> FormSection {
        var rows: [FormRow] = [
            .button(title: L("Импорт шрифта TTF / OTF"), destructive: false) { [weak self] in self?.importFont() },
            .value(title: L("Шрифт"), detail: { Prefs.fontName.isEmpty ? L("системный") : Prefs.fontName }),
        ]
        if !(Prefs.fontFile ?? "").isEmpty {
            rows.append(.button(title: L("Сбросить шрифт"), destructive: false) { [weak self] in
                Prefs.fontName = ""
                Prefs.fontFile = nil
                self?.rebuild()
            })
        }
        return FormSection(L("Шрифт"), rows)
    }

    private func importFont() {
        FontImporter.shared.present(from: self) { [weak self] in self?.rebuild() }
    }
}

final class FontImporter: NSObject, UIDocumentPickerDelegate {
    static let shared = FontImporter()
    private var done: (() -> Void)?

    func present(from host: UIViewController, done: @escaping () -> Void) {
        self.done = done
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.font, .data], asCopy: true)
        picker.delegate = self
        host.present(picker, animated: true)
    }

    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let first = descriptors.first else {
            App.shared.notice.value = L("Этот файл не удалось прочитать как шрифт.")
            return
        }
        let directory = Theme.fontsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "imported-\(Int(Date().timeIntervalSince1970)).\(url.pathExtension.isEmpty ? "ttf" : url.pathExtension)"
        do {
            try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(name))
        } catch {
            App.shared.notice.value = Lf("Шрифт не сохранён: %@", "\(error.localizedDescription)")
            return
        }
        Prefs.fontName = (CTFontDescriptorCopyAttribute(first, kCTFontDisplayNameAttribute) as? String) ?? url.deletingPathExtension().lastPathComponent
        Prefs.fontFile = name
        done?()
    }
}
