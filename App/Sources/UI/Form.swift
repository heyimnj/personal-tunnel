import UIKit

enum FormRow {
    case link(symbol: String?, title: String, action: () -> Void)
    case toggle(title: String, get: () -> Bool, set: (Bool) -> Void)
    case picker(title: String, options: [(value: String, title: String)], get: () -> String, set: (String) -> Void)
    case slider(title: String, get: () -> Double, set: (Double) -> Void)
    case note(String)
    case button(title: String, destructive: Bool, action: () -> Void)
    case value(title: String, detail: () -> String)
    case color(title: String, get: () -> UIColor, set: (UIColor) -> Void)
    /// 3.5.24: a page with a small picture of its value beside the title (the background).
    case swatch(title: String, image: () -> UIImage, action: () -> Void)
    /// 3.5.23: a colour whose panel has «Сбросить» for this part (`reset`).
    case paint(title: String, get: () -> UIColor, set: (UIColor) -> Void, reset: () -> Void)
    case check(title: String, selected: () -> Bool, action: () -> Void)
    /// A text field: title on the left, the value typed on the right.
    case field(title: String, placeholder: String, get: () -> String, set: (String) -> Void, keyboard: UIKeyboardType)
    /// A long value (key, UUID, address) typed under its title and wrapping, so it is
    /// seen whole.
    case text(title: String, placeholder: String, get: () -> String, set: (String) -> Void, keyboard: UIKeyboardType)
    /// Any row with a symbol in front of it, in the settings' icon style.
    indirect case symbol(String, FormRow)

    /// The row without its symbol.
    var bare: FormRow {
        if case let .symbol(_, row) = self { return row.bare }
        return self
    }
}

/// The long text of `FormRow.text`: grows with what is typed.
private final class FormTextView: UITextView, UITextViewDelegate {
    var onChange: ((String) -> Void)?
    var onResize: (() -> Void)?
    private let hint = UILabel()
    private var lastHeight: CGFloat = 0

    init(placeholder text: String) {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        hint.text = text
        hint.font = Theme.font(15)
        hint.textColor = .tertiaryLabel
        addSubview(hint)
        hint.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([hint.leadingAnchor.constraint(equalTo: leadingAnchor), hint.topAnchor.constraint(equalTo: topAnchor)])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func showPlaceholder() { hint.isHidden = !text.isEmpty }

    func textViewDidChange(_ textView: UITextView) {
        showPlaceholder()
        // No line breaks in a key: Return ends the editing.
        if text.contains("\n") {
            text = text.replacingOccurrences(of: "\n", with: "")
            resignFirstResponder()
        }
        onChange?(text)
        let height = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
        if abs(height - lastHeight) > 0.5 {
            lastHeight = height
            onResize?()
        }
    }
}

struct FormSection {
    var header: String?
    var rows: [FormRow]
    var footer: String?

    init(_ header: String, footer: String? = nil, _ rows: [FormRow]) {
        self.header = header
        self.rows = rows
        self.footer = footer
    }

    init(footer: String? = nil, _ rows: [FormRow]) {
        header = nil
        self.rows = rows
        self.footer = footer
    }
}

/// Grouped settings list used by the Minimal interface and by shared pages.
class FormViewController: UITableViewController, UIColorPickerViewControllerDelegate {
    var sections: [FormSection] = [] {
        didSet {
            (sections, infos) = Self.foldDescriptions(sections)
            reloadAfterToggle()
        }
    }
    /// 3.5.27 (the owner): a switch whose setting redraws the list (AMOLED, the
    /// app lock) lost its glass press — the list was rebuilt under the finger and the
    /// switch replaced mid-animation. The list now waits for the switch to settle.
    private var toggledAt: Date?
    private var reloadPending = false

    private func reloadAfterToggle() {
        guard isViewLoaded else { return }
        let wait = 0.6 - Date().timeIntervalSince(toggledAt ?? .distantPast)
        guard wait > 0 else { tableView.reloadData(); return }
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.reloadPending = false
            self.tableView.reloadData()
        }
    }
    /// 3.5.23 (the owner): a setting's description is not under it any more — a
    /// tap on the setting (not on its switch or its menu) shows it.
    private var infos: [IndexPath: String] = [:]
    private var colorSetter: ((UIColor) -> Void)?
    var largeTitle = false

