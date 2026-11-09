import UIKit

/// Light feedback for selection, connection and errors. Respects the
/// "Vibration" switch.
@MainActor
enum Haptics {
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let impactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let notificationGenerator = UINotificationFeedbackGenerator()

    private static var enabled: Bool { AppSettings.shared.haptics }

    static func selection() {
        guard enabled else { return }
        selectionGenerator.selectionChanged()
    }

    static func impact() {
        guard enabled else { return }
        impactGenerator.impactOccurred()
    }

    static func light() {
        guard enabled else { return }
        lightGenerator.impactOccurred()
    }

    static func success() {
        guard enabled else { return }
        notificationGenerator.notificationOccurred(.success)
    }

    static func error() {
        guard enabled else { return }
        notificationGenerator.notificationOccurred(.error)
    }
}
