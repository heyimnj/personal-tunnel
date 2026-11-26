import UIKit

/// The lab's one screen: the Minimal Home with a pretend tunnel, and on top the
/// switches for what is being compared. A swipe left or right moves to the next
/// variant; «¼×» runs everything four times slower.
final class LabHomeViewController: UIViewController {
    private let tunnel = MockTunnel()
    private var style: GlyphStyle = ConnectGlyphs.style(LabSettings.variant)
    private var memo = GlyphMemo()
    private var start = GlyphMemo()

    private let variantButton = UIButton(type: .system)
    private let themeButton = UIButton(type: .system)
    private let slowButton = UIButton(type: .system)
    private let note = UILabel()
    private let button = LabPowerButton()
    private let canvas = GlyphCanvas()
    private let status = UILabel()
    private let capsule = LabCapsule()
    private let hint = UILabel()

    private var link: CADisplayLink?
    private var clock: Double = 0
    private var lastTick: CFTimeInterval = 0
    private var speed: Double = 1

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        variantButton.showsMenuAsPrimaryAction = true
        variantButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        variantButton.contentHorizontalAlignment = .leading
        themeButton.addAction(UIAction { [weak self] _ in self?.nextTheme() }, for: .touchUpInside)
        slowButton.addAction(UIAction { [weak self] _ in self?.toggleSlow() }, for: .touchUpInside)
        for item in [themeButton, slowButton] {
            item.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        }
        note.font = .systemFont(ofSize: 13)
        note.textColor = .secondaryLabel
        note.numberOfLines = 0

        status.font = .preferredFont(forTextStyle: .headline)
        status.textColor = .secondaryLabel
        status.textAlignment = .center

        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabel
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.text = "PT Lab — только для сравнения вариантов, без VPN.\nСвайп влево/вправо — следующий вариант."

        button.addSubview(canvas)
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.tunnel.tap(at: self.clock)
        }, for: .touchUpInside)

        for item in [variantButton, themeButton, slowButton, note, button, status, capsule, hint] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        canvas.translatesAutoresizingMaskIntoConstraints = false
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            variantButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            variantButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            variantButton.trailingAnchor.constraint(lessThanOrEqualTo: themeButton.leadingAnchor, constant: -12),
            slowButton.centerYAnchor.constraint(equalTo: variantButton.centerYAnchor),
            slowButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            themeButton.centerYAnchor.constraint(equalTo: variantButton.centerYAnchor),
            themeButton.trailingAnchor.constraint(equalTo: slowButton.leadingAnchor, constant: -16),
            note.topAnchor.constraint(equalTo: variantButton.bottomAnchor, constant: 4),
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            note.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: guide.centerYAnchor, constant: -60),
            button.widthAnchor.constraint(equalToConstant: 140),
            button.heightAnchor.constraint(equalToConstant: 140),
            canvas.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            canvas.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            // 100 box units: the ring's radius 22 is the app's 18.5 pt.
            canvas.widthAnchor.constraint(equalToConstant: 84),
            canvas.heightAnchor.constraint(equalToConstant: 84),
            status.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 20),
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            capsule.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 64),
            capsule.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            capsule.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            capsule.heightAnchor.constraint(equalToConstant: 58),
            hint.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            view.addGestureRecognizer(swipe)
        }

        tunnel.onChange = { [weak self] phase in self?.phaseChanged(phase) }
        phaseChanged(.off)
        showVariant()
        showTheme()
        showSlow()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard link == nil else { return }
        let link = CADisplayLink(target: LabTicker(self), selector: #selector(LabTicker.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = CACurrentMediaTime()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        link?.invalidate()
        link = nil
    }

    fileprivate func tick() {
        let now = CACurrentMediaTime()
        clock += min(now - lastTick, 0.05) * speed
        lastTick = now
        tunnel.tick(at: clock)
        let elapsed = clock - tunnel.started
        let frame = style.frame(tunnel.phase, elapsed, start: start, memo: &memo, traits: traitCollection)
        canvas.render(frame)
    }

    private func phaseChanged(_ phase: MockTunnel.Phase) {
        start = memo
        switch phase {
        case .off: status.text = "Не подключено"
        case .connecting: status.text = "Подключение…"
        case .on: status.text = "Подключено"
        case .disconnecting: status.text = "Отключение…"
        }
        capsule.delay = phase == .on ? "237 ms" : nil
    }

    // MARK: Switches

    private func showVariant() {
        var title = AttributedString(style.title + "  ▾")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        var config = UIButton.Configuration.plain()
        config.attributedTitle = title
        config.contentInsets = .zero
        variantButton.configuration = config
        note.text = style.note
        let actions = ConnectGlyphs.all.map { item in
            UIAction(title: item.title, subtitle: item.note, state: item.id == style.id ? .on : .off) { [weak self] _ in self?.choose(item) }
        }
        variantButton.menu = UIMenu(title: "Иконка кнопки подключения", children: actions)
    }

    private func choose(_ next: GlyphStyle) {
        style = next
        LabSettings.variant = next.id
        memo = GlyphMemo()
        start = GlyphMemo()
        tunnel.reset(at: clock)
        showVariant()
    }

    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        let all = ConnectGlyphs.all
        guard let index = all.firstIndex(where: { $0.id == style.id }) else { return }
        let step = gesture.direction == .left ? 1 : -1
        choose(all[(index + step + all.count) % all.count])
    }

    private func nextTheme() {
        let all = LabSettings.Theme.allCases
        let next = all[(LabSettings.theme.rawValue + 1) % all.count]
        LabSettings.theme = next
        view.window?.overrideUserInterfaceStyle = next.style
        showTheme()
    }

    private func showTheme() {
        themeButton.setTitle(LabSettings.theme.title, for: .normal)
    }

    private func toggleSlow() {
        speed = speed == 1 ? 0.25 : 1
        showSlow()
    }

    private func showSlow() {
        slowButton.setTitle(speed == 1 ? "1×" : "¼×", for: .normal)
    }
}

