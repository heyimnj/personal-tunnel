import UIKit

/// Hosts the interface of the chosen style and swaps it when the style changes.
final class RootViewController: UIViewController {
    private var current: UIViewController?
    private var shownStyle: InterfaceStyle?

    override func viewDidLoad() {
        super.viewDidLoad()
        apply()
        Prefs.appearanceChanged.observe(self) { [weak self] in self?.apply() }
        App.shared.notice.observe(self) { [weak self] message in
            guard let self, let message else { return }
            App.shared.notice.value = nil
            self.show(message)
        }
    }

    private func apply() {
        view.window?.overrideUserInterfaceStyle = Theme.userInterfaceStyle
        overrideUserInterfaceStyle = Theme.userInterfaceStyle
        view.backgroundColor = Theme.background
        view.tintColor = Theme.accent
        guard shownStyle != Prefs.style else { return }
        shownStyle = Prefs.style
        let next: UIViewController = Prefs.style == .classic ? ClassicRootViewController() : MinimalRootViewController()
        let previous = current
        addChild(next)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(next.view)
        next.didMove(toParent: self)
        current = next
        guard let previous else { return }
        previous.willMove(toParent: nil)
        next.view.alpha = 0
        UIView.animate(withDuration: 0.25, animations: { next.view.alpha = 1 }, completion: { _ in
            previous.view.removeFromSuperview()
            previous.removeFromParent()
        })
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.window?.overrideUserInterfaceStyle = Theme.userInterfaceStyle
    }

    override var childForStatusBarStyle: UIViewController? { current }

    private func show(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        var top: UIViewController = self
        while let presented = top.presentedViewController { top = presented }
        top.present(alert, animated: true)
    }
}
