import TunnelCore
import UIKit

/// 3.2.11: «Мои сети» — the Wi-Fi networks where the VPN does not start by itself
/// (automatic start on unknown Wi-Fi). Shared by both styles.
final class TrustedNetworksViewController: FormViewController {
    /// The network the device is on, when the app may read its name.
    private var current: String?
    private var currentChecked = false

    init() { super.init(title: L("Мои сети")) }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        CurrentWiFi.fetch { [weak self] ssid, _ in
            self?.current = ssid
            self?.currentChecked = true
            self?.rebuild()
        }
    }

    override func build() -> [FormSection] {
        let list = Prefs.trustedNetworks
        var top: [FormRow] = []
        if let current, !list.contains(current) {
            top.append(.button(title: Lf("Добавить текущую сеть «%@»", current), destructive: false) { [weak self] in self?.add(current) })
        } else if let current {
            top.append(.value(title: Lf("Текущая сеть «%@»", current), detail: { L("в списке") }))
        }
        top.append(.button(title: L("Добавить сеть по названию"), destructive: false) { [weak self] in self?.askName() })
        let hint = currentChecked && current == nil
            ? L("Название текущей сети недоступно: нет подключения к Wi-Fi или у приложения нет доступа к информации о Wi-Fi (это задаётся при подписи). Сеть можно добавить по названию, как оно написано в настройках Wi-Fi.")
            : nil
        var sections = [FormSection(footer: hint, top)]
        sections.append(FormSection(L("Сети"), footer: L("В этих сетях VPN сам не включается. В любой другой сети Wi-Fi он включится сам, если включено «Автоподключение в неизвестных Wi-Fi». Нажмите на сеть, чтобы убрать её."),
                                    list.isEmpty ? [.value(title: L("Пока нет сетей"), detail: { "" })] : list.map { name in
                                        .button(title: name, destructive: false) { [weak self] in self?.confirmRemove(name) }
                                    }))
        return sections
    }

    private func add(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Prefs.trustedNetworks = Prefs.trustedNetworks + [name]
        if Prefs.pausedNetwork == name { Prefs.pausedNetwork = nil }
        changed()
    }

    private func askName() {
        let alert = UIAlertController(title: L("Название сети"), message: L("Как в настройках Wi-Fi, с учётом регистра."), preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Home Wi-Fi"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: L("Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("Добавить"), style: .default) { [weak self, weak alert] _ in
            self?.add(alert?.textFields?.first?.text ?? "")
        })
        present(alert, animated: true)
    }

    private func confirmRemove(_ name: String) {
        let alert = UIAlertController(title: nil, message: Lf("Убрать «%@» из моих сетей?", name), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("Убрать"), style: .destructive) { [weak self] _ in
            Prefs.trustedNetworks = Prefs.trustedNetworks.filter { $0 != name }
            self?.changed()
        })
        present(alert, animated: true)
    }

    private func changed() {
        App.shared.tunnel.applySettings()
        rebuild()
    }
}
