import Foundation

/// Transport and TLS parameters shared by VLESS, VMess and Trojan, collected
/// from a share link, an Xray `streamSettings` object or a Clash proxy, and
/// turned into the sing-box `transport` and `tls` objects.
struct StreamSettings {
    var network = "tcp"
    var host: String?
    var path: String?
    var serviceName: String?
    /// `http` selects the HTTP/1.1 header obfuscation of TCP transport.
    var headerType: String?
    var mode: String?
    var method: String?
    var headers: [String: String] = [:]
    var xhttpExtra: JSON?
    var maxEarlyData: Int?
    var earlyDataHeaderName: String?

    var security = "none"
    var serverName: String?
    var alpn: [String] = []
    var fingerprint: String?
    var insecure = false
    var realityPublicKey: String?
    var realityShortID: String?
    var echConfig: String?
    var certificatePin: String?

    // MARK: Transport

    func transport() throws -> JSON? {
        switch network.lowercased() {
        case "", "tcp", "raw", "none":
            guard headerType?.lowercased() == "http" else { return nil }
            var object: [String: JSON] = ["type": "http", "method": .string(method ?? "GET")]
            if let host = host?.nonEmpty { object["host"] = .strings(StreamSettings.list(host)) }
            object["path"] = .string(path?.nonEmpty ?? "/")
            return .object(object)
        case "ws", "websocket":
            var object: [String: JSON] = ["type": "ws"]
            var effectivePath = path?.nonEmpty ?? "/"
            var earlyData = maxEarlyData
            // `?ed=2048` in the path is the Xray way to ask for early data.
            if let range = effectivePath.range(of: "?ed=") {
                let value = effectivePath[range.upperBound...].prefix { $0.isNumber }
                earlyData = Int(value) ?? earlyData
                effectivePath = String(effectivePath[effectivePath.startIndex ..< range.lowerBound])
                if effectivePath.isEmpty { effectivePath = "/" }
            }
            object["path"] = .string(effectivePath)
            if let earlyData, earlyData > 0 {
                object["max_early_data"] = .int(earlyData)
                object["early_data_header_name"] = .string(earlyDataHeaderName ?? "Sec-WebSocket-Protocol")
            }
            var allHeaders = headers
            if let host = host?.nonEmpty { allHeaders["Host"] = host }
            if !allHeaders.isEmpty { object["headers"] = .object(allHeaders.mapValues { .string($0) }) }
            return .object(object)
        case "grpc", "gun":
            var object: [String: JSON] = ["type": "grpc"]
            if let serviceName = (serviceName ?? path)?.nonEmpty {
                object["service_name"] = .string(serviceName.hasPrefix("/") ? String(serviceName.dropFirst()) : serviceName)
            }
            return .object(object)
        case "httpupgrade":
            var object: [String: JSON] = ["type": "httpupgrade", "path": .string(path?.nonEmpty ?? "/")]
            if let host = host?.nonEmpty { object["host"] = .string(host) }
            if !headers.isEmpty { object["headers"] = .object(headers.mapValues { .string($0) }) }
            return .object(object)
        case "http", "h2", "h3":
            var object: [String: JSON] = ["type": "http"]
            if let host = host?.nonEmpty { object["host"] = .strings(StreamSettings.list(host)) }
            if let path = path?.nonEmpty { object["path"] = .string(path) }
            if let method = method?.nonEmpty { object["method"] = .string(method) }
            if !headers.isEmpty { object["headers"] = .object(headers.mapValues { .string($0) }) }
            return .object(object)
        case "quic":
            return ["type": "quic"]
        case "xhttp", "splithttp":
            return xhttpTransport()
        case "kcp", "mkcp":
            throw ImportError.unsupportedTransport("mKCP")
        default:
            throw ImportError.unsupportedTransport(network)
        }
    }

