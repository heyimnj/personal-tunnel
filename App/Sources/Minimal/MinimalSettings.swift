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
        [
            FormSection([
                .link(symbol: "paintpalette", title: L("Внешний вид")) { [weak self] in self?.push(AppearanceViewController()) },
                .link(symbol: "globe", title: L("Язык")) { [weak self] in self?.push(LanguageViewController()) },
            ]),
            // 3.5 (the owner's choice): «Подписки и серверы», «Порядок серверов» and
            // «Проверка соединения» are gone from here — Home reaches all three (the
            // server capsule, the servers' «…», the bottom of analytics).
            FormSection([
                .link(symbol: "folder", title: L("Управление подписками")) { [weak self] in self?.push(SubscriptionsViewController()) },
                .link(symbol: "arrow.clockwise", title: L("Обновление подписок")) { [weak self] in self?.push(NetworkSettingsViewController(.updates)) },
            ]),
            // 3.5 beta 2 (the owner): «Маршрутизация и DNS» and «Пинг» are inside «Подключение».
            FormSection([
                .link(symbol: "wifi", title: L("Подключение")) { [weak self] in self?.push(NetworkSettingsViewController(.connection)) },
            ]),
            FormSection([
                .symbol("lock", .toggle(title: L("Блокировка приложения"), get: { Prefs.appLock }, set: { Prefs.appLock = $0 })),
                .link(symbol: "externaldrive.badge.icloud", title: L("Резервные копии")) { [weak self] in self?.push(BackupViewController()) },
                .link(symbol: "hand.raised", title: L("Конфиденциальность")) { [weak self] in self?.push(PrivacyViewController()) },
                .link(symbol: "eye", title: L("Сетевая активность приложения")) { [weak self] in self?.push(NetworkActivityViewController()) },
            ]),
            FormSection(footer: AboutViewController.version, [
                .link(symbol: "doc.text.magnifyingglass", title: L("Журнал службы")) { [weak self] in self?.push(ServiceLogViewController()) },
                .link(symbol: "info.circle", title: L("О приложении")) { [weak self] in self?.push(AboutViewController()) },
            ]),
        ]
    }
}

/// «Внешний вид» (3.5, the owner's choice): the colours, the background and
/// the font are here, not one page further; the glass has its own page.
/// «Обои» is gone: its one switch (AMOLED) was in «Цвета и шрифт» as well.
final class AppearanceViewController: ColorsViewController {
    override init() { super.init(title: L("Внешний вид")) }

