import Foundation

/// Title and quota information reported by a subscription panel through
/// response headers (or `#key: value` lines in the body).
public struct SubscriptionMetadata: Equatable, Sendable {
    public var title: String?
    public var info: SubscriptionInfo

    public init(title: String? = nil, info: SubscriptionInfo = SubscriptionInfo()) {
        self.title = title
        self.info = info
    }

    public static func parse(headers: [String: String], bodyMetadata: [String: String] = [:]) -> SubscriptionMetadata {
        var values: [String: String] = [:]
        for (key, value) in bodyMetadata { values[key.lowercased()] = value }
        // Headers win over body lines.
        for (key, value) in headers { values[key.lowercased()] = value }

        var metadata = SubscriptionMetadata()
        if let raw = values["profile-title"] ?? values["subscription-name"] ?? values["profile-name"] {
            metadata.title = decodeValue(raw)
        }
        if metadata.title == nil, let disposition = values["content-disposition"] {
            metadata.title = filename(fromContentDisposition: disposition)
        }
        if let userInfo = values["subscription-userinfo"] {
            applyUserInfo(userInfo, to: &metadata.info)
        }
        if let raw = values["profile-update-interval"], let hours = Int(raw.trimmed), hours > 0 {
            metadata.info.updateIntervalHours = min(hours, 24 * 7)
        }
        if let raw = values["support-url"] ?? values["supporturl"] { metadata.info.supportURL = decodeValue(raw) }
        if let raw = values["profile-web-page-url"] ?? values["profile-webpage-url"] { metadata.info.webPageURL = decodeValue(raw) }
        if let raw = values["announce"] { metadata.info.announce = decodeValue(raw) }
        for key in ["x-hwid-device-limit", "x-device-limit", "x-devices-limit", "device-limit", "hwid-device-limit"] {
            if let raw = values[key], let limit = Int(raw.trimmed) {
                metadata.info.deviceLimit = limit
                break
            }
        }
        for key in ["x-hwid-device-used", "x-device-used", "x-devices-used", "device-used", "hwid-device-used"] {
            if let raw = values[key], let used = Int(raw.trimmed) {
                metadata.info.devicesUsed = used
                break
            }
        }
        if let raw = values["x-hwid-max-devices-reached"] ?? values["x-hwid-limit"], JSON.string(raw).bool == true {
            metadata.info.deviceLimitReached = true
        }
        return metadata
    }

    static func applyUserInfo(_ header: String, to info: inout SubscriptionInfo) {
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            let value = pair[1]
            switch pair[0].lowercased() {
            case "upload": info.uploadBytes = Int64(value) ?? Double(value).map { Int64($0) }
            case "download": info.downloadBytes = Int64(value) ?? Double(value).map { Int64($0) }
            case "total":
                let total = Int64(value) ?? Double(value).map { Int64($0) }
                info.totalBytes = (total ?? 0) > 0 ? total : nil
            case "expire":
                if let seconds = Double(value), seconds > 0 {
                    // Some panels send milliseconds.
                    let normalized = seconds > 100_000_000_000 ? seconds / 1000 : seconds
                    info.expiresAt = Date(timeIntervalSince1970: normalized)
                }
            default:
                continue
            }
        }
    }

    /// Decodes `base64:…`, percent-encoded and quoted header values.
    static func decodeValue(_ raw: String) -> String? {
        var value = raw.trimmed
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        if value.lowercased().hasPrefix("base64:") {
            let encoded = String(value.dropFirst("base64:".count))
            value = TextCoding.base64String(encoded) ?? encoded
        } else if value.contains("%") {
            value = TextCoding.percentDecoded(value)
        }
        // Headers are Latin-1 on the wire; recover UTF-8 sent as raw bytes.
        if value.unicodeScalars.contains(where: { (0x80 ... 0xFF).contains($0.value) }),
           value.unicodeScalars.allSatisfy({ $0.value <= 0xFF })
        {
            let bytes = value.unicodeScalars.map { UInt8($0.value) }
            if let decoded = String(bytes: bytes, encoding: .utf8) { value = decoded }
        }
        value = value.trimmed
        return value.isEmpty ? nil : value
    }

    static func filename(fromContentDisposition header: String) -> String? {
        for part in header.split(separator: ";") {
            let item = part.trimmingCharacters(in: .whitespaces)
            if item.lowercased().hasPrefix("filename*=") {
                let value = item.dropFirst("filename*=".count)
                let encoded = value.components(separatedBy: "''").last ?? String(value)
                return decodeValue(TextCoding.percentDecoded(encoded))
            }
        }
        for part in header.split(separator: ";") {
            let item = part.trimmingCharacters(in: .whitespaces)
            if item.lowercased().hasPrefix("filename=") {
                var name = decodeValue(String(item.dropFirst("filename=".count)))
                if let current = name, let dot = current.lastIndex(of: "."), current.distance(from: dot, to: current.endIndex) <= 6 {
                    name = String(current[current.startIndex ..< dot])
                }
                return name
            }
        }
        return nil
    }
}
