import CoreText
import UniformTypeIdentifiers
import TunnelCore
import UIKit

/// Settings root: four groups, as in 1.5.0.
final class MinimalSettingsViewController: FormViewController {
    init() {
        super.init(title: "Настройки")
        largeTitle = true
    }

    private func push(_ controller: UIViewController) {
        navigationController?.pushViewController(controller, animated: true)
    }

    override func build() -> [FormSection] {
        [
            FormSection([
                .link(symbol: "paintpalette", title: "Внешний вид") { [weak self] in self?.push(AppearanceViewController()) },
                .link(symbol: "globe", title: "Язык") { [weak self] in self?.push(LanguageViewController()) },
            ]),
            FormSection([
                .link(symbol: "server.rack", title: "Подписки и серверы") { [weak self] in
                    self?.present(MinimalServersViewController.wrapped(), animated: true)
                },
                .link(symbol: "folder", title: "Управление подписками") { [weak self] in self?.push(SubscriptionsViewController()) },
                .link(symbol: "arrow.up.arrow.down", title: "Порядок серверов") { [weak self] in self?.push(ServerOrderViewController()) },
            ]),
            FormSection([
                .link(symbol: "network", title: "Сеть и безопасность") { [weak self] in self?.push(NetworkSettingsViewController()) },
                .link(symbol: "stethoscope", title: "Проверка соединения") { [weak self] in self?.push(DiagnosticsViewController()) },
                .link(symbol: "doc.text.magnifyingglass", title: "Журнал службы") { [weak self] in self?.push(ServiceLogViewController()) },
            ]),
            FormSection([
                .link(symbol: "externaldrive.badge.icloud", title: "Резервные копии") { [weak self] in self?.push(BackupViewController()) },
                .link(symbol: "eye", title: "Сетевая активность приложения") { [weak self] in self?.push(NetworkActivityViewController()) },
                .link(symbol: "info.circle", title: "О приложении") { [weak self] in self?.push(AboutViewController()) },
            ]),
        ]
    }
}

final class AppearanceViewController: FormViewController {
    init() { super.init(title: "Внешний вид") }

    override func build() -> [FormSection] {
        func slider(_ title: String, _ key: String) -> FormRow {
            .slider(title: title, get: { Prefs.opacity(key) }, set: { Prefs.setOpacity($0, key) })
        }
        return [
            FormSection([
                .picker(title: "Интерфейс", options: [("modern", "Минималистичный"), ("classic", "Классика")], get: { Prefs.style.rawValue },
                        set: { Prefs.style = InterfaceStyle(rawValue: $0) ?? .minimal }),
                .picker(title: "Оформление", options: [("system", "Системная"), ("light", "Светлая"), ("dark", "Тёмная")], get: { Prefs.theme }, set: { Prefs.theme = $0 }),
                .link(symbol: "photo", title: "Обои") { [weak self] in self?.navigationController?.pushViewController(WallpaperViewController(), animated: true) },
                .link(symbol: "paintpalette", title: "Цвета и шрифт") { [weak self] in self?.navigationController?.pushViewController(ColorsViewController(), animated: true) },
            ]),
            FormSection([
                .picker(title: "Стекло", options: [("clear", "Чистое"), ("regular", "Блюр"), ("tinted", "Tinted")], get: { Prefs.glassStyle }, set: { Prefs.glassStyle = $0 }),
                .toggle(title: "Непрозрачные панели настроек", get: { Prefs.solidSettings }, set: { Prefs.solidSettings = $0 }),
                .toggle(title: "Только иконки вкладок", get: { Prefs.hideTabLabels }, set: { Prefs.hideTabLabels = $0 }),
                .toggle(title: "Акцентная активная точка", get: { Prefs.accentDots }, set: { Prefs.accentDots = $0 }),
            ]),
            FormSection("Прозрачность стекла", [
                slider("Весь интерфейс", Prefs.glassOpacityKey),
                slider("Кнопка подключения", Prefs.buttonOpacityKey),
                slider("Выбранный сервер", Prefs.serverOpacityKey),
                slider("Карточки и панели", Prefs.cardOpacityKey),
            ]),
        ]
    }
}

final class LanguageViewController: FormViewController {
    init() { super.init(title: "Язык") }

    override func build() -> [FormSection] {
        [FormSection(footer: "В этой версии интерфейс доступен на русском языке.", [
            .check(title: "Русский", selected: { true }, action: {}),
        ])]
    }
}

final class NetworkSettingsViewController: FormViewController {
    init() {
        super.init(title: "Сеть")
        largeTitle = true
    }

    private var modeNote: String {
        switch Prefs.pingMode {
        case "classic":
            return "Классика: активный узел проверяется по HTTPS раз в минуту. Список: generate_204 по HTTPS через каждый узел, до 8 одновременно, ожидание до 5 с; без VPN — TCP-соединение с сервером."
        case "alternative":
            return "Альтернативный: короткая HTTP-проверка через узел, до 12 одновременно, ожидание до 2,5 с; без VPN — TCP. HTTP-проверка не подтверждает доступность HTTPS-сайтов."
        default:
            return "Основной: сначала TCP-проверка доступности сервера (1,5 с), затем generate_204 через каждый ответивший узел (3 с), до 20 одновременно; UDP-протоколы сразу проходят URL-тест. Без VPN доступна только TCP-проверка. Результаты хранятся 2,5 минуты, при открытии списка проверяются только устаревшие."
        }
    }

