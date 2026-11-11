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
    case check(title: String, selected: () -> Bool, action: () -> Void)
}

struct FormSection {
    var header: String?
    var rows: [FormRow]
    var footer: String?

    init(_ header: String? = nil, footer: String? = nil, _ rows: [FormRow]) {
        self.header = header
        self.rows = rows
        self.footer = footer
    }
}

/// Grouped settings list used by the Minimal interface and by shared pages.
class FormViewController: UITableViewController, UIColorPickerViewControllerDelegate {
    var sections: [FormSection] = [] { didSet { if isViewLoaded { tableView.reloadData() } } }
    private var colorSetter: ((UIColor) -> Void)?
    var largeTitle = false

    init(title: String) {
        super.init(style: .insetGrouped)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// Builds the sections; called on load and whenever values may have changed.
    func build() -> [FormSection] { [] }

    func rebuild() { sections = build() }

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
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = FormViewController.cellColor
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.textProperties.font = Theme.font(17)
        content.textProperties.color = Theme.text
        switch sections[indexPath.section].rows[indexPath.row] {
        case let .link(symbol, title, _):
            content.text = title
            if let symbol { content.image = FormViewController.icon(symbol) }
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case let .toggle(title, get, set):
            content.text = title
            let toggle = UISwitch()
            toggle.isOn = get()
            toggle.onTintColor = Theme.accent
            toggle.addAction(UIAction { [weak toggle] _ in set(toggle?.isOn ?? false) }, for: .valueChanged)
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
        case let .color(title, get, _):
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
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case let .link(_, _, action), let .button(_, _, action):
            action()
        case let .check(_, _, action):
            action()
            rebuild()
        case let .color(_, get, set):
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