/// Holds the controller weakly for the display link (which retains its target).
private final class LabTicker: NSObject {
    weak var owner: LabHomeViewController?
    init(_ owner: LabHomeViewController) { self.owner = owner }

    @objc func tick(_ link: CADisplayLink) {
        guard let owner else { link.invalidate(); return }
        owner.tick()
    }
}

/// The big round button as in 3.6: raised, lighter at the top, a fine edge and a
/// soft shadow; it sinks a little under the finger.
final class LabPowerButton: UIControl {
    private let face = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.shadowOffset = CGSize(width: 0, height: 10)
        layer.shadowRadius = 18
        face.borderWidth = 1 / UIScreen.main.scale
        layer.addSublayer(face)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        face.frame = bounds
        face.cornerRadius = bounds.width / 2
        layer.shadowPath = UIBezierPath(ovalIn: bounds).cgPath
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        restyle()
    }

    private func restyle() {
        let dark = traitCollection.userInterfaceStyle == .dark
        face.colors = dark
            ? [UIColor(white: 0.17, alpha: 1).cgColor, UIColor(white: 0.115, alpha: 1).cgColor]
            : [UIColor.white.cgColor, UIColor(white: 0.945, alpha: 1).cgColor]
        face.borderColor = dark ? UIColor(white: 1, alpha: 0.09).cgColor : UIColor(white: 0, alpha: 0.12).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = dark ? 0.6 : 0.12
    }

    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted else { return }
            let pressed = isHighlighted
            UIView.animate(withDuration: pressed ? 0.18 : 0.6, delay: 0, usingSpringWithDamping: pressed ? 1 : 0.5, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transform = pressed ? CGAffineTransform(scaleX: 0.985, y: 0.985) : .identity
            }
        }
    }
}

/// The server capsule: flag, name, delay when connected, a chevron up.
final class LabCapsule: UIView {
    private let face = CAGradientLayer()
    private let flag = UILabel()
    private let name = UILabel()
    private let delayLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))

    var delay: String? {
        didSet { delayLabel.text = delay }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        face.borderWidth = 1 / UIScreen.main.scale
        layer.addSublayer(face)
        flag.text = "🇺🇸"
        flag.font = .systemFont(ofSize: 21)
        name.text = "USA"
        name.font = .systemFont(ofSize: 17, weight: .medium)
        delayLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        delayLabel.textColor = .secondaryLabel
        chevron.tintColor = .tertiaryLabel
        let row = UIStackView(arrangedSubviews: [flag, name, UIView(), delayLabel, chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        face.frame = bounds
        face.cornerRadius = bounds.height / 2
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        restyle()
    }

    private func restyle() {
        let dark = traitCollection.userInterfaceStyle == .dark
        face.colors = dark
            ? [UIColor(white: 0.16, alpha: 1).cgColor, UIColor(white: 0.12, alpha: 1).cgColor]
            : [UIColor.white.cgColor, UIColor(white: 0.955, alpha: 1).cgColor]
        face.borderColor = dark ? UIColor(white: 1, alpha: 0.09).cgColor : UIColor(white: 0, alpha: 0.12).cgColor
    }
}
