import UIKit

/// Hosts the interface of the chosen style and swaps it when the style changes.
final class RootViewController: UIViewController {
    private var current: UIViewController?
    private var shownStyle: InterfaceStyle?
    private var shownLanguage: String?
    private var shownFont: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        apply()
        Prefs.appearanceChanged.observe(self) { [weak self] in self?.apply() }
        App.shared.notice.observe(self) { [weak self] message in
            guard let self, let message else { return }
            App.shared.notice.value = nil
            self.show(message)
        }
        // 3.3 (PT-08): the VPN did not start even on its second try.
        App.shared.tunnel.unprotected.observe(self) { [weak self] reason in
            guard let self, let reason else { return }
            App.shared.tunnel.unprotected.value = nil
            let alert = UIAlertController(title: L("VPN не запущен, трафик не защищён"), message: reason, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("Повторить"), style: .default) { _ in App.shared.connect() })
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            var top: UIViewController = self
            while let presented = top.presentedViewController { top = presented }
            top.present(alert, animated: true)
        }
        // 3.2.2: the connected server changed in a subscription update.
        App.shared.serverUpdateOffered.observe(self) { [weak self] offered in
            guard let self else { return }
            if offered { self.showServerUpdate() } else { self.serverUpdate?.dismiss(); self.serverUpdate = nil }
        }
        App.shared.tunnel.crash.observe(self) { [weak self] crash in
            guard let self, let crash else { return }
            App.shared.tunnel.crash.value = nil
            var top: UIViewController = self
            while let presented = top.presentedViewController { top = presented }
            top.present(CrashReportViewController.wrapped(crash), animated: true)
        }
    }

    private func apply() {
        view.window?.overrideUserInterfaceStyle = Theme.userInterfaceStyle
        overrideUserInterfaceStyle = Theme.userInterfaceStyle
        view.backgroundColor = Theme.background
        view.tintColor = Theme.accent
        // A new style or language builds the interface again.
        // 3.5.18: an imported font too — labels take their font when made, and
        // the navigation bars' titles take it from here.
        let font = Prefs.fontFile ?? ""
        let titles: [NSAttributedString.Key: Any]? = font.isEmpty ? nil : [.font: Theme.fixed(17, .semibold)]
        UINavigationBar.appearance().titleTextAttributes = titles
        guard shownStyle != Prefs.style || shownLanguage != Language.code || shownFont != font else { return }
        shownStyle = Prefs.style
        shownLanguage = Language.code
        shownFont = font
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

    private var serverUpdate: ServerUpdateBanner?

    private func showServerUpdate() {
        guard serverUpdate == nil else { return }
        // On the window: over a sheet that is open, too.
        let container: UIView = view.window ?? view
        let banner = ServerUpdateBanner()
        banner.onReconnect = { App.shared.applyServerUpdate() }
        banner.onLater = { App.shared.declineServerUpdate() }
        serverUpdate = banner
        banner.show(in: container)
    }

    /// 3.5.20 (the owner): a notice drops in at the top and goes by itself, as
    /// iOS's own banners do (it was an alert to dismiss). Over any sheet: it lies in
    /// the window. A tap or a flick up sends it away at once.
    private func show(_ message: String) {
        guard let window = view.window else { return }
        NoticeBanner.show(message, in: window)
    }
}

final class NoticeBanner: UIView {
    private static weak var current: NoticeBanner?
    private let label = UILabel()
    private var hideWork: DispatchWorkItem?

    static func show(_ message: String, in window: UIWindow) {
        current?.hide(animated: false)
        let banner = NoticeBanner(message: message, style: window.traitCollection.userInterfaceStyle)
        window.addSubview(banner)
        banner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 6),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: window.leadingAnchor, constant: 16),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: window.trailingAnchor, constant: -16),
            banner.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            banner.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        current = banner
        window.layoutIfNeeded()
        banner.transform = CGAffineTransform(translationX: 0, y: -(banner.frame.maxY + 12))
        banner.alpha = 0
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            banner.transform = .identity
            banner.alpha = 1
        }
        UIAccessibility.post(notification: .announcement, argument: message)
        // Long enough to read: 2.5 s and a little per word, at most 7 s.
        let seconds = min(7, 2.5 + Double(message.count) * 0.04)
        let work = DispatchWorkItem { [weak banner] in banner?.hide(animated: true) }
        banner.hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private init(message: String, style: UIUserInterfaceStyle) {
        super.init(frame: .zero)
        overrideUserInterfaceStyle = style
        backgroundColor = HoldMenuView.fill
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.label.withAlphaComponent(0.06).resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = style == .dark ? 0.4 : 0.14
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: 6)
        label.text = message
        label.font = Theme.font(.subheadline, .medium)
        label.textColor = .label
        label.numberOfLines = 0
        label.textAlignment = .center
        addSubview(label)
        label.pin(to: self, insets: UIEdgeInsets(top: 12, left: 18, bottom: 12, right: 18))
        isAccessibilityElement = true
        accessibilityLabel = message
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismissTapped)))
        let flick = UISwipeGestureRecognizer(target: self, action: #selector(dismissTapped))
        flick.direction = .up
        addGestureRecognizer(flick)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    @objc private func dismissTapped() { hide(animated: true) }

    private func hide(animated: Bool) {
        hideWork?.cancel()
        guard animated else { removeFromSuperview(); return }
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            self.transform = CGAffineTransform(translationX: 0, y: -(self.frame.maxY + 12))
            self.alpha = 0
        } completion: { _ in self.removeFromSuperview() }
    }
}
