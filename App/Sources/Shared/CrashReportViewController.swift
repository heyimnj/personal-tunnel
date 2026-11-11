import TunnelCore
import UIKit

/// The tunnel ended without being stopped: the cause and the extension's last
/// lines, to read and to share. Both interface styles show the same page.
final class CrashReportViewController: UIViewController {
    private let crash: TunnelCrash

    static func wrapped(_ crash: TunnelCrash) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: CrashReportViewController(crash))
        navigation.overrideUserInterfaceStyle = Theme.userInterfaceStyle
        return navigation
    }

    init(_ crash: TunnelCrash) {
        self.crash = crash
        super.init(nibName: nil, bundle: nil)
        title = L("Туннель завершился аварийно")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// Everything that leaves the app goes through the redactor.
    private var shareText: String {
        Redactor.redact("Personal Tunnel \(AboutViewController.version)\n\n\(crash.cause)\n\n\(crash.details)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("Поделиться журналом"), primaryAction: UIAction { [weak self] _ in self?.share() })

        let cause = UILabel(crash.cause, font: Theme.font(.headline), color: .label, lines: 0)
        let text = UITextView()
        text.isEditable = false
        text.backgroundColor = .clear
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .secondaryLabel
        text.text = crash.details
        text.textContainerInset = .zero
        text.textContainer.lineFragmentPadding = 0

        let stack = UIStackView(arrangedSubviews: [cause, text])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ])
    }

    private func share() {
        let controller = UIActivityViewController(activityItems: [shareText], applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(controller, animated: true)
    }
}
