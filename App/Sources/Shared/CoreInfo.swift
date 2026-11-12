import AppCore

enum CoreInfo {
    static var version: String { LibboxVersion() }
    static var xrayVersion: String { PtbridgeXrayVersion() }

    /// Which core the packet tunnel was built with (read from its Info.plist).
    static var tunnelCore: String {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { return "—" }
        for item in items where item.pathExtension == "appex" {
            if let value = Bundle(url: item)?.object(forInfoDictionaryKey: "PersonalTunnelCore") as? String, !value.isEmpty {
                return value == "combined" ? "sing-box + Xray-core" : "sing-box"
            }
        }
        return "—"
    }
}