    init(title: String) {
        super.init(style: .insetGrouped)
        self.title = title
    }

    /// 3.5.23 (the owner): a switch shows the system's pressed (glass) look on a
    /// plain tap, as in iOS's own Settings — the list no longer holds the touch back
    /// to see whether it starts a scroll; a scroll begun on a switch still scrolls.
    override func loadView() {
        let table = FormTableView(frame: .zero, style: .insetGrouped)
        table.delaysContentTouches = false
        tableView = table
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// Builds the sections; called on load and whenever values may have changed.
    func build() -> [FormSection] { [] }

    func rebuild() { sections = build() }

    /// The notes after a switch or a menu describe it: they go with it (several
    /// join), as does the footer of a section that has one switch or menu. Notes
    /// before any (a page of text) stay where they are.
    static func foldDescriptions(_ sections: [FormSection]) -> ([FormSection], [IndexPath: String]) {
        var infos: [IndexPath: String] = [:]
        var result: [FormSection] = []
        for (sectionIndex, section) in sections.enumerated() {
            var rows: [FormRow] = []
            var owner: Int?
            for row in section.rows {
                switch row.bare {
                case .toggle, .picker:
                    rows.append(row)
                    owner = rows.count - 1
                case let .note(text):
                    if let owner {
                        let path = IndexPath(row: owner, section: sectionIndex)
                        infos[path] = infos[path].map { $0 + "\n\n" + text } ?? text
                    } else {
                        rows.append(row)
                    }
                default:
                    rows.append(row)
                }
            }
            var folded = section
            folded.rows = rows
            let described = rows.indices.filter { index in
                switch rows[index].bare { case .toggle, .picker: return true; default: return false }
            }
            if let footer = section.footer, described.count == 1, !rows.contains(where: { if case .note = $0.bare { return true }; return false }) {
                let path = IndexPath(row: described[0], section: sectionIndex)
                infos[path] = infos[path].map { $0 + "\n\n" + footer } ?? footer
                folded.footer = nil
            }
            result.append(folded)
        }
        return (result, infos)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = largeTitle ? .always : .never
        tableView.backgroundColor = Theme.background
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        view.tintColor = Theme.accent
        rebuild()
        Prefs.appearanceChanged.observe(self) { [weak self] in
            self?.tableView.backgroundColor = Theme.background
            self?.view.tintColor = Theme.accent
            self?.rebuild()
        }
    }

    override func numberOfSections(in _: UITableView) -> Int { sections.count }
    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].header }
    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer }

    static var cellColor: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.11, alpha: 1) : UIColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1) }
    }

    static func icon(_ symbol: String) -> UIImage {
        let size = CGSize(width: 29, height: 29)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let accent = Theme.accent
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 7).addClip()
            let colors = [accent.withAlphaComponent(0.82).cgColor, accent.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]), let context = UIGraphicsGetCurrentContext() {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            let glyph = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))?.withTintColor(.white, renderingMode: .alwaysOriginal)
            if let glyph {
                glyph.draw(in: CGRect(x: (size.width - glyph.size.width) / 2, y: (size.height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height))
            }
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = makeCell(sections[indexPath.section].rows[indexPath.row], symbol: nil)
        if infos[indexPath] != nil, var content = cell.contentConfiguration as? UIListContentConfiguration, let title = content.text {
            content.attributedText = Self.titleWithInfo(title)
            cell.contentConfiguration = content
        }
        return cell
    }

    /// The symbol in front of a hand-built row (fields), as `content.image` is for the rest.
    private static func iconView(_ symbol: String?) -> UIView? {
        guard let symbol else { return nil }
        let view = UIImageView(image: icon(symbol))
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }

    private func makeCell(_ row: FormRow, symbol: String?) -> UITableViewCell {
        if case let .symbol(name, inner) = row { return makeCell(inner, symbol: name) }
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = FormViewController.cellColor
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.textProperties.font = Theme.font(17)
        content.textProperties.color = Theme.text
        if let symbol { content.image = FormViewController.icon(symbol) }
        switch row {
        case .symbol: break
        case let .link(own, title, _):
            content.text = title
            if let own { content.image = FormViewController.icon(own) }
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case let .toggle(title, get, set):
            content.text = title
            let toggle = UISwitch()
            toggle.addTactileToggle()
            toggle.isOn = get()
            toggle.onTintColor = Theme.accent
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                self?.toggledAt = Date()
                set(toggle?.isOn ?? false)
            }, for: .valueChanged)
            cell.accessoryView = toggle
        case let .picker(title, options, get, set):
            content.text = title
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.plain()
            configuration.title = options.first { $0.value == get() }?.title
            configuration.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            configuration.imagePlacement = .trailing
            configuration.imagePadding = 4
            configuration.contentInsets = .zero
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = Theme.font(17)
                return attributes
            }
            button.configuration = configuration
            button.showsMenuAsPrimaryAction = true
            button.menu = UIMenu(children: options.map { option in
                UIAction(title: option.title, state: option.value == get() ? .on : .off) { [weak self] _ in
                    set(option.value)
                    self?.rebuild()
                }
            })
            button.sizeToFit()
            cell.accessoryView = button
        case let .slider(title, get, set):
            let label = UILabel(title, font: Theme.font(15))
            let slider = UISlider()
            slider.minimumValue = 0.05
            slider.maximumValue = 1
            slider.value = Float(get())
            slider.minimumTrackTintColor = Theme.accent
            slider.addAction(UIAction { [weak slider] _ in set(Double(slider?.value ?? 1)) }, for: .touchUpInside)
            let stack = UIStackView(.vertical, spacing: 6, alignment: .fill, [label, slider])
            cell.contentView.addSubview(stack)
            stack.pin(to: cell.contentView, insets: UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20))
            return cell
        case let .note(text):
            content.text = text
            content.textProperties.font = Theme.font(13)
            content.textProperties.color = .secondaryLabel
        case let .button(title, destructive, _):
            content.text = title
            content.textProperties.color = destructive ? .systemRed : Theme.text
            cell.selectionStyle = .default
        case let .value(title, detail):
            content.text = title
            content.secondaryText = detail()
            content.secondaryTextProperties.font = Theme.font(15)
        case let .swatch(title, image, _):
            content.text = title
            // 3.5.28 (the owner): just the circle, as the colour rows show theirs.
            let picture = UIImageView(image: image())
            picture.frame = CGRect(origin: .zero, size: picture.image?.size ?? CGSize(width: 28, height: 28))
            cell.accessoryView = picture
            cell.selectionStyle = .default
        case let .color(title, get, _), let .paint(title, get, _, _):
            content.text = title
            let well = UIView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
            well.backgroundColor = get()
            well.layer.cornerRadius = 14
            well.layer.borderWidth = 3
            well.layer.borderColor = UIColor.systemGray4.cgColor
            cell.accessoryView = well
            cell.selectionStyle = .default
        case let .check(title, selected, _):
            content.text = title
            cell.accessoryType = selected() ? .checkmark : .none
            cell.selectionStyle = .default
        case let .field(title, placeholder, get, set, keyboard):
            let label = UILabel(title, font: Theme.font(17), color: Theme.text)
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            let field = UITextField()
            field.text = get()
            field.placeholder = placeholder
            field.font = Theme.font(17)
            field.textAlignment = .right
            field.textColor = .secondaryLabel
            field.keyboardType = keyboard
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.clearButtonMode = .whileEditing
            field.addAction(UIAction { [weak field] _ in set(field?.text ?? "") }, for: .editingChanged)
            let stack = UIStackView(.horizontal, spacing: 12, alignment: .center, [Self.iconView(symbol), label, field].compactMap { $0 })
            cell.contentView.addSubview(stack)
            stack.pin(to: cell.contentView, insets: UIEdgeInsets(top: 11, left: 20, bottom: 11, right: 16))
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
            return cell
        case let .text(title, placeholder, get, set, keyboard):
            let label = UILabel(title, font: Theme.font(17), color: Theme.text)
            let head = UIStackView(.horizontal, spacing: 12, alignment: .center, [Self.iconView(symbol), label].compactMap { $0 })
            let field = FormTextView(placeholder: placeholder)
            field.text = get()
            field.showPlaceholder()
            field.font = Theme.font(15)
            field.textColor = .secondaryLabel
            field.keyboardType = keyboard
            field.returnKeyType = .done
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.smartDashesType = .no
            field.smartQuotesType = .no
            field.onChange = set
            field.onResize = { [weak self] in
                UIView.performWithoutAnimation { self?.tableView.performBatchUpdates(nil) }
            }
            // The value lines up with the title, past the symbol.
            let value = UIView()
            value.addSubview(field)
            field.pin(to: value, insets: UIEdgeInsets(top: 0, left: symbol == nil ? 0 : 41, bottom: 0, right: 0))
            let stack = UIStackView(.vertical, spacing: 6, alignment: .fill, [head, value])
            cell.contentView.addSubview(stack)
            stack.pin(to: cell.contentView, insets: UIEdgeInsets(top: 11, left: 20, bottom: 11, right: 16))
            return cell
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if infos[indexPath] != nil { cell.selectionStyle = .default }
    }

    /// 3.5.23 (the owner): a small ⓘ after the title of a setting that has a description.
    static func titleWithInfo(_ title: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title + " ", attributes: [.font: Theme.font(17), .foregroundColor: Theme.text])
        if let mark = UIImage(systemName: "info.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular))?
            .withTintColor(.tertiaryLabel, renderingMode: .alwaysOriginal) {
            let attachment = NSTextAttachment(image: mark)
            let font = Theme.font(17)
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - mark.size.height) / 2, width: mark.size.width, height: mark.size.height)
            text.append(NSAttributedString(attachment: attachment))
        }
        return text
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // 3.5.23 (the owner: a row stayed dimmed all the way to the next page): the
        // shade goes the moment the finger lifts, as in iOS's own Settings.
        tableView.deselectRow(at: indexPath, animated: false)
        if let info = infos[indexPath], let cell = tableView.cellForRow(at: indexPath), !InfoBubble.isShown {
            Haptics.tap()
            InfoBubble.show(info, under: cell, in: view.window ?? view)
            return
        }
        // 3.5.13 (the owner): the settings' buttons answer to the touch.
        switch sections[indexPath.section].rows[indexPath.row].bare {
        case let .link(_, _, action), let .button(_, _, action), let .swatch(_, _, action):
            Haptics.tap()
            action()
        case let .check(_, _, action):
            Haptics.tap()
            action()
            rebuild()
        case let .paint(title, get, set, reset):
            Haptics.tap()
            let panel = ColorPanelController(title: title, color: get(), pick: { [weak self] in set($0); self?.rebuild() },
                                             reset: { [weak self] in reset(); self?.rebuild() })
            present(panel, animated: true)
        case let .color(_, get, set):
            Haptics.tap()
            colorSetter = set
            let picker = UIColorPickerViewController()
            picker.selectedColor = get()
            picker.supportsAlpha = false
            picker.delegate = self
            present(picker, animated: true)
        default: break
        }
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        colorSetter?(viewController.selectedColor)
        colorSetter = nil
        rebuild()
    }
}