    override func build() -> [FormSection] {
        let changed = { App.shared.networkSettingsChanged() }
        return [
            FormSection("Измерение задержки", [
                .picker(title: "Режим пинга", options: [("primary", "Основной"), ("classic", "Классика"), ("alternative", "Альтернативный")], get: { Prefs.pingMode }, set: { Prefs.pingMode = $0 }),
                .note(modeNote),
                .note("Тест только показывает задержку и не меняет выбранный сервер. Его можно остановить в любой момент."),
            ]),
            FormSection("Подключение", [
                .toggle(title: "Автоподключение", get: { Prefs.autoConnect }, set: { Prefs.autoConnect = $0; App.shared.tunnel.applySettings() }),
                .toggle(title: "Неизвестные Wi-Fi", get: { Prefs.unknownWiFi }, set: { Prefs.unknownWiFi = $0; App.shared.tunnel.applySettings() }),
                .toggle(title: "Автоматический failover", get: { Prefs.autoFailover }, set: { Prefs.autoFailover = $0 }),
            ]),
            FormSection("Маршрутизация", [
                .toggle(title: "Блокировка рекламы", get: { Prefs.adBlocking }, set: { Prefs.adBlocking = $0; changed() }),
                .note("Рекламные домены блокируются локально в трафике VPN. Список встроен в приложение и обновляется вместе с ним. Реклама с домена самого сайта может остаться. Изменение применяется к работающему туннелю."),
                .toggle(title: "Обход российских сайтов", get: { Prefs.bypassRussia }, set: { Prefs.bypassRussia = $0; changed() }),
                .toggle(title: "Защищённый DNS", get: { Prefs.secureDNS }, set: { Prefs.secureDNS = $0; App.shared.tunnel.applySettings() }),
                .toggle(title: "Локальная сеть", get: { Prefs.localNetwork }, set: { Prefs.localNetwork = $0; changed() }),
                .note("Серверы DNS берутся из конфигурации. После изменения системных маршрутов переподключите VPN."),
            ]),
            FormSection("Безопасность", [
                .toggle(title: "Блокировка приложения", get: { Prefs.appLock }, set: { Prefs.appLock = $0 }),
            ]),
        ]
    }
}

final class ColorsViewController: FormViewController {
    init() { super.init(title: "Цвета и шрифт") }
    private var pendingAccent: UIColor?
    private var pendingText: UIColor?
    private var pendingPanel: UIColor?

    override func build() -> [FormSection] {
        [
            FormSection("Цвета", footer: "Цвета этого интерфейса сохраняются отдельно. Выключите AMOLED для тёмно-серого фона.", [
                .color(title: "Акцентный цвет", get: { [weak self] in self?.pendingAccent ?? Theme.accent }, set: { [weak self] in self?.pendingAccent = $0 }),
                .toggle(title: "AMOLED — чёрный фон в тёмной теме", get: { Prefs.amoled }, set: { Prefs.amoled = $0 }),
                .button(title: "Применить цвета", destructive: false) { [weak self] in
                    if let color = self?.pendingAccent { Prefs.setAccentHex(color.hexString) }
                    self?.pendingAccent = nil
                },
                .button(title: "Сбросить цвета", destructive: false) { [weak self] in
                    self?.pendingAccent = nil
                    Prefs.setAccentHex(nil)
                },
            ]),
            FormSection("Текст и шрифт", [
                .color(title: "Цвет текста", get: { [weak self] in self?.pendingText ?? Theme.text }, set: { [weak self] in self?.pendingText = $0 }),
                .color(title: "Цвет панелей", get: { [weak self] in self?.pendingPanel ?? Theme.panel }, set: { [weak self] in self?.pendingPanel = $0 }),
                .button(title: "Применить цвет текста и панелей", destructive: false) { [weak self] in
                    if let color = self?.pendingText { Prefs.textHex = color.hexString }
                    if let color = self?.pendingPanel { Prefs.panelHex = color.hexString }
                    self?.pendingText = nil
                    self?.pendingPanel = nil
                },
                .button(title: "Импорт шрифта TTF / OTF", destructive: false) { [weak self] in self?.importFont() },
                .note("Шрифт: " + (Prefs.fontName.isEmpty ? "системный" : Prefs.fontName)),
                .button(title: "Сбросить текст, панели и шрифт", destructive: false) {
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
            App.shared.notice.value = "Этот файл не удалось прочитать как шрифт."
            return
        }
        let directory = Theme.fontsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "imported-\(Int(Date().timeIntervalSince1970)).\(url.pathExtension.isEmpty ? "ttf" : url.pathExtension)"
        do {
            try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(name))
        } catch {
            App.shared.notice.value = "Шрифт не сохранён: \(error.localizedDescription)"
            return
        }
        Prefs.fontName = (CTFontDescriptorCopyAttribute(first, kCTFontDisplayNameAttribute) as? String) ?? url.deletingPathExtension().lastPathComponent
        Prefs.fontFile = name
        done?()
    }
}

final class WallpaperViewController: FormViewController {
    init() { super.init(title: "Обои") }

    override func build() -> [FormSection] {
        [FormSection(footer: "Фон «Минималистичного»: белый в светлой теме и чёрный в тёмной. AMOLED переключается в «Цвета и шрифт».", [
            .toggle(title: "AMOLED — чёрный фон в тёмной теме", get: { Prefs.amoled }, set: { Prefs.amoled = $0 }),
        ])]
    }
}
