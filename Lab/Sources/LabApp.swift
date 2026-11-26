import UIKit

// PT Lab 2.0: the app itself (../App) is the Lab; this screen of variants opens
// from the flask button (LabOverlay). Its settings and pretend tunnel follow.

/// What the lab remembers between launches.
enum LabSettings {
    enum Theme: Int, CaseIterable {
        case system, dark, light

        var style: UIUserInterfaceStyle {
            switch self {
            case .system: return .unspecified
            case .dark: return .dark
            case .light: return .light
            }
        }

        var title: String {
            switch self {
            case .system: return "Как в системе"
            case .dark: return "Тёмная"
            case .light: return "Светлая"
            }
        }
    }

    private static let defaults = UserDefaults.standard

    static var theme: Theme {
        get { Theme(rawValue: defaults.integer(forKey: "lab.theme")) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "lab.theme") }
    }

    static var press: PressStyle {
        get { PressStyle(rawValue: defaults.string(forKey: "lab.press") ?? "") ?? .wave }
        set { defaults.set(newValue.rawValue, forKey: "lab.press") }
    }

    static var variant: String {
        get { defaults.string(forKey: "lab.connectGlyph") ?? "" }
        set { defaults.set(newValue, forKey: "lab.connectGlyph") }
    }
}

/// A pretend tunnel: «Подключение…» for 2.5 s, then connected; a tap while it is
/// up or coming up stops it (0.65 s). Time is the lab's own clock, so the whole
/// screen can run slower.
final class MockTunnel {
    enum Phase { case off, connecting, on, disconnecting }

    static let connectTime: Double = 2.5
    static let stopTime: Double = 0.65

    private(set) var phase: Phase = .off
    private(set) var started: Double = 0
    var onChange: ((Phase) -> Void)?

    func tap(at now: Double) {
        switch phase {
        case .off: set(.connecting, now)
        case .connecting, .on: set(.disconnecting, now)
        case .disconnecting: break
        }
    }

    func reset(at now: Double) { set(.off, now) }

    func tick(at now: Double) {
        let elapsed = now - started
        if phase == .connecting, elapsed >= Self.connectTime { set(.on, now) }
        if phase == .disconnecting, elapsed >= Self.stopTime { set(.off, now) }
    }

    private func set(_ next: Phase, _ now: Double) {
        phase = next
        started = now
        onChange?(next)
    }
}
