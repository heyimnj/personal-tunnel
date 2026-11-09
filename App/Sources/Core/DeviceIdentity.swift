import Foundation
import Security
import TunnelKit
import UIKit

/// The device identity sent to panels that limit devices (Remnawave, Happ).
///
/// The HWID is created once from `identifierForVendor` and kept in the
/// Keychain (this device only). The Keychain item and the defaults key are
/// the ones Personal Tunnel 1.x used, so panels keep recognising the device.
enum DeviceIdentity {
    private static let keychainService = "com.personaltunnelapp.subscription"
    private static let keychainAccount = "hwid.v2"
    private static let defaultsKey = "vpndirect.subscription.hwid.v2"
    private static let legacyDefaultsKey = "vpndirect.subscription.hwid"

    @MainActor static var current: DeviceInfo {
        DeviceInfo(
            hwid: hwid,
            osName: "iOS",
            osVersion: UIDevice.current.systemVersion,
            model: modelIdentifier,
            locale: Locale.current.identifier
        )
    }

    @MainActor static let hwid: String = {
        if let stored = readKeychain(), DeviceInfo.isValidHWID(stored) { return stored }
        let defaults = UserDefaults.standard
        for key in [defaultsKey, legacyDefaultsKey] {
            if let stored = defaults.string(forKey: key), DeviceInfo.isValidHWID(stored) {
                writeKeychain(stored)
                defaults.set(stored, forKey: defaultsKey)
                return stored
            }
        }
        let seed = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let created = String(seed.replacingOccurrences(of: "-", with: "").prefix(32))
        writeKeychain(created)
        defaults.set(created, forKey: defaultsKey)
        return created
    }()

    static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return identifier.isEmpty ? "iPhone" : String(identifier.prefix(32))
    }

    private static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
