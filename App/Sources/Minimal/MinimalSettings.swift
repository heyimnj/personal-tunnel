import CoreText
import UniformTypeIdentifiers
import TunnelCore
import UIKit

/// Settings root: four groups, as in 1.5.0.
final class MinimalSettingsViewController: FormViewController {
    init() {
        super.init(title: L("Настройки"))
        largeTitle = true
    }

    private func push(_ controller: UIViewController) {
        navigationController?.pushViewController(controller, animated: true)
    }

    override func build() -> [FormSection] {
        [
            FormSection([
                .link(symbol: "paintpalette", title: L("Внешний вид")) { [weak self] in self?.push(AppearanceViewController()) },
                .link(symbol: "globe", title: L("Язык")) { [weak self] in self?.push(LanguageViewController()) },
            ]),
            FormSection([
                .link(symbol: "server.rack", title: L("Подписки и серверы")) { [weak self] in
                    self?.present(MinimalServersViewController.wrapped(), animated: true)
                },
                .link(symbol: "folder", title: L("Управление подписками")) { [weak self] in self?.push(SubscriptionsViewController()) },
                .link(symbol: "arrow.up.arrow.down", title: L("Порядок серверов")) { [weak self] in self?.push(ServerOrderViewController()) },
            ]),
            FormSection([
                .link(symbol: "network", title: L("Сеть и безопасность")) { [weak self] in self?.push(NetworkSettingsViewController()) },
                .link(symbol: "stethoscope", title: L("Проверка соединения")) { [weak self] in self?.push(DiagnosticsViewController()) },
                .link(symbol: "doc.text.magnifyingglass", title: L("Журнал службы")) { [weak self] in self?.push(ServiceLogViewController()) },
            ]),
            FormSection(footer: AboutViewController.version, [
                .link(symbol: "externaldrive.badge.icloud", title: L("Резервные копии")) { [weak self] in self?.push(BackupViewController()) },
                .link(symbol: "eye", title: L("Сетевая активность приложения")) { [weak self] in self?.push(NetworkActivityViewController()) },
                .link(symbol: "info.circle", title: L("О приложении")) { [weak self] in self?.push(AboutViewController()) },
            ]),
        ]
    }
}

final class AppearanceViewController: FormViewController {
    init() { super.init(title: L("Внешний вид")) }