    private func xhttpTransport() -> JSON {
        var object: [String: JSON] = ["type": "xhttp", "path": .string(path?.nonEmpty ?? "/")]
        if let host = host?.nonEmpty { object["host"] = .string(host) }
        if let mode = mode?.nonEmpty, mode != "auto" { object["mode"] = .string(mode) }
        var allHeaders = headers
        if let extra = xhttpExtra?.object {
            for (key, value) in extra {
                switch key {
                case "headers":
                    for (name, header) in value.object ?? [:] {
                        if let text = header.string { allHeaders[name] = text }
                    }
                case "xPaddingBytes", "x_padding_bytes":
                    if let range = StreamSettings.range(value) { object["x_padding_bytes"] = .string(range) }
                case "noGRPCHeader", "no_grpc_header":
                    if value.bool == true { object["no_grpc_header"] = true }
                case "noSSEHeader", "no_sse_header":
                    if value.bool == true { object["no_sse_header"] = true }
                case "scMaxEachPostBytes", "sc_max_each_post_bytes":
                    if let range = StreamSettings.range(value) { object["sc_max_each_post_bytes"] = .string(range) }
                case "scMinPostsIntervalMs", "sc_min_posts_interval_ms":
                    if let range = StreamSettings.range(value) { object["sc_min_posts_interval_ms"] = .string(range) }
                case "scMaxConcurrentPosts", "sc_max_concurrent_posts":
                    if let number = value.int { object["sc_max_concurrent_posts"] = .int(number) }
                case "scMaxBufferedPosts", "sc_max_buffered_posts":
                    if let number = value.int { object["sc_max_buffered_posts"] = .int(number) }
                case "xPaddingObfsMode", "x_padding_obfs_mode":
                    if value.bool == true { object["x_padding_obfs_mode"] = true }
                case "xPaddingKey", "x_padding_key":
                    if let text = value.text { object["x_padding_key"] = .string(text) }
                case "xPaddingHeader", "x_padding_header":
                    if let text = value.text { object["x_padding_header"] = .string(text) }
                case "xPaddingPlacement", "x_padding_placement":
                    if let text = value.text { object["x_padding_placement"] = .string(text) }
                case "xPaddingMethod", "x_padding_method":
                    if let text = value.text { object["x_padding_method"] = .string(text) }
                case "sessionPlacement", "sessionIDPlacement", "session_placement":
                    if let text = value.text { object["session_placement"] = .string(text) }
                case "sessionKey", "session_key":
                    if let text = value.text { object["session_key"] = .string(text) }
                case "seqPlacement", "seq_placement":
                    if let text = value.text { object["seq_placement"] = .string(text) }
                case "seqKey", "seq_key":
                    if let text = value.text { object["seq_key"] = .string(text) }
                case "uplinkHTTPMethod", "uplink_http_method":
                    if let text = value.text { object["uplink_http_method"] = .string(text) }
                case "uplinkDataPlacement", "uplink_data_placement":
                    if let text = value.text { object["uplink_data_placement"] = .string(text) }
                case "uplinkDataKey", "uplink_data_key":
                    if let text = value.text { object["uplink_data_key"] = .string(text) }
                case "uplinkChunkSize", "uplink_chunk_size":
                    if let range = StreamSettings.range(value) { object["uplink_chunk_size"] = .string(range) }
                case "xmux":
                    if let xmux = StreamSettings.xmux(value) { object["xmux"] = xmux }
                case "mode":
                    if object["mode"] == nil, let text = value.text, text != "auto" { object["mode"] = .string(text) }
                default:
                    continue
                }
            }
        }
        if !allHeaders.isEmpty { object["headers"] = .object(allHeaders.mapValues { .string($0) }) }
        return .object(object)
    }

    private static func xmux(_ value: JSON) -> JSON? {
        guard let source = value.object else { return nil }
        let names: [String: String] = [
            "maxConcurrency": "max_concurrency", "max_concurrency": "max_concurrency",
            "maxConnections": "max_connections", "max_connections": "max_connections",
            "cMaxReuseTimes": "c_max_reuse_times", "c_max_reuse_times": "c_max_reuse_times",
            "hMaxRequestTimes": "h_max_request_times", "h_max_request_times": "h_max_request_times",
            "hMaxReusableSecs": "h_max_reusable_secs", "h_max_reusable_secs": "h_max_reusable_secs",
        ]
        var result: [String: JSON] = [:]
        for (key, item) in source {
            if let target = names[key], let range = range(item) {
                result[target] = .string(range)
            } else if key == "hKeepAlivePeriod" || key == "h_keep_alive_period", let number = item.int {
                result["h_keep_alive_period"] = .int(number)
            }
        }
        return result.isEmpty ? nil : .object(result)
    }

    /// `"100-1000"`, `100` or `{"from": 100, "to": 1000}` as the `min-max` text.
    static func range(_ value: JSON) -> String? {
        if let object = value.object {
            guard let from = object["from"]?.int else { return nil }
            let to = object["to"]?.int ?? from
            return "\(from)-\(to)"
        }
        guard let text = value.text else { return nil }
        let parts = text.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty, parts.count <= 2, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return parts.joined(separator: "-")
    }

    static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: TLS

