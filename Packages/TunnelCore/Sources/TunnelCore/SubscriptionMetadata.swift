import Foundation

/// What subscription response headers say (Remnawave, Marzban, 3x-ui...).
public enum SubscriptionHeaders {
    private static func decodeTitle(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasPrefix("base64:") {
            return TextCoding.decodeBase64String(String(value.dropFirst(7))) ?? value
        }
        return TextCoding.percentDecode(value)
    }

    /// Returns the provider's title (if any) and fills `info`.
    public static func parse(_ headers: [String: String], into info: inout SubscriptionInfo) -> String? {
        var fields: [String: String] = [:]
        for (key, value) in headers { fields[key.lowercased()] = value }
        if let userInfo = fields["subscription-userinfo"] {
            for part in userInfo.split(separator: ";") {
                let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2, let number = Int64(pair[1]) else { continue }
                switch pair[0].lowercased() {
                case "upload": info.uploadBytes = number
                case "download": info.downloadBytes = number
                case "total": info.totalBytes = number
                case "expire": info.expiresAt = number > 0 ? Date(timeIntervalSince1970: TimeInterval(number)) : nil
                default: break
                }
            }
        }
        if let hours = fields["profile-update-interval"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), hours > 0 {
            info.updateIntervalHours = hours
        }
        info.supportURL = fields["support-url"] ?? info.supportURL
        info.webPageURL = fields["profile-web-page-url"] ?? info.webPageURL
        if let text = fields["announce"] { info.announcement = decodeTitle(text) }
        for key in ["x-hwid-device-limit", "x-device-limit", "device-limit"] {
            if let value = fields[key].flatMap({ Int($0) }) { info.deviceLimit = value }
        }
        for key in ["x-hwid-device-used", "x-device-used", "device-used"] {
            if let value = fields[key].flatMap({ Int($0) }) { info.devicesUsed = value }
        }
        guard let title = fields["profile-title"].map(decodeTitle)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }

    /// A readable name when the provider sends none: the host of the address.
    public static func fallbackName(url: String) -> String {
        LinkParts(url)?.host.replacingOccurrences(of: "www.", with: "") ?? "Подписка"
    }
}

public enum Format {
    /// `106.7 MB`, `415 KB`, `Zero KB` — as the analytics cards print.
    public static func bytes(_ value: Int64) -> String {
        if value <= 0 { return "Zero KB" }
        let units = ["KB", "MB", "GB", "TB"]
        var amount = Double(value) / 1024
        var index = 0
        while amount >= 1000, index < units.count - 1 { amount /= 1024; index += 1 }
        if index == 0 { return "\(Int(amount.rounded())) \(units[index])" }
        return String(format: "%.1f %@", amount, units[index])
    }

    public static func speed(_ bytesPerSecond: Int64) -> String { bytes(bytesPerSecond) + "/с" }

    public static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    public static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "никогда" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) с назад" }
        if seconds < 3600 { return "\(seconds / 60) мин назад" }
        if seconds < 86400 { return "\(seconds / 3600) ч назад" }
        return "\(seconds / 86400) дн. назад"
    }

    public static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let tens = count % 100, units = count % 10
        if tens >= 11, tens <= 14 { return "\(count) \(many)" }
        if units == 1 { return "\(count) \(one)" }
        if units >= 2, units <= 4 { return "\(count) \(few)" }
        return "\(count) \(many)"
    }
}

/// Last two minutes of speed and totals per outbound, for analytics.
public struct TrafficHistory: Sendable {
    public static let capacity = 120
    public private(set) var down: [Int64] = []
    public private(set) var up: [Int64] = []

    public init() {}

    public mutating func append(down d: Int64, up u: Int64) {
        down.append(d); up.append(u)
        if down.count > TrafficHistory.capacity { down.removeFirst(); up.removeFirst() }
    }

    public mutating func reset() { down = []; up = [] }
}
