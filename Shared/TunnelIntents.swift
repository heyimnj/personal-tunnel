import AppIntents
import NetworkExtension
import TunnelKit
import WidgetKit

/// Starts and stops the VPN without the app's interface: widgets, Control
/// Center and Shortcuts. The extension starts with the configuration the
/// app last saved to the shared container.
enum TunnelSwitch {
    static func manager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier?.hasSuffix(".SingBoxPacketTunnel") == true }
            ?? managers.first
    }

    static func isOn() async -> Bool {
        guard let manager = try? await manager() else { return false }
        switch manager.connection.status {
        case .connected, .connecting, .reasserting: return true
        default: return false
        }
    }

    static func set(_ on: Bool) async throws {
        guard let manager = try await manager() else {
            throw SwitchError.noProfile
        }
        if on {
            if !manager.isEnabled {
                manager.isEnabled = true
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            }
            try manager.connection.startVPNTunnel()
        } else {
            if manager.isOnDemandEnabled {
                manager.isOnDemandEnabled = false
                try await manager.saveToPreferences()
            }
            manager.connection.stopVPNTunnel()
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    enum SwitchError: Error, CustomLocalizedStringResourceConvertible {
        case noProfile

        var localizedStringResource: LocalizedStringResource {
            "Сначала подключитесь один раз в приложении Personal Tunnel."
        }
    }
}

struct ToggleTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Переключить VPN"
    static var description = IntentDescription("Включает или выключает Personal Tunnel.")

    func perform() async throws -> some IntentResult {
        let on = await TunnelSwitch.isOn()
        try await TunnelSwitch.set(!on)
        return .result()
    }
}

struct ConnectTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Подключить VPN"
    static var description = IntentDescription("Подключает Personal Tunnel к выбранному серверу.")

    func perform() async throws -> some IntentResult {
        try await TunnelSwitch.set(true)
        return .result()
    }
}

struct DisconnectTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Отключить VPN"
    static var description = IntentDescription("Отключает Personal Tunnel.")

    func perform() async throws -> some IntentResult {
        try await TunnelSwitch.set(false)
        return .result()
    }
}

/// The Control Center toggle sets the state directly.
@available(iOS 18.0, *)
struct SetTunnelIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Personal Tunnel"

    @Parameter(title: "Включён")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        try await TunnelSwitch.set(value)
        return .result()
    }
}