    /// - Parameter defaultServerName: used as SNI when none is given and the
    ///   server address is a domain name.
    func tls(defaultServerName: String?) -> JSON? {
        let kind = security.lowercased()
        guard kind == "tls" || kind == "reality" || kind == "xtls" else { return nil }
        var object: [String: JSON] = ["enabled": true]
        let sni = serverName?.nonEmpty ?? (kind == "reality" ? nil : defaultServerName.flatMap { StreamSettings.isIPAddress($0) ? nil : $0 })
        if let sni { object["server_name"] = .string(sni) }
        if insecure { object["insecure"] = true }
        if !alpn.isEmpty { object["alpn"] = .strings(alpn) }
        let utlsFingerprint = StreamSettings.utlsFingerprint(fingerprint) ?? (kind == "reality" ? "chrome" : nil)
        if let utlsFingerprint {
            object["utls"] = ["enabled": true, "fingerprint": .string(utlsFingerprint)]
        }
        if kind == "reality" {
            var reality: [String: JSON] = ["enabled": true]
            if let key = realityPublicKey?.nonEmpty { reality["public_key"] = .string(key) }
            if let shortID = realityShortID?.nonEmpty { reality["short_id"] = .string(shortID) }
            object["reality"] = .object(reality)
        }
        if let echConfig = echConfig?.nonEmpty {
            object["ech"] = ["enabled": true, "config": .strings(StreamSettings.pemECH(echConfig))]
        }
        return .object(object)
    }

    /// Maps client fingerprint names to the uTLS fingerprints sing-box knows.
    static func utlsFingerprint(_ value: String?) -> String? {
        guard let value = value?.trimmed.lowercased(), !value.isEmpty, value != "none" else { return nil }
        switch value {
        case "chrome", "firefox", "edge", "safari", "360", "qq", "ios", "android", "random", "randomized":
            return value
        case "randomizednoalpn", "randomized-noalpn": return "randomized"
        case "chrome_pq", "chrome_psk", "chrome_psk_shuffle", "chrome_padding_psk_shuffle", "chrome_pq_psk":
            return value
        default:
            return "chrome"
        }
    }

    static func pemECH(_ config: String) -> [String] {
        if config.contains("BEGIN ECH CONFIGS") {
            return config.split(separator: "\n").map(String.init)
        }
        return ["-----BEGIN ECH CONFIGS-----", config, "-----END ECH CONFIGS-----"]
    }

    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    // MARK: Share link parameters

    /// Reads the v2rayN / Xray share link query parameters.
    static func fromQuery(_ query: [String: String], defaultSecurity: String = "none") -> StreamSettings {
        var settings = StreamSettings()
        settings.network = query["type"]?.nonEmpty ?? query["network"]?.nonEmpty ?? "tcp"
        settings.host = query["host"]?.nonEmpty
        settings.path = query["path"]?.nonEmpty
        settings.serviceName = query["servicename"]?.nonEmpty ?? query["service_name"]?.nonEmpty
        settings.headerType = query["headertype"]?.nonEmpty
        settings.mode = query["mode"]?.nonEmpty
        if let extra = query["extra"]?.nonEmpty { settings.xhttpExtra = JSON.tryParse(extra) }
        if let ed = query["ed"].flatMap(Int.init) { settings.maxEarlyData = ed }
        if let edHeader = query["eh"]?.nonEmpty { settings.earlyDataHeaderName = edHeader }
        settings.security = query["security"]?.nonEmpty ?? defaultSecurity
        if settings.security == "none", query["tls"] == "1" || query["tls"] == "true" { settings.security = "tls" }
        settings.serverName = query["sni"]?.nonEmpty ?? query["peer"]?.nonEmpty ?? query["servername"]?.nonEmpty
        if let alpn = query["alpn"]?.nonEmpty { settings.alpn = list(alpn) }
        settings.fingerprint = query["fp"]?.nonEmpty ?? query["fingerprint"]?.nonEmpty
        let insecure = query["allowinsecure"] ?? query["insecure"] ?? query["allow_insecure"] ?? query["skip-cert-verify"]
        settings.insecure = insecure.map { ["1", "true", "yes"].contains($0.lowercased()) } ?? false
        settings.realityPublicKey = query["pbk"]?.nonEmpty ?? query["publickey"]?.nonEmpty
        settings.realityShortID = query["sid"]?.nonEmpty ?? query["shortid"]?.nonEmpty
        settings.echConfig = query["ech"]?.nonEmpty
        return settings
    }
}
