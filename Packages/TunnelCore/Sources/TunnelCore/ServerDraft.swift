import Foundation

/// A server typed in by hand («Создать вручную») or opened for editing: the
/// fields a person fills in, and the sing-box outbound they make.
public struct ServerDraft: Equatable, Sendable {
    public enum Proto: String, CaseIterable, Sendable {
        case vless, vmess, trojan, shadowsocks, hysteria2, tuic, wireguard

        public var title: String {
            switch self {
            case .vless: return "VLESS"
            case .vmess: return "VMess"
            case .trojan: return "Trojan"
            case .shadowsocks: return "Shadowsocks"
            case .hysteria2: return "Hysteria2"
            case .tuic: return "TUIC"
            case .wireguard: return "WireGuard"
            }
        }

        /// Protocols that carry a transport (TCP, WebSocket, gRPC…) and a TLS choice.
        public var hasTransport: Bool { [.vless, .vmess, .trojan].contains(self) }
        /// QUIC protocols: always TLS, never a transport.
        public var isQUIC: Bool { self == .hysteria2 || self == .tuic }
    }

    public enum Security: String, CaseIterable, Sendable { case none, tls, reality }
    public enum Transport: String, CaseIterable, Sendable { case tcp, ws, grpc, httpupgrade, xhttp }

    public static let shadowsocksMethods = ["2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
                                           "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305"]
    public static let fingerprints = ["chrome", "firefox", "safari", "ios", "edge", "random", "randomized"]

    public var name = ""
    public var proto = Proto.vless
    public var host = ""
    public var port = "443"
    /// UUID (VLESS, VMess, TUIC) or password (Trojan, Shadowsocks, Hysteria2).
    public var secret = ""
    /// TUIC's password beside its UUID.
    public var password = ""
    public var method = ServerDraft.shadowsocksMethods[0]
    public var vision = false
    public var security = Security.tls
    public var sni = ""
    public var fingerprint = "chrome"
    public var alpn = ""
    public var insecure = false
    public var publicKey = ""
    public var shortID = ""
    public var transport = Transport.tcp
    public var path = ""
    public var hostHeader = ""
    public var serviceName = ""
    /// Hysteria2: salamander obfuscation password and port hopping (`20000-30000`).
    public var obfsPassword = ""
    public var hopPorts = ""
    /// TUIC.
    public var congestion = "bbr"
    /// WireGuard.
    public var privateKey = ""
    public var peerPublicKey = ""
    public var preSharedKey = ""
    public var localAddress = ""
    public var mtu = "1280"

    public init() {}

    // MARK: Draft → outbound

