import Foundation

/// How a subscription is asked for (3.3, PT-12 / PT-13 / PT-14): which address is
/// accepted, which device headers go with each try, what a redirect may carry,
/// and the HWID a panel gets.
public enum SubscriptionRequest {
    /// The client names panels pick their answer by, in the order they are tried.
    public static let identityAgents = ["INCY/2.7.2", "Happ/3.13.0"]
    public static let plainAgent = "PersonalTunnel/2.0"

    /// Headers that describe the device; never sent to another host after a redirect.
    public static let deviceHeaders: Set<String> = ["x-hwid", "x-device-os", "x-ver-os", "x-device-model", "x-device-locale"]

    /// What the device tells a panel. `full` adds the iOS version and the
    /// language, sent only when a panel gave no servers without them.
    public struct Device: Equatable, Sendable {
        public var hwid: String
        public var model: String
        public var osVersion: String
        public var locale: String

        public init(hwid: String, model: String, osVersion: String, locale: String) {
            self.hwid = hwid
            self.model = model
            self.osVersion = osVersion
            self.locale = locale
        }

        public func headers(full: Bool) -> [String: String] {
            var result = ["X-HWID": hwid, "X-Device-OS": "iOS", "X-Device-Model": model]
            if full {
                result["X-Ver-OS"] = osVersion
                result["X-Device-Locale"] = locale
            }
            return result
        }
    }

    /// One request of a download: the client name and the headers it carries.
    public struct Attempt: Equatable, Sendable {
        public var agent: String
        public var headers: [String: String]
    }

    /// The tries in order: each identity client first with the HWID, OS and model
    /// only, then with the iOS version and language too; the plain client last,
    /// with no device data. Without device data: the client names alone.
    public static func attempts(device: Device?) -> [Attempt] {
        var result: [Attempt] = []
        for agent in identityAgents {
            if let device {
                result.append(Attempt(agent: agent, headers: device.headers(full: false)))
                result.append(Attempt(agent: agent, headers: device.headers(full: true)))
            } else {
                result.append(Attempt(agent: agent, headers: [:]))
            }
        }
        result.append(Attempt(agent: plainAgent, headers: [:]))
        return result
    }

    /// A subscription address that may be fetched, or the reason it may not.
    /// PT-12: plain `http://` is refused before any request — the address (its
    /// token) and the device headers would travel unencrypted.
    public static func address(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            throw ImportError(CoreText.t("Это не адрес подписки."))
        }
        if scheme == "http" {
            throw ImportError(CoreText.t("Адрес подписки начинается с http://: он и данные устройства ушли бы без шифрования. Нужен адрес https://."))
        }
        guard scheme == "https" else { throw ImportError(CoreText.t("Это не адрес подписки.")) }
        return url
    }

    /// The headers a redirect from `from` to `to` may carry, or nil when it must
    /// not be followed: https → http is refused, and a different host loses the
    /// device headers (PT-13).
    public static func redirected(_ headers: [String: String], from: URL, to: URL) -> [String: String]? {
        if from.scheme?.lowercased() == "https", to.scheme?.lowercased() != "https" { return nil }
        guard from.host?.lowercased() != to.host?.lowercased() else { return headers }
        return headers.filter { !deviceHeaders.contains($0.key.lowercased()) }
    }

    /// 3.3: the HWID a new subscription sends — HMAC-SHA256(device HWID, panel
    /// host), the first 32 hex characters — so panels cannot match the device by
    /// it. Subscriptions added before keep the device's own HWID.
    public static func hwid(_ device: String, host: String) -> String {
        let mac = SHA256.hmac(key: Array(device.utf8), message: Array(host.lowercased().utf8))
        return String(mac.map { String(format: "%02x", $0) }.joined().prefix(32))
    }
}

/// What an import would add, shown before anything is fetched (PT-14).
public enum ImportPreview: Equatable, Sendable {
    /// A subscription address: its host only (no path, no token).
    case subscription(host: String)
    /// Servers in the text itself: how many, their protocols, and how many have
    /// no certificate check.
    case servers(count: Int, protocols: [String], unchecked: Int)
    case invalid(String)

    public static func of(_ text: String) -> ImportPreview {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", !trimmed.contains("\n") {
            do {
                let address = try SubscriptionRequest.address(trimmed)
                return .subscription(host: address.host?.lowercased() ?? "")
            } catch {
                return .invalid((error as? ImportError)?.message ?? "\(error)")
            }
        }
        do {
            let result = try ContentImporter.parse(trimmed)
            let nodes = NodeAssembler.assemble(result.nodes)
            guard !nodes.isEmpty else { return .invalid(CoreText.t("Серверов не найдено.")) }
            var protocols: [String] = []
            for node in nodes where !protocols.contains(node.facts.proto) { protocols.append(node.facts.proto) }
            return .servers(count: nodes.count, protocols: protocols, unchecked: CertificateCheck.unchecked(nodes))
        } catch {
            return .invalid((error as? ImportError)?.message ?? "\(error)")
        }
    }
}

/// SHA-256 and HMAC-SHA256 in plain Swift: TunnelCore has only Foundation, which
/// has no hashing on Linux.
enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var data = message
        let bitLength = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((bitLength >> UInt64(shift)) & 0xff)) }
        func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 { (value >> count) | (value << (32 - count)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for i in 0 ..< 16 {
                let j = chunk + i * 4
                w[i] = UInt32(data[j]) << 24 | UInt32(data[j + 1]) << 16 | UInt32(data[j + 2]) << 8 | UInt32(data[j + 3])
            }
            for i in 16 ..< 64 {
                let s0 = rotate(w[i - 15], 7) ^ rotate(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotate(w[i - 2], 17) ^ rotate(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0 ..< 64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ choice &+ k[i] &+ w[i]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ majority
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { value in (0 ..< 4).map { UInt8((value >> UInt32(24 - $0 * 8)) & 0xff) } }
    }

    static func hmac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var block = key.count > 64 ? hash(key) : key
        block += [UInt8](repeating: 0, count: 64 - block.count)
        let inner = hash(block.map { $0 ^ 0x36 } + message)
        return hash(block.map { $0 ^ 0x5c } + inner)
    }
}
