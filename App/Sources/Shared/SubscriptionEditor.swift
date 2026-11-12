import TunnelCore
import UIKit

/// «Редактировать» on a subscription: its name and the order of its servers.
/// Nothing changes until the check mark: then the name is saved and a moved order
/// becomes the manual order the server list shows (pinned servers stay on top).
final class SubscriptionEditorViewController: UITableViewController {
    private let subscriptionID: Int64
    private var name: String
    private var nodes: [ServerNode]
    private let originalKeys: [String]
    private var moved = false
    private let labels: [String: ServerLabels.Label]
    /// The list redraws in the new order.
    var onSaved: (() -> Void)?

    static func wrapped(_ subscription: Subscription, onSaved: (() -> Void)? = nil) -> UINavigationController {
        let editor = SubscriptionEditorViewController(subscription)
        editor.onSaved = onSaved
        let navigation = UINavigationController(rootViewController: editor)
        navigation.overrideUserInterfaceStyle = Theme.userInterfaceStyle
        return navigation
    }

    init(_ subscription: Subscription) {
        subscriptionID = subscription.id
        name = subscription.name
        let labels = App.shared.store.labels(for: subscription)
        self.labels = labels
        nodes = Prefs.arrangement.sorted(subscription.nodes, key: { Arrangement.server(subscription.id, $0.id) }, name: { labels[$0.id]?.text ?? $0.name })
        originalKeys = nodes.map { Arrangement.server(subscription.id, $0.id) }
        super.init(style: .insetGrouped)
        title = L("Редактировать")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = Theme.background
        view.tintColor = Theme.accent
        tableView.keyboardDismissMode = .interactive
        // Reorder handles only on the servers (rows of section 2).
        tableView.isEditing = true
        tableView.allowsSelectionDuringEditing = true
        let close = UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        close.accessibilityLabel = L("Отмена")
        close.tintColor = .label
        let save = UIBarButtonItem(image: UIImage(systemName: "checkmark"), primaryAction: UIAction { [weak self] _ in self?.save() })
        save.accessibilityLabel = L("Сохранить")
        if #available(iOS 26.0, *) {
            save.style = .prominent
            save.tintColor = Theme.accent
        }
        navigationItem.leftBarButtonItem = close
        navigationItem.rightBarButtonItem = save
    }

    private func save() {
        view.endEditing(true)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Haptics.result(false)
            App.shared.notice.value = L("Название не может быть пустым.")
            return
        }
        if trimmed != App.shared.library.subscription(subscriptionID)?.name {
            App.shared.rename(subscription: subscriptionID, to: trimmed)
        }
        if moved {
            var next = Prefs.arrangement
            next.setManualOrder(nodes.map { Arrangement.server(subscriptionID, $0.id) }, replacing: originalKeys)
            Prefs.arrangement = next
            // The order just set is what the list should show.
            Prefs.sortByLatency = false
        }
        onSaved?()
        Haptics.result(true)
        dismiss(animated: true)
    }

    // MARK: Sorting shortcuts

    private func sortByName() {
        nodes.sort { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
        reordered()
    }

    private func sortByLatency() {
        let latency = App.shared.latency
        nodes = nodes.enumerated().sorted { left, right in
            let l = latency.entry(subscriptionID, left.element.id)?.result.milliseconds ?? Int.max
            let r = latency.entry(subscriptionID, right.element.id)?.result.milliseconds ?? Int.max
            return l != r ? l < r : left.offset < right.offset
        }.map(\.element)
        reordered()
    }

    private func reordered() {
        moved = true
        Haptics.selection()
        tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
    }

    private func title(_ node: ServerNode) -> String { labels[node.id]?.text ?? node.name }

    // MARK: Table

    override func numberOfSections(in _: UITableView) -> Int { 3 }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 1
        case 1: return 2
        default: return nodes.count
        }
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 1: return L("Порядок серверов")
        case 2: return Lf("Серверы: %@", "\(nodes.count)")
        default: return nil
        }
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 2 ? L("Перетащите сервер за полоски справа. Закреплённые серверы остаются сверху. Новый порядок включает ручную сортировку.") : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = FormViewController.cellColor
        cell.selectionStyle = .none
        switch indexPath.section {
        case 0:
            let icon = UIImageView(image: FormViewController.icon("tag"))
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let label = UILabel(L("Название"), font: Theme.font(17), color: Theme.text)
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            let field = UITextField()
            field.text = name
            field.font = Theme.font(17)
            field.textAlignment = .right
            field.textColor = .secondaryLabel
            field.clearButtonMode = .whileEditing
            field.returnKeyType = .done
            field.addAction(UIAction { [weak self, weak field] _ in self?.name = field?.text ?? "" }, for: .editingChanged)
            field.addAction(UIAction { [weak field] _ in field?.resignFirstResponder() }, for: .editingDidEndOnExit)
            let stack = UIStackView(.horizontal, spacing: 12, alignment: .center, [icon, label, field])
            cell.contentView.addSubview(stack)
            stack.pin(to: cell.contentView, insets: UIEdgeInsets(top: 11, left: 20, bottom: 11, right: 16))
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        case 1:
            var content = cell.defaultContentConfiguration()
            content.text = indexPath.row == 0 ? L("Упорядочить по имени") : L("Упорядочить по задержке")
            content.image = FormViewController.icon(indexPath.row == 0 ? "textformat.abc" : "speedometer")
            content.textProperties.font = Theme.font(17)
            content.textProperties.color = Theme.accent
            cell.contentConfiguration = content
            cell.selectionStyle = .default
        default:
            let node = nodes[indexPath.row]
            var content = cell.defaultContentConfiguration()
            let flag = Theme.flag(labels[node.id]?.countryCode)
            content.text = [flag, title(node)].compactMap { $0 }.joined(separator: " ")
            content.textProperties.font = Theme.font(17)
            content.textProperties.color = Theme.text
            content.textProperties.numberOfLines = 1
            var detail = node.facts.badges.joined(separator: " · ")
            if let ms = App.shared.latency.entry(subscriptionID, node.id)?.result.milliseconds { detail += (detail.isEmpty ? "" : " · ") + "\(ms) ms" }
            content.secondaryText = detail.isEmpty ? nil : detail
            content.secondaryTextProperties.font = Theme.font(12)
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            if Prefs.arrangement.isPinned(Arrangement.server(subscriptionID, node.id)) {
                let pin = UIImageView(image: UIImage(systemName: "pin.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
                pin.tintColor = Theme.accent
                cell.editingAccessoryView = pin
            }
            cell.showsReorderControl = true
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        if indexPath.row == 0 { sortByName() } else { sortByLatency() }
    }

    override func tableView(_: UITableView, editingStyleForRowAt _: IndexPath) -> UITableViewCell.EditingStyle { .none }
    override func tableView(_: UITableView, shouldIndentWhileEditingRowAt _: IndexPath) -> Bool { false }
    override func tableView(_: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { indexPath.section == 2 }

    override func tableView(_: UITableView, targetIndexPathForMoveFromRowAt source: IndexPath, toProposedIndexPath proposed: IndexPath) -> IndexPath {
        guard proposed.section == 2 else { return IndexPath(row: 0, section: 2) }
        return proposed
    }

    override func tableView(_: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        let node = nodes.remove(at: source.row)
        nodes.insert(node, at: destination.row)
        moved = true
        Haptics.selection()
    }
}