    public func outbound() throws -> JSONValue {
        let host = self.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw ImportError(CoreText.t("Укажите адрес сервера.")) }
        guard let port = Int(self.port.trimmingCharacters(in: .whitespaces)), port > 0, port < 65536 else {
            throw ImportError(CoreText.t("Порт — число от 1 до 65535."))
        }
        let secret = self.secret.trimmingCharacters(in: .whitespaces)
        var object: [String: JSONValue] = ["type": .string(proto.rawValue), "server": .string(host), "server_port": .int(Int64(port))]
        switch proto {
        case .vless, .vmess:
            guard !secret.isEmpty else { throw ImportError(CoreText.t("Укажите UUID.")) }
            object["uuid"] = .string(secret)
            if proto == .vless {
                object["packet_encoding"] = "xudp"
                if vision, transport == .tcp, security != .none { object["flow"] = "xtls-rprx-vision" }
            } else {
                object["security"] = "auto"
            }
        case .trojan:
            guard !secret.isEmpty else { throw ImportError(CoreText.t("Укажите пароль.")) }
            object["password"] = .string(secret)
        case .shadowsocks:
            guard !secret.isEmpty else { throw ImportError(CoreText.t("Укажите пароль.")) }
            object["method"] = .string(method)
            object["password"] = .string(secret)
        case .hysteria2:
            if !secret.isEmpty { object["password"] = .string(secret) }
            if !obfsPassword.isEmpty { object["obfs"] = ["type": "salamander", "password": .string(obfsPassword)] }
            let ranges = ShareLink.portRanges(hopPorts)
            if !ranges.isEmpty { object["server_ports"] = JSONValue(ranges) }
        case .tuic:
            guard !secret.isEmpty else { throw ImportError(CoreText.t("Укажите UUID.")) }
            object["uuid"] = .string(secret)
            object["password"] = .string(password)
            object["congestion_control"] = .string(congestion)
        case .wireguard:
            return try wireguard(host: host, port: port)
        }
        if proto.isQUIC || security != .none { object["tls"] = tls(host: host) }
        if proto.hasTransport, let transport = transportObject() { object["transport"] = transport }
        return .object(object)
    }

    private func tls(host: String) -> JSONValue {
        var tls: [String: JSONValue] = ["enabled": true]
        let name = sni.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { tls["server_name"] = .string(name) } else if !TextCoding.isIPAddress(host) { tls["server_name"] = .string(host) }
        let protocols = alpn.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !protocols.isEmpty { tls["alpn"] = JSONValue(protocols) } else if proto == .hysteria2 || proto == .tuic { tls["alpn"] = ["h3"] }
        if insecure { tls["insecure"] = true }
        if proto.hasTransport, !fingerprint.isEmpty { tls["utls"] = ["enabled": true, "fingerprint": .string(fingerprint)] }
        if proto.hasTransport, security == .reality {
            tls["reality"] = ["enabled": true, "public_key": .string(publicKey.trimmingCharacters(in: .whitespaces)),
                              "short_id": .string(shortID.trimmingCharacters(in: .whitespaces))]
            if tls["utls"] == nil { tls["utls"] = ["enabled": true, "fingerprint": "chrome"] }
        }
        return .object(tls)
    }

    private func transportObject() -> JSONValue? {
        let path = self.path.isEmpty ? "/" : self.path
        switch transport {
        case .tcp: return nil
        case .ws:
            var object: [String: JSONValue] = ["type": "ws", "path": .string(path)]
            if !hostHeader.isEmpty { object["headers"] = ["Host": .string(hostHeader)] }
            return .object(object)
        case .grpc: return ["type": "grpc", "service_name": .string(serviceName)]
        case .httpupgrade:
            var object: [String: JSONValue] = ["type": "httpupgrade", "path": .string(path)]
            if !hostHeader.isEmpty { object["host"] = .string(hostHeader) }
            return .object(object)
        case .xhttp:
            var object: [String: JSONValue] = ["type": "xhttp", "path": .string(path), "mode": "auto"]
            if !hostHeader.isEmpty { object["host"] = .string(hostHeader) }
            return .object(object)
        }
    }

    private func wireguard(host: String, port: Int) throws -> JSONValue {
        guard !privateKey.isEmpty, !peerPublicKey.isEmpty else { throw ImportError(CoreText.t("Укажите закрытый ключ и ключ сервера.")) }
        let addresses = localAddress.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { $0.contains("/") ? $0 : ($0.contains(":") ? $0 + "/128" : $0 + "/32") }
        guard !addresses.isEmpty else { throw ImportError(CoreText.t("Укажите адрес интерфейса WireGuard.")) }
        var peer: [String: JSONValue] = ["address": .string(host), "port": .int(Int64(port)), "public_key": .string(peerPublicKey),
                                         "allowed_ips": ["0.0.0.0/0", "::/0"]]
        if !preSharedKey.isEmpty { peer["pre_shared_key"] = .string(preSharedKey) }
        return ["type": "wireguard", "address": JSONValue(addresses), "private_key": .string(privateKey),
                "mtu": .int(Int64(Int(mtu) ?? 1280)), "peers": [.object(peer)]]
    }

    // MARK: Outbound → draft

    /// The fields of an existing server, or nil for what this form cannot edit
    /// (groups, servers Xray runs, protocols it does not offer).
    public init?(outbound object: JSONValue, name: String) {
        guard let type = object["type"]?.stringValue?.lowercased(), let proto = Proto(rawValue: type) else { return nil }
        self.name = name
        self.proto = proto
        if proto == .wireguard {
            guard let peer = object["peers"]?.arrayValue?.first else { return nil }
            host = peer["address"]?.stringValue ?? ""
            port = peer["port"]?.looseInt.map(String.init) ?? "51820"
            peerPublicKey = peer["public_key"]?.stringValue ?? ""
            preSharedKey = peer["pre_shared_key"]?.stringValue ?? ""
            privateKey = object["private_key"]?.stringValue ?? ""
            localAddress = (object["address"]?.stringList ?? []).joined(separator: ", ")
            mtu = object["mtu"]?.looseInt.map(String.init) ?? "1280"
            return
        }
        host = object["server"]?.stringValue ?? ""
        port = object["server_port"]?.looseInt.map(String.init) ?? "443"
        secret = object["uuid"]?.stringValue ?? object["password"]?.stringValue ?? ""
        if proto == .tuic { password = object["password"]?.stringValue ?? "" }
        method = object["method"]?.stringValue ?? method
        vision = object["flow"]?.stringValue == "xtls-rprx-vision"
        congestion = object["congestion_control"]?.stringValue ?? congestion
        obfsPassword = object.at("obfs", "password")?.stringValue ?? ""
        hopPorts = (object["server_ports"]?.stringList ?? []).map { $0.replacingOccurrences(of: ":", with: "-") }.joined(separator: ",")
        let tls = object["tls"]
        if tls?.at("reality", "enabled")?.boolValue == true {
            security = .reality
            publicKey = tls?.at("reality", "public_key")?.stringValue ?? ""
            shortID = tls?.at("reality", "short_id")?.stringValue ?? ""
        } else {
            security = tls?["enabled"]?.boolValue == true ? .tls : .none
        }
        sni = tls?["server_name"]?.stringValue ?? ""
        fingerprint = tls?.at("utls", "fingerprint")?.stringValue ?? (proto.hasTransport ? "" : fingerprint)
        alpn = (tls?["alpn"]?.stringList ?? []).joined(separator: ",")
        insecure = tls?["insecure"]?.boolValue ?? false
        let transport = object["transport"]
        self.transport = Transport(rawValue: transport?["type"]?.stringValue?.lowercased() ?? "tcp") ?? .tcp
        path = transport?["path"]?.stringValue ?? ""
        hostHeader = transport?.at("headers", "Host")?.stringValue ?? transport?["host"]?.stringValue ?? ""
        serviceName = transport?["service_name"]?.stringValue ?? ""
    }
}
