import TunnelCore
import UIKit

/// «Блокировка рекламы» (both styles): on/off and the list, as in Anywhere's Purify:
/// rules ahead of every other route, blocked names answered with 0.0.0.0 / ::,
/// connections matched by name (SNI) rejected. Works while the VPN is on.
final class AdBlockViewController: FormViewController {
    init() { super.init(title: L("Блокировка рекламы")) }

    private static var levels: [(AdBlockLevel, String, String)] { [
        (.basic, L("Базовый"), L("Около 900 рекламных доменов (v2fly category-ads-all). Почти не занимает памяти.")),
        (.standard, L("Стандартный"), L("Плюс HaGeZi Light: около 88 000 доменов рекламы, трекеров и телеметрии. Практически без ложных блокировок.")),
        (.extended, L("Расширенный"), L("Плюс HaGeZi Normal: около 208 000 доменов. Блокирует больше, изредка может задеть нужный сайт; занимает больше памяти туннеля.")),
    ] }

    override func build() -> [FormSection] {
        let changed = { App.shared.networkSettingsChanged() }
        var sections = [
            FormSection(footer: L("Запросы к рекламным и следящим серверам отклоняются в трафике VPN раньше остальных правил: DNS отвечает 0.0.0.0, соединения по имени сервера (SNI) закрываются. Реклама, которая приходит с домена самого сервиса (YouTube, Spotify), так не убирается. Изменения применяются к работающему туннелю."), [
                .toggle(title: L("Блокировка рекламы"), get: { Prefs.adBlocking }, set: { [weak self] in
                    Prefs.adBlocking = $0
                    changed()
                    self?.rebuild()
                }),
            ]),
        ]
        guard Prefs.adBlocking else { return sections }
        let current = Prefs.adBlockLevel
        sections.append(FormSection(L("Список"), footer: Self.levels.first { $0.0 == current }?.2, Self.levels.map { level, title, _ in
            .check(title: title, selected: { Prefs.adBlockLevel == level }, action: { [weak self] in
                guard Prefs.adBlockLevel != level else { return }
                Prefs.adBlockLevel = level
                changed()
                self?.rebuild()
            })
        }))
        return sections
    }
}