    override func build() -> [FormSection] {
        func slider(_ title: String, _ key: String) -> FormRow {
            .slider(title: title, get: { Prefs.opacity(key) }, set: { Prefs.setOpacity($0, key) })
        }
        return [
            FormSection([
                .picker(title: L("Интерфейс"), options: [("modern", L("Минималистичный")), ("classic", L("Классика"))], get: { Prefs.style.rawValue },
                        set: { Prefs.style = InterfaceStyle(rawValue: $0) ?? .minimal }),
                .picker(title: L("Оформление"), options: [("system", L("Системная")), ("light", L("Светлая")), ("dark", L("Тёмная"))], get: { Prefs.theme }, set: { Prefs.theme = $0 }),
                .link(symbol: "photo", title: L("Обои")) { [weak self] in self?.navigationController?.pushViewController(WallpaperViewController(), animated: true) },
                .link(symbol: "paintpalette", title: L("Цвета и шрифт")) { [weak self] in self?.navigationController?.pushViewController(ColorsViewController(), animated: true) },
            ]),
            FormSection([
                .picker(title: L("Стекло"), options: [("clear", L("Чистое")), ("regular", L("Блюр")), ("tinted", "Tinted")], get: { Prefs.glassStyle }, set: { Prefs.glassStyle = $0 }),
                .toggle(title: L("Непрозрачные панели настроек"), get: { Prefs.solidSettings }, set: { Prefs.solidSettings = $0 }),
                .toggle(title: L("Только иконки вкладок"), get: { Prefs.hideTabLabels }, set: { Prefs.hideTabLabels = $0 }),
                .toggle(title: L("Акцентная активная точка"), get: { Prefs.accentDots }, set: { Prefs.accentDots = $0 }),
            ]),
            FormSection(L("Прозрачность стекла"), [
                slider(L("Весь интерфейс"), Prefs.glassOpacityKey),
                slider(L("Кнопка подключения"), Prefs.buttonOpacityKey),
                slider(L("Выбранный сервер"), Prefs.serverOpacityKey),
                slider(L("Карточки и панели"), Prefs.cardOpacityKey),
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

final class NetworkSettingsViewController: FormViewController {
    init() {
        super.init(title: L("Сеть"))
        largeTitle = true
    }

    private var modeNote: String {
        switch Prefs.pingMode {
        case "classic":
            return L("Классика: активный узел проверяется по HTTPS раз в минуту. Список: generate_204 по HTTPS через каждый узел, до 8 одновременно, ожидание до 5 с; без VPN — то же ядром приложения, 3 с, до 10 одновременно.")
        case "alternative":
            return L("Альтернативный: короткая HTTP-проверка через узел, до 12 одновременно, ожидание до 2,5 с; без VPN — ядром приложения. HTTP-проверка не подтверждает доступность HTTPS-сайтов.")
        default:
            return L("Основной: generate_204 через каждый узел подключённой подписки (3 с), до 20 одновременно. Серверы остальных подписок и все серверы без VPN проверяет ядро приложения: generate_204 через каждый сервер (3 с), до 10 одновременно; с VPN их задержка включает туннель. Результаты хранятся 2,5 минуты, при открытии списка проверяются только устаревшие.")
        }
    }

    override func build() -> [FormSection] {
        let changed = { App.shared.networkSettingsChanged() }
        return [
            FormSection(L("Измерение задержки"), [
                .picker(title: L("Режим пинга"), options: [("primary", L("Основной")), ("classic", L("Классика")), ("alternative", L("Альтернативный"))], get: { Prefs.pingMode }, set: { Prefs.pingMode = $0 }),
                .note(modeNote),
            ] + (Prefs.autoPingAvailable ? [
                .toggle(title: L("Автопинг"), get: { Prefs.autoPing }, set: { Prefs.autoPing = $0 }),
                .note(L("Задержка серверов проверяется сама при открытии приложения и после обновления подписки.")),
            ] : []) + [
                .note(L("Тест только показывает задержку и не меняет выбранный сервер. Его можно остановить в любой момент.")),
            ]),
            FormSection(L("Подключение"), [
                .toggle(title: L("Автоподключение"), get: { Prefs.autoConnect }, set: { Prefs.autoConnect = $0; App.shared.tunnel.applySettings() }),
                .toggle(title: L("Неизвестные Wi-Fi"), get: { Prefs.unknownWiFi }, set: { Prefs.unknownWiFi = $0; App.shared.tunnel.applySettings() }),
                .toggle(title: L("Автоматический failover"), get: { Prefs.autoFailover }, set: { Prefs.autoFailover = $0 }),
            ]),
            FormSection(L("Маршрутизация"), [
                .link(symbol: nil, title: L("Блокировка рекламы")) { [weak self] in self?.navigationController?.pushViewController(AdBlockViewController(), animated: true) },
                .toggle(title: L("Обход российских сайтов"), get: { Prefs.bypassRussia }, set: { Prefs.bypassRussia = $0; changed() }),
                .toggle(title: L("Защищённый DNS"), get: { Prefs.secureDNS }, set: { Prefs.secureDNS = $0; App.shared.tunnel.applySettings() }),
                .toggle(title: L("Локальная сеть"), get: { Prefs.localNetwork }, set: { Prefs.localNetwork = $0; changed() }),
                .note(L("Серверы DNS берутся из конфигурации. После изменения системных маршрутов переподключите VPN.")),
            ]),
            FormSection(L("Безопасность"), [
                .toggle(title: L("Блокировка приложения"), get: { Prefs.appLock }, set: { Prefs.appLock = $0 }),
            ]),
        ]
    }
}

final class ColorsViewController: FormViewController {
    init() { super.init(title: L("Цвета и шрифт")) }
    private var pendingAccent: UIColor?
    private var pendingText: UIColor?
    private var pendingPanel: UIColor?

    override func build() -> [FormSection] {
        [
            FormSection(L("Цвета"), footer: L("Цвета этого интерфейса сохраняются отдельно. Выключите AMOLED для тёмно-серого фона."), [
                .color(title: L("Акцентный цвет"), get: { [weak self] in self?.pendingAccent ?? Theme.accent }, set: { [weak self] in self?.pendingAccent = $0 }),
                .toggle(title: L("AMOLED — чёрный фон в тёмной теме"), get: { Prefs.amoled }, set: { Prefs.amoled = $0 }),
                .button(title: L("Применить цвета"), destructive: false) { [weak self] in
                    if let color = self?.pendingAccent { Prefs.setAccentHex(color.hexString) }
                    self?.pendingAccent = nil
                },
                .button(title: L("Сбросить цвета"), destructive: false) { [weak self] in
                    self?.pendingAccent = nil
                    Prefs.setAccentHex(nil)
                },
            ]),
            FormSection(L("Текст и шрифт"), [
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
            ]),
        ]
    }

    private func importFont() {
        FontImporter.shared.present(from: self) { [weak self] in self?.rebuild() }
    }
}

/// Picks a TTF/OTF in Files and copies it into the app.
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

final class WallpaperViewController: FormViewController {
    init() { super.init(title: L("Обои")) }

    override func build() -> [FormSection] {
        [FormSection(footer: L("Фон «Минималистичного»: белый в светлой теме и чёрный в тёмной. AMOLED переключается в «Цвета и шрифт»."), [
            .toggle(title: L("AMOLED — чёрный фон в тёмной теме"), get: { Prefs.amoled }, set: { Prefs.amoled = $0 }),
        ])]
    }
}
