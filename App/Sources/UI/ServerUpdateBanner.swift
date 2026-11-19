import UIKit

/// 3.2.2: «Конфиг сервера обновлён — переподключиться?» at the top of the screen,
/// over both styles and over open sheets. The running tunnel is not restarted until
/// the owner taps «Переподключиться»; «Позже» (or a swipe up, or 20 seconds
/// without an answer) leaves it running, and the next connection takes the update.
final class ServerUpdateBanner: UIView {
    var onReconnect: (() -> Void)?
    var onLater: (() -> Void)?

    private let glass = GlassView(radius: 18)
    private var hideTimer: Timer?
    private var shown = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 4)
        addSubview(glass)
        glass.pin(to: self)

        let icon = UIImageView(image: UIImage(systemName: "arrow.triangle.2.circlepath"))
        icon.tintColor = Theme.accent
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let title = UILabel(L("Конфиг сервера обновлён — переподключиться?"), font: Theme.font(15, .semibold), lines: 0)
        let detail = UILabel(L("Соединение прервётся на пару секунд. Без переподключения обновление применится при следующем подключении."),
                             font: Theme.font(13), color: Theme.secondaryText, lines: 0)
        let later = button(L("Позже"), filled: false) { [weak self] in self?.finish(reconnect: false) }
        let reconnect = button(L("Переподключиться"), filled: true) { [weak self] in self?.finish(reconnect: true) }
        let buttons = UIStackView(.horizontal, spacing: 10, [UIView(), later, reconnect])
        let text = UIStackView(.vertical, spacing: 3, [title, detail])
        let top = UIStackView(.horizontal, spacing: 12, alignment: .top, [icon, text])
        let stack = UIStackView(.vertical, spacing: 12, [top, buttons])
        glass.contentView.addSubview(stack)
        stack.pin(to: glass.contentView, insets: UIEdgeInsets(top: 14, left: 16, bottom: 12, right: 14))

        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedUp))
        swipe.direction = .up
        addGestureRecognizer(swipe)
        isAccessibilityElement = false
        accessibilityViewIsModal = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func button(_ title: String, filled: Bool, _ action: @escaping () -> Void) -> UIButton {
        var configuration = filled ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        configuration.title = title
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = filled ? Theme.accent : nil
        configuration.baseForegroundColor = filled ? .white : Theme.text
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.font(14, .semibold)
            return attributes
        }
        return UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    }

    /// Slides in under the status bar of `container`.
    func show(in container: UIView) {
        guard !shown else { return }
        shown = true
        translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(self)
        let guide = container.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 12),
            trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -12),
            centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        let fill = widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -24)
        fill.priority = .defaultHigh
        fill.isActive = true
        container.layoutIfNeeded()
        transform = CGAffineTransform(translationX: 0, y: -(frame.maxY + 20))
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.4) {
            self.transform = .identity
        }
        UIAccessibility.post(notification: .announcement, argument: L("Конфиг сервера обновлён — переподключиться?"))
        hideTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in self?.finish(reconnect: false) }
    }

    /// Slides out without an answer (the offer was withdrawn).
    func dismiss() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard shown else { return }
        shown = false
        UIView.animate(withDuration: 0.25, animations: {
            self.transform = CGAffineTransform(translationX: 0, y: -(self.frame.maxY + 20))
        }, completion: { _ in self.removeFromSuperview() })
    }

    @objc private func swipedUp() { finish(reconnect: false) }

    private func finish(reconnect: Bool) {
        guard shown else { return }
        dismiss()
        if reconnect { onReconnect?() } else { onLater?() }
    }
}
