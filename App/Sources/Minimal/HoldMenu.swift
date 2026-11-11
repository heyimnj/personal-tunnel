import UIKit

struct HoldMenuItem {
    var title: String
    var symbol: String
    var destructive = false
    var action: () -> Void
}

/// The menu a long press opens at the finger: a glass card with a small tail.
final class HoldMenuView: UIView {
    private let card = UIView()
    private let glass = GlassView(radius: 22)
    private let tail = CAShapeLayer()
    private var anchor = CGPoint.zero
    private var onDismiss: (() -> Void)?

    static func show(in host: UIView, at point: CGPoint, title: String, items: [HoldMenuItem], onDismiss: (() -> Void)? = nil) {
        let menu = HoldMenuView(frame: host.bounds)
        menu.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        menu.onDismiss = onDismiss
        menu.build(title: title, items: items)
        host.addSubview(menu)
        menu.place(at: point)
        Haptics.soft()
    }

    private func build(title: String, items: [HoldMenuItem]) {
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismiss)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dismiss)))
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.16
        card.layer.shadowRadius = 22
        card.layer.shadowOffset = CGSize(width: 0, height: 10)
        addSubview(card)
        card.addSubview(glass)
        glass.pin(to: card)
        glass.contentView.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.72)
        let stack = UIStackView(.vertical, spacing: 0, alignment: .fill, [])
        let heading = UILabel(title, font: Theme.font(13, .semibold))
        heading.lineBreakMode = .byTruncatingTail
        let headingBox = UIView()
        headingBox.addSubview(heading)
        heading.pin(to: headingBox, insets: UIEdgeInsets(top: 14, left: 16, bottom: 8, right: 16))
        stack.addArrangedSubview(headingBox)
        stack.addArrangedSubview(rule())
        for item in items {
            if item.destructive { stack.addArrangedSubview(rule()) }
            let control = TapControl()
            control.pressScale = 1
            let color: UIColor = item.destructive ? .systemRed : .label
            let icon = UIImageView(image: UIImage(systemName: item.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)))
            icon.tintColor = color
            icon.contentMode = .center
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
            let row = UIStackView(.horizontal, spacing: 12, alignment: .center, [icon, UILabel(item.title, font: Theme.font(17), color: color), UIView()])
            row.isUserInteractionEnabled = false
            control.addSubview(row)
            row.pin(to: control, insets: UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16))
            control.heightAnchor.constraint(equalToConstant: 46).isActive = true
            control.onTap = { [weak self] in
                self?.dismiss()
                item.action()
            }
            stack.addArrangedSubview(control)
        }
        stack.addArrangedSubview(UIView.spacer(6))
        glass.contentView.addSubview(stack)
        stack.pin(to: glass.contentView)
        tail.fillColor = UIColor.systemBackground.withAlphaComponent(0.9).cgColor
        card.layer.addSublayer(tail)
    }

    private func rule() -> UIView {
        let box = UIView()
        let line = UIView()
        line.backgroundColor = UIColor.label.withAlphaComponent(0.1)
        box.addSubview(line)
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.heightAnchor.constraint(equalToConstant: 0.5), line.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14), line.topAnchor.constraint(equalTo: box.topAnchor, constant: 4),
            line.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -4),
        ])
        return box
    }

    private func place(at point: CGPoint) {
        let width: CGFloat = 268
        let height = card.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                  withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        let x = min(bounds.width - width - 12, max(12, point.x - width / 2))
        let below = point.y + 16 + height < bounds.height - safeAreaInsets.bottom - 12
        let y = below ? point.y + 16 : max(safeAreaInsets.top + 12, point.y - 16 - height)
        card.frame = CGRect(x: x, y: y, width: width, height: height)
        anchor = CGPoint(x: (point.x - x) / width, y: below ? 0 : 1)
        // The tail points at the finger, left, centre or right.
        let tip = min(width - 34, max(34, point.x - x))
        let path = UIBezierPath()
        if below {
            path.move(to: CGPoint(x: tip - 11, y: 1)); path.addLine(to: CGPoint(x: tip, y: -9)); path.addLine(to: CGPoint(x: tip + 11, y: 1))
        } else {
            path.move(to: CGPoint(x: tip - 11, y: height - 1)); path.addLine(to: CGPoint(x: tip, y: height + 9)); path.addLine(to: CGPoint(x: tip + 11, y: height - 1))
        }
        path.close()
        tail.path = path.cgPath
        card.layer.anchorPoint = anchor
        card.frame = CGRect(x: x, y: y, width: width, height: height)
        card.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        card.alpha = 0
        UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0, options: .allowUserInteraction) {
            self.card.transform = .identity
            self.card.alpha = 1
        }
    }

    @objc private func dismiss() {
        guard isUserInteractionEnabled else { return }
        isUserInteractionEnabled = false
        onDismiss?()
        UIView.animate(withDuration: 0.16, animations: {
            self.card.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            self.card.alpha = 0
        }, completion: { _ in self.removeFromSuperview() })
    }
}
