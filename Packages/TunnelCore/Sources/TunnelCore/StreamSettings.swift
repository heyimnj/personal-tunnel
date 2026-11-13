import Foundation

public struct ImportError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Transport and TLS of a server in Xray terms, turned into the sing-box
/// `tls` and `transport` objects. Share links and Xray JSON both go through it.
public struct StreamSpec: Equatable {
    public var network = "tcp"
    public var security = "none"
    public var hosts: [String] = []
    public var path: String?
    public var serviceName: String?
    public var mode: String?
    public var headerType: String?
    public var sni: String?
    public var alpn: [String] = []
    public var fingerprint: String?
    public var allowInsecure = false
    public var realityPublicKey: String?
    public var realityShortID: String?
    public var headers: [String: String] = [:]
    public var xhttpExtra: JSONValue?
    public var earlyData: Int?
    public var earlyDataHeader: String?
    /// Split the TLS ClientHello (Xray finalmask `fragment`); client side only.
    public var tlsFragment = false

    public init() {}

    static let fingerprints: Set<String> = [
        "chrome", "firefox", "edge", "safari", "360", "qq", "ios", "android", "random", "randomized",
        "chrome_psk", "chrome_psk_shuffle", "chrome_padding_psk_shuffle", "chrome_pq", "chrome_pq_psk",
    ]

    private func usableFingerprint() -> String? {
        guard let value = fingerprint?.lowercased(), !value.isEmpty, value != "none" else { return nil }
        return StreamSpec.fingerprints.contains(value) ? value : "chrome"
    }

    /// The `tls` object, or `nil` when the server uses no transport TLS.
    public func tls(server: String, required: Bool = false) throws -> JSONValue? {
        let kind = security.lowercased()
        let isReality = kind == "reality"
        guard isReality || kind == "tls" || kind == "xtls" || required else { return nil }
        var tls: [String: JSONValue] = ["enabled": true]
        let name = (sni?.isEmpty == false ? sni : nil) ?? hosts.first(where: { !$0.isEmpty && !TextCoding.isIPAddress($0) })
            ?? (TextCoding.isIPAddress(server) ? nil : server)
        if let name, !name.isEmpty { tls["server_name"] = .string(name) }
        if tlsFragment { tls["fragment"] = true }
        if allowInsecure, !isReality { tls["insecure"] = true }
        let protocols = alpn.filter { !$0.isEmpty }
        if !protocols.isEmpty, !isReality { tls["alpn"] = JSONValue(protocols) }
        if isReality {
            guard let key = realityPublicKey, StreamSpec.isRealityKey(key) else {
                throw ImportError(CoreText.t("REALITY: в ссылке нет открытого ключа (pbk) или он неверный."))
            }
            let shortID = realityShortID ?? ""
            guard shortID.count <= 16, shortID.count % 2 == 0, shortID.allSatisfy(\.isHexDigit) else {
                throw ImportError(CoreText.t("REALITY: неверный short ID."))
            }
            tls["reality"] = ["enabled": true, "public_key": .string(key), "short_id": .string(shortID)]
            // REALITY only works through uTLS.
            tls["utls"] = ["enabled": true, "fingerprint": .string(usableFingerprint() ?? "chrome")]
        } else if let fingerprint = usableFingerprint() {
            tls["utls"] = ["enabled": true, "fingerprint": .string(fingerprint)]
        }
        return .object(tls)
    }

    static func isRealityKey(_ key: String) -> Bool {
        guard let data = TextCoding.decodeBase64(key) else { return false }
        return data.count == 32
    }

