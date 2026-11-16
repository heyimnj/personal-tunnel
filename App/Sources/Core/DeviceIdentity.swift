import Foundation
import Security
import UIKit

/// The stable device identifier panels count devices by. Same Keychain item and
/// defaults keys as 1.x, so an update does not look like a new device.
enum DeviceIdentity {
    private static let service = "com.personaltunnelapp.subscription"
    private static let account = "hwid.v2"
    private static let defaultsKey = "vpndirect.subscription.hwid.v2"
    private static var cached: String?

    static var hwid: String {
        if let cached { return cached }
        let value = load()
        cached = value
        return value
    }

    private static func valid(_ value: String?) -> String? {
        guard let value, value.range(of: "^[a-zA-Z0-9=-]{10,64}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    private static func load() -> String {
        if let stored = valid(readKeychain()) { return stored }
        let defaults = UserDefaults.standard
        if let stored = valid(defaults.string(forKey: defaultsKey)) ?? valid(defaults.string(forKey: "vpndirect.subscription.hwid")) {
            writeKeychain(stored)
            return stored
        }
        // 3.2.1: a new identifier is random. It came from identifierForVendor, and
        // then «Удалить все данные» could not change it: the same value came back.
        // Installs that already have one keep it (Keychain, or the 1.x defaults).
        let fresh = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(32))
        writeKeychain(fresh)
        defaults.set(fresh, forKey: defaultsKey)
        return fresh
    }

    /// «Удалить все данные» (3.2.1): the identifier is gone from the Keychain and
    /// the defaults; the next subscription download that sends it makes a new one.
    static func erase() {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: defaultsKey)
        defaults.removeObject(forKey: "vpndirect.subscription.hwid")
        cached = nil
    }

    private static func readKeychain() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static var model: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
