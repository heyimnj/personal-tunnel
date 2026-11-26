import TunnelCore
import UIKit

/// «Конфиденциальность» (3.2.1): PRIVACY.md in short, the device data each
/// subscription panel gets, and «Удалить все данные». Both interface styles
/// open this page from their settings.
final class PrivacyViewController: FormViewController {
    static let policyURL = URL(string: "https://github.com/heyimnj/personal-tunnel/blob/main/PRIVACY.md")!

    init() { super.init(title: L("Конфиденциальность")) }

    override func viewDidLoad() {
        super.viewDidLoad()
        App.shared.store.library.observe(self, fireNow: false) { [weak self] _ in self?.rebuild() }
    }

    override func build() -> [FormSection] {
        var device: [FormRow] = [
            .toggle(title: L("Для новых подписок"), get: { Prefs.deviceDataForNewSubscriptions }, set: { Prefs.deviceDataForNewSubscriptions = $0 }),
        ]
        for subscription in App.shared.library.subscriptions where subscription.isRemote {
            let id = subscription.id
            device.append(.toggle(title: subscription.name, get: { App.shared.library.subscription(id)?.sendsDeviceIdentity ?? true }, set: { value in
                App.setSendsDeviceData(value, for: id)
            }))
        }
        // 3.5.23: the HWID is shown here (it was on «Сетевая активность», now gone).
        device.append(.value(title: "HWID", detail: { let id = DeviceIdentity.hwid; return id.count > 8 ? String(id.prefix(4)) + "…" + String(id.suffix(4)) : id }))
        return [
            FormSection(L("Что приложение не собирает"), [
                .note(L("Нет аналитики, телеметрии, рекламы и учётных записей. У приложения нет своего сервера: разработчик ничего не получает.")),
            ]),
            FormSection(L("Куда приложение подключается само"), [
                .note(L("К адресам подписок, которые вы добавили (только https), и к серверам VPN. Для пинга — к адресам серверов напрямую, по физической сети, и к www.gstatic.com/generate_204 через сервер; для «Проверки соединения» — к www.gstatic.com. Адреса серверов находятся по DNS over HTTPS через резолверы из «DNS вне туннеля». Подписки обновляются по вашей команде, после подключения VPN, если не загрузились без него, и один раз после обновления приложения.")),
            ]),
            FormSection(L("Что получает провайдер подписки"), [
                .note(L("Ваш IP-адрес и запрос от имени клиента INCY или Happ: так панели отдают все серверы. С «Передавать данные устройства провайдеру» ещё HWID (у каждой новой подписки свой) и модель iPhone; версию iOS и язык — только если без них панель не отдала серверы. Перед добавлением приложение показывает хост подписки и спрашивает про эти данные.")),
            ]),
            FormSection(L("Передавать данные устройства провайдеру"),
                        footer: L("Передаются HWID и модель iPhone, версия iOS и язык — только если без них панель не отдаёт серверы. Без этих данных некоторые панели не отдают серверы или считают iPhone новым устройством. «Для новых подписок» — значение по умолчанию на экране добавления. Изменение действует со следующего обновления подписки."),
                        device),
            FormSection(L("Что хранится на iPhone"), [
                .note(L("Подписки, серверы и их ключи — в общей папке приложения и VPN-расширения (App Group), под защитой файлов iOS; в резервные копии iCloud и компьютера они не попадают. HWID — только в Keychain этого устройства. Своих копий конфигурации ядро не делает. Настройки — в UserDefaults. Статистика и результаты пинга — только в памяти.")),
            ]),
            FormSection(L("Журналы"), [
                .note(L("Журнал остаётся на iPhone и сам никуда не уходит. Ядро пишет только предупреждения и ошибки; каждое соединение — лишь в «Подробном отчёте», который сам выключается через 30 минут. При копировании вырезаются ссылки, адреса подписок, пароли, UUID, ключи, HWID, имена ваших серверов, сайты, к которым шли соединения, и IP-адреса.")),
            ]),
            FormSection(L("Блокировка рекламы"), [
                .note(L("Списки встроены в приложение и обновляются только вместе с ним: HaGeZi DNS Blocklists, фильтры AdGuard, SagerNet sing-geosite (GPL-3.0). Проверка идёт на iPhone, запросы никуда не отправляются.")),
            ]),
            FormSection(L("Что видит провайдер VPN-сервера"), [
                .note(L("Ваш IP-адрес, время и объём трафика, адреса и имена сайтов (имя из TLS, нешифрованный трафик целиком) и DNS-запросы. Мимо VPN идут российские сайты и локальная сеть, если они включены, push-уведомления Apple и службы оператора.")),
            ]),
            FormSection(footer: L("Удаляются подписки и серверы, статистика, результаты пинга, журналы, отчёты о падениях, HWID и настройка VPN в iOS. Настройки интерфейса и сети остаются."), [
                .link(symbol: "doc.text", title: L("Полный текст политики")) { UIApplication.shared.open(PrivacyViewController.policyURL) },
                .button(title: L("Удалить все данные"), destructive: true) { [weak self] in self?.confirmErase() },
            ]),
        ]
    }

    private func confirmErase() {
        let alert = UIAlertController(title: L("Удалить все данные?"),
                                      message: L("VPN отключится. Будут удалены все подписки и серверы, статистика, журналы и HWID. Отменить это нельзя: если нужно, сначала сохраните резервную копию."),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("Удалить всё"), style: .destructive) { [weak self] _ in
            let progress = UIAlertController(title: nil, message: L("Удаление…"), preferredStyle: .alert)
            self?.present(progress, animated: true)
            App.shared.eraseAllData {
                progress.dismiss(animated: true)
                Haptics.result(true)
                self?.rebuild()
            }
        })
        present(alert, animated: true)
    }
}

extension App {
    /// «Передавать данные устройства провайдеру» of one subscription.
    static func setSendsDeviceData(_ value: Bool, for id: Int64) {
        App.shared.store.update { library in
            guard var current = library.subscription(id) else { return }
            current.sendsDeviceIdentity = value
            library.replace(current)
        }
    }
}