    /// The `transport` object, or `nil` for plain TCP.
    public func transport() throws -> JSONValue? {
        let host = hosts.first(where: { !$0.isEmpty })
        switch network.lowercased() {
        case "", "tcp", "raw":
            guard headerType?.lowercased() == "http" else { return nil }
            var object: [String: JSONValue] = ["type": "http"]
            if !hosts.isEmpty { object["host"] = JSONValue(hosts) }
            if let path, !path.isEmpty { object["path"] = .string(path) }
            return .object(object)
        case "ws", "websocket":
            var object: [String: JSONValue] = ["type": "ws"]
            var route = path ?? "/"
            var early = earlyData
            if let range = route.range(of: "ed=", options: .backwards), let mark = route.firstIndex(of: "?"), range.lowerBound > mark {
                let digits = route[range.upperBound...].prefix { $0.isNumber }
                if let value = Int(digits), value > 0 {
                    early = early ?? value
                    var query = route[route.index(after: mark)...].split(separator: "&").map(String.init)
                    query.removeAll { $0.hasPrefix("ed=") }
                    route = String(route[..<mark]) + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
                }
            }
            object["path"] = .string(route.isEmpty ? "/" : route)
            var fields = headers
            if let host { fields["Host"] = host }
            if !fields.isEmpty { object["headers"] = .object(fields.mapValues(JSONValue.string)) }
            if let early, early > 0 {
                object["max_early_data"] = .int(Int64(early))
                object["early_data_header_name"] = .string(earlyDataHeader ?? "Sec-WebSocket-Protocol")
            }
            return .object(object)
        case "grpc", "gun":
            var object: [String: JSONValue] = ["type": "grpc"]
            if let name = serviceName ?? path, !name.isEmpty { object["service_name"] = .string(name) }
            return .object(object)
        case "httpupgrade":
            var object: [String: JSONValue] = ["type": "httpupgrade"]
            if let host { object["host"] = .string(host) }
            object["path"] = .string((path?.isEmpty == false ? path : nil) ?? "/")
            if !headers.isEmpty { object["headers"] = .object(headers.mapValues(JSONValue.string)) }
            return .object(object)
        case "h2", "http":
            var object: [String: JSONValue] = ["type": "http"]
            if !hosts.isEmpty { object["host"] = JSONValue(hosts.filter { !$0.isEmpty }) }
            if let path, !path.isEmpty { object["path"] = .string(path) }
            return .object(object)
        case "xhttp", "splithttp":
            var object: [String: JSONValue] = ["type": "xhttp"]
            if let host { object["host"] = .string(host) }
            object["path"] = .string((path?.isEmpty == false ? path : nil) ?? "/")
            if let mode, !mode.isEmpty { object["mode"] = .string(mode) }
            var fields = headers
            if let extra = xhttpExtra {
                for (key, value) in XHTTPOptions.map(extra) {
                    if key == "headers", let more = value.objectValue {
                        for (name, text) in more { if let text = text.text { fields[name] = text } }
                    } else if object[key] == nil || key == "mode" {
                        object[key] = value
                    }
                }
            }
            fields["Host"] = nil
            if !fields.isEmpty { object["headers"] = .object(fields.mapValues(JSONValue.string)) }
            return .object(object)
        case "quic":
            return ["type": "quic"]
        case "kcp", "mkcp":
            throw ImportError(CoreText.t("Транспорт mKCP не поддерживается ядром sing-box."))
        default:
            throw ImportError(CoreText.f("Неизвестный транспорт «%@».", "\(network)"))
        }
    }
}

/// Xray's `xhttpSettings` / link `extra` fields in the names the core expects.
enum XHTTPOptions {
    private static let textFields: [String: String] = [
        "xPaddingBytes": "x_padding_bytes", "scMaxEachPostBytes": "sc_max_each_post_bytes",
        "scMinPostsIntervalMs": "sc_min_posts_interval_ms", "uplinkChunkSize": "uplink_chunk_size",
        "sessionPlacement": "session_placement", "sessionKey": "session_key", "seqPlacement": "seq_placement",
        "seqKey": "seq_key", "uplinkDataPlacement": "uplink_data_placement", "uplinkDataKey": "uplink_data_key",
        "uplinkHTTPMethod": "uplink_http_method", "xPaddingKey": "x_padding_key", "xPaddingHeader": "x_padding_header",
        "xPaddingPlacement": "x_padding_placement", "xPaddingMethod": "x_padding_method",
    ]
    private static let flagFields: [String: String] = [
        "noGRPCHeader": "no_grpc_header", "xPaddingObfsMode": "x_padding_obfs_mode",
    ]
    private static let xmuxRanges: [String: String] = [
        "maxConcurrency": "max_concurrency", "maxConnections": "max_connections", "cMaxReuseTimes": "c_max_reuse_times",
        "hMaxRequestTimes": "h_max_request_times", "hMaxReusableSecs": "h_max_reusable_secs",
    ]

    /// `100`, `"100-200"` and `{"from":100,"to":200}` all become the `"100-200"` form.
    static func range(_ value: JSONValue) -> String? {
        if let object = value.objectValue {
            guard let from = object["from"]?.looseInt, let to = object["to"]?.looseInt else { return nil }
            return from == to ? String(from) : "\(from)-\(to)"
        }
        guard let text = value.text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }

    static func map(_ extra: JSONValue) -> [String: JSONValue] {
        guard let source = extra.objectValue else { return [:] }
        var result: [String: JSONValue] = [:]
        for (key, value) in source {
            if let name = textFields[key], let text = range(value) {
                result[name] = .string(text)
            } else if let name = flagFields[key], let flag = value.looseBool {
                if flag { result[name] = true }
            } else if key == "mode", let text = value.stringValue, !text.isEmpty {
                result["mode"] = .string(text)
            } else if key == "headers", value.objectValue != nil {
                result["headers"] = value
            } else if key == "xmux", let xmux = value.objectValue {
                var mapped: [String: JSONValue] = [:]
                for (field, item) in xmux {
                    if let name = xmuxRanges[field], let text = range(item), text != "0" {
                        mapped[name] = Int(text).map { JSONValue.int(Int64($0)) } ?? .string(text)
                    } else if field == "hKeepAlivePeriod", let seconds = item.looseInt, seconds != 0 {
                        mapped["h_keep_alive_period"] = .int(Int64(seconds))
                    }
                }
                if !mapped.isEmpty { result["xmux"] = .object(mapped) }
            }
        }
        return result
    }
}
