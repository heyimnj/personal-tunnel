import AppIntents

/// Siri and Shortcuts phrases.
struct PersonalTunnelShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleTunnelIntent(),
            phrases: ["Переключи \(.applicationName)", "Toggle \(.applicationName)"],
            shortTitle: "Переключить VPN",
            systemImageName: "power"
        )
        AppShortcut(
            intent: ConnectTunnelIntent(),
            phrases: ["Подключи \(.applicationName)", "Connect \(.applicationName)"],
            shortTitle: "Подключить",
            systemImageName: "lock.shield"
        )
        AppShortcut(
            intent: DisconnectTunnelIntent(),
            phrases: ["Отключи \(.applicationName)", "Disconnect \(.applicationName)"],
            shortTitle: "Отключить",
            systemImageName: "lock.open"
        )
    }
}