    override func build() -> [FormSection] {
        [
            FormSection([
                .picker(title: L("Интерфейс"), options: [("modern", L("Современный")), ("classic", L("Классика"))], get: { Prefs.style.rawValue },
                        set: { Prefs.style = InterfaceStyle(rawValue: $0) ?? .minimal }),
                .picker(title: L("Оформление"), options: [("system", L("Системная")), ("light", L("Светлая")), ("dark", L("Тёмная"))], get: { Prefs.theme }, set: { Prefs.theme = $0 }),
            ]),
        ] + colorSections(background: true) + [
            FormSection([
                .link(symbol: "drop", title: L("Стекло и прозрачность")) { [weak self] in self?.navigationController?.pushViewController(GlassSettingsViewController(), animated: true) },
                .toggle(title: L("Только иконки вкладок"), get: { Prefs.hideTabLabels }, set: { Prefs.hideTabLabels = $0 }),
                .toggle(title: L("Акцентная активная точка"), get: { Prefs.accentDots }, set: { Prefs.accentDots = $0 }),
            ]),
        ]
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
            // 3.5 beta 2 (the owner): the cards of analytics — how solid, and their colour.
            FormSection(L("Фон карточек"), footer: L("Карточки аналитики: график скорости, сеанс, ядро, соединения, маршруты."), [
                .slider(title: L("Плотность фона"), get: { Prefs.cardFill }, set: { Prefs.cardFill = $0 }),
                .color(title: L("Цвет фона"), get: { UIColor(hex: Prefs.cardHex) ?? UIColor.secondarySystemBackground }, set: { Prefs.cardHex = $0.hexString }),
                .button(title: L("Сбросить фон карточек"), destructive: false) {
                    Prefs.cardHex = nil
                    Prefs.cardFill = Prefs.defaultCardFill
                },
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

    override func build() -> [FormSection] {
        let changed = { App.shared.networkSettingsChanged() }
        switch part {
        case .ping: return [
            FormSection([
                .picker(title: L("Режим пинга"), options: [("primary", L("Основной")), ("classic", L("Классика")), ("alternative", L("Альтернативный"))], get: { Prefs.pingMode }, set: { Prefs.pingMode = $0 }),
                .note(modeNote),
            ] + (Prefs.autoPingAvailable ? [
                .toggle(title: L("Автопинг"), get: { Prefs.autoPing }, set: { Prefs.autoPing = $0 }),
                .note(L("Задержка серверов проверяется сама при открытии приложения и после обновления подписки.")),
            ] : []) + [
                .note(L("Тест только показывает задержку и не меняет выбранный сервер. Его можно остановить в любой момент.")),
            ]),
        ]
        case .updates: return [
            FormSection([
                .toggle(title: L("Автообновление подписок"), get: { Prefs.autoUpdateSubscriptions }, set: { Prefs.autoUpdateSubscriptions = $0 }),
                .picker(title: L("Время обновления"), options: Prefs.subscriptionUpdateOptions,
                        get: { String(Prefs.subscriptionUpdateHour) }, set: { Prefs.subscriptionUpdateHour = Int($0) ?? SubscriptionSchedule.everyDay }),
                .note(L("Подписки обновляются сами раз в 24 часа или каждый день в выбранное время — при первом открытии приложения после него (и пока оно открыто). Выключено — только вручную.")),
            ]),
        ]
        case .connection: return [
            FormSection([
                .link(symbol: "arrow.triangle.branch", title: L("Маршрутизация и DNS")) { [weak self] in
                    self?.navigationController?.pushViewController(NetworkSettingsViewController(.routing), animated: true)
                },
                .link(symbol: "waveform.path.ecg", title: L("Пинг")) { [weak self] in
                    self?.navigationController?.pushViewController(NetworkSettingsViewController(.ping), animated: true)
                },
            ]),
            FormSection([
                .toggle(title: L("Автоподключение в неизвестных Wi-Fi"), get: { Prefs.autoConnect }, set: { Prefs.autoConnect = $0; App.shared.tunnel.applySettings() }),
                .link(symbol: nil, title: L("Мои сети")) { [weak self] in self?.navigationController?.pushViewController(TrustedNetworksViewController(), animated: true) },
                .note(L("VPN включается сам при подключении к Wi-Fi не из «Моих сетей». В своих сетях и по сотовой связи сам не включается. Выключили VPN кнопкой в неизвестной сети — в ней он не включится сам, пока вы снова не включите его.")),
                .toggle(title: L("Kill switch"), get: { Prefs.killSwitch }, set: { Prefs.killSwitch = $0; App.shared.tunnel.applySettings() }),
                .note(L("Пока VPN включён, но не подключён (переподключение, сбой), приложения не выходят в интернет напрямую. Исключения iOS: push-уведомления Apple и службы оператора (звонки, SMS) iOS может пускать мимо VPN. При большом трафике (видео) тратит больше батареи: каждый пакет обрабатывает ядро туннеля. Действует со следующего подключения.")),
            ]),
        ]
        case .routing: return [
            FormSection(L("Маршрутизация"), [
                .link(symbol: nil, title: L("Блокировка рекламы")) { [weak self] in self?.navigationController?.pushViewController(AdBlockViewController(), animated: true) },
                .toggle(title: L("Обход российских сайтов"), get: { Prefs.bypassRussia }, set: { Prefs.bypassRussia = $0; changed() }),
                .note(L("Российские сайты открываются мимо VPN, с вашим настоящим IP. Сайт, который подгружает что-то с российского адреса, может увидеть настоящий IP рядом с IP VPN.")),
                .toggle(title: L("Защищённый DNS"), get: { Prefs.secureDNS }, set: { Prefs.secureDNS = $0; App.shared.tunnel.applySettings() }),
                .toggle(title: L("Локальная сеть"), get: { Prefs.localNetwork }, set: { Prefs.localNetwork = $0; changed() }),
                .note(L("Серверы DNS берутся из конфигурации. После изменения системных маршрутов переподключите VPN.")),
            ]),
            FormSection(L("DNS вне туннеля"), footer: L("Адреса серверов находятся вне туннеля, по DNS over HTTPS через выбранные резолверы, а если сеть его не пропускает — обычным DNS через них же. Российские сайты при обходе — через Яндекс."), [
                .picker(title: L("Резолверы"), options: DirectResolvers.presets.map { preset -> (value: String, title: String) in (preset.id, Prefs.resolverTitle(preset.id)) },
                        get: { Prefs.directResolvers }, set: { Prefs.directResolvers = $0; changed() }),
            ]),
        ]
        }
    }
}

/// «Цвета и шрифт». Classic opens it as a page; Minimal has the same rows on
/// «Внешний вид» (3.5), with its background's colours as well.
class ColorsViewController: FormViewController {
    init() { super.init(title: L("Цвета и шрифт")) }
    override init(title: String) { super.init(title: title) }
    private var pendingAccent: UIColor?
    private var pendingText: UIColor?
    private var pendingPanel: UIColor?

    override func build() -> [FormSection] { colorSections(background: false) }

    /// `background`: the Minimal background's own colours (`Wallpaper`).
    func colorSections(background: Bool) -> [FormSection] {
        var colors: [FormRow] = [
            .color(title: L("Акцентный цвет"), get: { [weak self] in self?.pendingAccent ?? Theme.accent }, set: { [weak self] in self?.pendingAccent = $0 }),
        ]
        // Minimal: AMOLED stands with the background.
        if !background { colors.append(.toggle(title: L("AMOLED — чёрный фон в тёмной теме"), get: { Prefs.amoled }, set: { Prefs.amoled = $0 })) }
        colors.append(.button(title: L("Применить цвета"), destructive: false) { [weak self] in
            if let color = self?.pendingAccent { Prefs.setAccentHex(color.hexString) }
            self?.pendingAccent = nil
        })
        colors.append(.button(title: L("Сбросить цвета"), destructive: false) { [weak self] in
            self?.pendingAccent = nil
            Prefs.setAccentHex(nil)
        })
        var sections: [FormSection] = [
            FormSection(L("Цвета"), footer: background ? nil : L("Цвета этого интерфейса сохраняются отдельно. Выключите AMOLED для тёмно-серого фона."), colors),
        ]
        if background { sections.append(backgroundSection()) }
        sections.append(FormSection(L("Текст и шрифт"), [
            .color(title: L("Цвет текста"), get: { [weak self] in self?.pendingText ?? Theme.text }, set: { [weak self] in self?.pendingText = $0 }),
            .color(title: L("Цвет панелей"), get: { [weak self] in self?.pendingPanel ?? Theme.panel }, set: { [weak self] in self?.pendingPanel = $0 }),
            .button(title: L("Применить цвет текста и панелей"), destructive: false) { [weak self] in
                if let color = self?.pendingText { Prefs.textHex = color.hexString }
                if let color = self?.pendingPanel { Prefs.panelHex = color.hexString }
                self?.pendingText = nil
                self?.pendingPanel = nil
            },
            .button(title: L("Импорт шрифта TTF / OTF"), destructive: false) { [weak self] in self?.importFont() },
            .note(L("Шрифт: ") + (Prefs.fontName.isEmpty ? L("системный") : Prefs.fontName)),
            .button(title: L("Сбросить текст, панели и шрифт"), destructive: false) {
                Prefs.fontName = ""
                Prefs.textHex = nil
                Prefs.panelHex = nil
                Prefs.fontFile = nil
            },
        ]))
        return sections
    }

    /// 3.5: the Home and analytics background of up to four colours, as 1.x had it.
    private func backgroundSection() -> FormSection {
        var rows: [FormRow] = [
            .toggle(title: L("AMOLED — чёрный фон в тёмной теме"), get: { Prefs.amoled }, set: { Prefs.amoled = $0 }),
            .toggle(title: L("Свой фон"), get: { Prefs.customBackground }, set: { Prefs.customBackground = $0 }),
        ]
        guard Prefs.customBackground else {
            return FormSection(L("Фон"), footer: L("Фон главной и аналитики: белый в светлой теме, чёрный или тёмно-серый в тёмной."), rows)
        }
        let colors = Prefs.backgroundColors
        for index in colors.indices {
            rows.append(.color(title: Lf("Цвет %@", "\(index + 1)"), get: { let all = Prefs.backgroundColors; return UIColor(hex: all.indices.contains(index) ? all[index] : nil) ?? .black }, set: { color in
                var next = Prefs.backgroundColors
                guard next.indices.contains(index) else { return }
                next[index] = color.hexString
                Prefs.backgroundColors = next
            }))
        }
        if colors.count < Prefs.maxBackgroundColors {
            rows.append(.button(title: L("Добавить цвет"), destructive: false) {
                var next = Prefs.backgroundColors
                next.append(next.count.isMultiple(of: 2) ? "BFBFBF" : "404040")
                Prefs.backgroundColors = next
            })
        }
        if colors.count > 1 {
            rows.append(.button(title: L("Убрать последний цвет"), destructive: true) {
                Prefs.backgroundColors = Array(Prefs.backgroundColors.dropLast())
            })
        }
        return FormSection(L("Фон"), footer: L("Фон главной и аналитики, в обеих темах. Два цвета: сверху и снизу. Три: два сверху и один снизу. Четыре: верхний левый, верхний правый, нижний левый, нижний правый."), rows)
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
