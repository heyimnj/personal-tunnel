import TunnelCore
import UIKit

/// «Блокировка рекламы» (both styles): on/off and the list, as in Anywhere's Purify:
/// rules ahead of every other route, blocked names answered with 0.0.0.0 / ::,
/// connections matched by name (SNI) rejected. Works while the VPN is on.
///
/// 3.0.5: stronger lists (HaGeZi Light / Pro / Pro++ instead of geosite / Light /
/// Normal), Russian and mobile ad servers from AdGuard's filters at every level,
/// and apps' own encrypted DNS refused so it cannot resolve around the blocking.
final class AdBlockViewController: FormViewController {
    init() { super.init(title: L("Блокировка рекламы")) }

    private static var levels: [(AdBlockLevel, String, String)] { [
        (.basic, L("Базовый"), L("HaGeZi Light: около 90 000 доменов рекламы и трекеров, и российские рекламные сети. Меньше всего памяти туннеля.")),
        (.standard, L("Стандартный"), L("HaGeZi Pro: около 226 000 доменов рекламы, трекеров, телеметрии и рекламных SDK в приложениях, и российские рекламные сети (из фильтров AdGuard). Почти без ложных блокировок.")),
        (.extended, L("Расширенный"), L("HaGeZi Pro++: около 243 000 доменов. Блокирует больше; изредка может задеть нужный сайт или вход через соцсети.")),
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
        sections.append(FormSection(footer: L("Браузеры и приложения со своим зашифрованным DNS (DoH, DoT), а также Safari через «Частный узел iCloud» узнают адреса в обход блокировки. Их DNS-серверы закрываются, и они переходят на DNS туннеля. Выключите, если какое-то приложение перестанет работать."), [
            .toggle(title: L("Не пускать в обход блокировки"), get: { Prefs.blockEncryptedDNS }, set: {
                Prefs.blockEncryptedDNS = $0
                changed()
            }),
        ]))
        return sections
    }
}