/// 3.5.23: a setting's description, a card under the setting (above it when
/// there is no room), in the menus' even tone. Any touch closes it.
final class InfoBubble: UIView {
    private static weak var current: InfoBubble?
    static var isShown: Bool { current?.superview != nil }
    private let card = UIView()
    private let label = UILabel()

    static func show(_ text: String, under anchor: UIView, in host: UIView) {
        current?.close()
        let bubble = InfoBubble(frame: host.bounds)
        bubble.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(bubble)
        bubble.overrideUserInterfaceStyle = anchor.traitCollection.userInterfaceStyle
        bubble.build(text)
        let row = anchor.convert(anchor.bounds, to: bubble)
        let safe = host.safeAreaInsets
        let width = min(host.bounds.width - 32, 520)
        let size = bubble.card.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                       withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let below = row.maxY + 6, above = row.minY - 6 - size.height
        let y = below + size.height <= host.bounds.height - safe.bottom - 90 ? below : max(safe.top + 8, above)
        bubble.card.frame = CGRect(x: (host.bounds.width - width) / 2, y: y, width: width, height: size.height)
        let down = y == below
        bubble.card.layer.anchorPoint = CGPoint(x: 0.5, y: down ? 0 : 1)
        bubble.card.frame = CGRect(x: (host.bounds.width - width) / 2, y: y, width: width, height: size.height)
        bubble.card.alpha = 0
        bubble.card.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            bubble.card.alpha = 1
            bubble.card.transform = .identity
        }
        UIAccessibility.post(notification: .announcement, argument: text)
        current = bubble
    }

    private func build(_ text: String) {
        backgroundColor = .clear
        card.backgroundColor = HoldMenuView.fill
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? 0.4 : 0.14
        card.layer.shadowRadius = 18
        card.layer.shadowOffset = CGSize(width: 0, height: 6)
        label.text = text
        label.font = Theme.font(15)
        label.textColor = .label
        label.numberOfLines = 0
        card.addSubview(label)
        label.pin(to: card, insets: UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
        addSubview(card)
        card.isAccessibilityElement = true
        card.accessibilityLabel = text
    }

    /// 3.5.26 (the owner): any touch, anywhere, only closes it — the same row again
    /// closes it rather than opening it once more, another row does not open its
    /// own, and nothing under it is pressed.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard superview != nil, isUserInteractionEnabled else { return nil }
        return self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        close()
    }

    func close() {
        guard superview != nil, isUserInteractionEnabled else { return }
        isUserInteractionEnabled = false
        if Self.current === self { Self.current = nil }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) {
            self.card.alpha = 0
            self.card.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        } completion: { _ in self.removeFromSuperview() }
    }
}


