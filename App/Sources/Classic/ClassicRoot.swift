import UIKit

/// «Классика». The screens are being built; until then the style opens the
/// shared settings so the switch back is always reachable.
final class ClassicRootViewController: UINavigationController {
    init() {
        super.init(rootViewController: ClassicPendingViewController())
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }
}

final class ClassicPendingViewController: FormViewController {
    init() { super.init(title: "Классика") }

    override func build() -> [FormSection] {
        [FormSection(footer: "Экраны «Классики» появятся в следующей сборке. Подключение и серверы доступны в «Минималистичном».", [
            .check(title: "Классика", selected: { true }, action: {}),
            .check(title: "Минималистичный", selected: { false }, action: { Prefs.style = .minimal }),
        ])]
    }
}