/// The settings' list: a touch that starts on a control still scrolls the list.
final class FormTableView: UITableView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UISwitch || view is UIButton ? true : super.touchesShouldCancel(in: view)
    }
}

/// 3.5.23 (the owner): the system's colour panel with «Сбросить» for the part it
/// was opened for, under the colours.
final class ColorPanelController: UIViewController, UIColorPickerViewControllerDelegate {
    private let picker = UIColorPickerViewController()
    private let pick: (UIColor) -> Void
    private let reset: () -> Void
    /// What it opened with: closing it unchanged changes nothing (no ✓ to save).
    private var initial = ""

    init(title: String, color: UIColor, pick: @escaping (UIColor) -> Void, reset: @escaping () -> Void) {
        self.pick = pick
        self.reset = reset
        super.init(nibName: nil, bundle: nil)
        picker.title = title
        picker.selectedColor = color
        initial = color.hexString
        picker.supportsAlpha = false
        picker.delegate = self
        modalPresentationStyle = .pageSheet
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        addChild(picker)
        view.addSubview(picker.view)
        picker.didMove(toParent: self)
        var config = UIButton.Configuration.gray()
        config.title = L("Сбросить")
        config.image = UIImage(systemName: "arrow.uturn.backward")
        config.imagePadding = 8
        config.cornerStyle = .capsule
        config.buttonSize = .large
        config.baseForegroundColor = .label
        let resetButton = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            Haptics.tap()
            self?.reset()
            self?.dismiss(animated: true)
        })
        resetButton.accessibilityHint = L("Вернуть исходный цвет")
        for item in [picker.view!, resetButton] as [UIView] { item.translatesAutoresizingMaskIntoConstraints = false }
        view.addSubview(resetButton)
        NSLayoutConstraint.activate([
            picker.view.topAnchor.constraint(equalTo: view.topAnchor),
            picker.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            picker.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            picker.view.bottomAnchor.constraint(equalTo: resetButton.topAnchor, constant: -12),
            resetButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            resetButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            resetButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
    }

    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        guard !continuously, color.hexString != initial else { return }
        pick(color)
    }

    func colorPickerViewControllerDidFinish(_: UIColorPickerViewController) {
        if picker.selectedColor.hexString != initial { pick(picker.selectedColor) }
        dismiss(animated: true)
    }
}
