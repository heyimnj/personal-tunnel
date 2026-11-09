import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Identity sent to panels that count devices (Remnawave, Happ-compatible).
public struct DeviceInfo: Equatable, Sendable {
    public var hwid: String
    public var osName: String
    public var osVersion: String
    public var model: String
    public var locale: String

    public init(hwid: String, osName: String, osVersion: String, model: String, locale: String) {
        self.hwid = hwid
        self.osName = osName
        self.osVersion = osVersion
        self.model = model
        self.locale = locale
    }

    public var headers: [String: String] {
        [
            "X-HWID": hwid,
            "X-Device-OS": osName,
            "X-Ver-OS": osVersion,
            "X-Device-Model": model,
            "X-Device-Locale": locale,
        ]
    }

    /// Remnawave accepts `^[a-zA-Z0-9=-]{10,64}$`.
    public static func isValidHWID(_ value: String) -> Bool {
        (10 ... 64).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "=" || $0 == "-") }
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data
    public var finalURL: URL?

    public init(statusCode: Int, headers: [String: String], body: Data, finalURL: URL?) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// One request the app made on its own, for the network activity screen.
public struct NetworkActivityEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var purpose: String
    public var method: String
    /// Scheme, host and path. Query and tokens are masked.
    public var target: String
    /// Header names with masked values.
    public var headers: [String]
    public var outcome: String

    public init(purpose: String, method: String, target: String, headers: [String], outcome: String, date: Date = Date()) {
        id = UUID()
        self.date = date
        self.purpose = purpose
        self.method = method
        self.target = target
        self.headers = headers
        self.outcome = outcome
    }

    public static func describing(_ request: URLRequest, purpose: String, outcome: String) -> NetworkActivityEntry {
        let url = request.url
        var target = ""
        if let url {
            target = (url.scheme ?? "https") + "://" + (url.host ?? "")
            if let port = url.port { target += ":\(port)" }
            target += Redactor.redactPath(url.path)
            if url.query != nil { target += "?…" }
        }
        let headers = (request.allHTTPHeaderFields ?? [:]).keys.sorted().map { name -> String in
            let value = request.value(forHTTPHeaderField: name) ?? ""
            switch name.lowercased() {
            case "user-agent", "accept", "accept-encoding", "x-device-os", "x-ver-os", "x-device-model", "x-device-locale":
                return "\(name): \(value)"
            default:
                return "\(name): \(Redactor.mask(value))"
            }
        }
        return NetworkActivityEntry(purpose: purpose, method: request.httpMethod ?? "GET", target: target, headers: headers, outcome: outcome)
    }
}

public struct SubscriptionFetchError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public var statusCode: Int?
}

/// The outcome of a refresh.
public struct FetchedSubscription: Sendable {
    public var content: DecodedContent
    public var metadata: SubscriptionMetadata
    public var userAgent: String
}

/// Downloads and decodes a subscription, trying the client identities panels
/// expect one after another.
public struct SubscriptionFetcher: Sendable {
    public struct Identity: Sendable, Hashable {
        public var userAgent: String
        /// Device headers go only with the Happ identity, the one Remnawave
        /// and Happ panels use to count devices.
        public var sendsDeviceInfo: Bool
    }

    public static let identities: [Identity] = [
        Identity(userAgent: "Happ/3.13.0", sendsDeviceInfo: true),
        Identity(userAgent: "sfi/1.12.0 (PersonalTunnel/2.0)", sendsDeviceInfo: false),
        Identity(userAgent: "PersonalTunnel/2.0", sendsDeviceInfo: false),
    ]

    public static let maxBodyBytes = 32 * 1024 * 1024

    public var transport: HTTPTransport
    public var device: DeviceInfo?
    public var record: @Sendable (NetworkActivityEntry) -> Void

    public init(transport: HTTPTransport, device: DeviceInfo?, record: @escaping @Sendable (NetworkActivityEntry) -> Void = { _ in }) {
        self.transport = transport
        self.device = device
        self.record = record
    }

    /// The headers the first request will carry; shown to the user before
    /// they decide whether to send device information.
    public static func previewHeaders(device: DeviceInfo?, sendsDeviceInfo: Bool) -> [String: String] {
        var headers = ["User-Agent": identities[0].userAgent]
        if sendsDeviceInfo, let device {
            headers.merge(device.headers) { _, new in new }
        }
        return headers
    }

    public static func validatedURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
            throw SubscriptionFetchError(description: "Ссылка подписки должна начинаться с http:// или https://.", statusCode: nil)
        }
        return url
    }

    public func fetch(url text: String, sendsDeviceInfo: Bool) async throws -> FetchedSubscription {
        let url = try SubscriptionFetcher.validatedURL(text)
        var lastError: Error = SubscriptionFetchError(description: "Подписка не ответила.", statusCode: nil)
        for identity in SubscriptionFetcher.identities {
            try Task.checkCancellation()
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.httpMethod = "GET"
            request.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/plain, application/json, application/yaml, */*", forHTTPHeaderField: "Accept")
            if identity.sendsDeviceInfo, sendsDeviceInfo, let device {
                for (name, value) in device.headers { request.setValue(value, forHTTPHeaderField: name) }
            }
            let response: HTTPResponse
            do {
                response = try await transport.send(request)
            } catch {
                record(.describing(request, purpose: "Обновление подписки", outcome: "ошибка сети"))
                if error is CancellationError { throw error }
                lastError = SubscriptionFetchError(description: "Сеть: \(error.localizedDescription)", statusCode: nil)
                continue
            }
            guard (200 ..< 300).contains(response.statusCode) else {
                record(.describing(request, purpose: "Обновление подписки", outcome: "HTTP \(response.statusCode)"))
                lastError = SubscriptionFetchError(description: SubscriptionFetcher.describeStatus(response.statusCode), statusCode: response.statusCode)
                continue
            }
            guard response.body.count <= SubscriptionFetcher.maxBodyBytes else {
                record(.describing(request, purpose: "Обновление подписки", outcome: "слишком большой ответ"))
                throw SubscriptionFetchError(description: "Ответ подписки больше 32 МБ.", statusCode: response.statusCode)
            }
            let body = String(decoding: response.body, as: UTF8.self)
            do {
                let content = try ContentDecoder.decode(body)
                record(.describing(request, purpose: "Обновление подписки", outcome: "HTTP \(response.statusCode), серверов: \(content.servers.count)"))
                let metadata = SubscriptionMetadata.parse(headers: response.headers, bodyMetadata: content.bodyMetadata)
                if content.servers.isEmpty, identity != SubscriptionFetcher.identities.last {
                    lastError = SubscriptionFetchError(description: content.skipped.first?.reason ?? ImportError.empty.description, statusCode: response.statusCode)
                    continue
                }
                return FetchedSubscription(content: content, metadata: metadata, userAgent: identity.userAgent)
            } catch {
                record(.describing(request, purpose: "Обновление подписки", outcome: "HTTP \(response.statusCode), формат не распознан"))
                lastError = SubscriptionFetchError(description: String(describing: error), statusCode: response.statusCode)
                continue
            }
        }
        throw lastError
    }

    static func describeStatus(_ code: Int) -> String {
        switch code {
        case 401, 403: return "Панель отказала в доступе (HTTP \(code)). Проверьте ссылку или лимит устройств."
        case 404: return "Подписка не найдена (HTTP 404)."
        case 429: return "Слишком много запросов (HTTP 429). Попробуйте позже."
        case 500 ..< 600: return "Ошибка сервера подписки (HTTP \(code))."
        default: return "Подписка ответила HTTP \(code)."
        }
    }
}

// MARK: - URLSession transport

/// `URLSession` transport that never sends identifying headers to another
/// origin on redirect and refuses HTTPS → HTTP downgrades.
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    static let sensitiveHeaders: Set<String> = [
        "x-hwid", "x-device-os", "x-ver-os", "x-device-model", "x-device-locale", "authorization",
        "proxy-authorization", "cookie",
    ]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        #if !canImport(FoundationNetworking)
            configuration.waitsForConnectivity = false
        #endif
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    override public init() {
        super.init()
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SubscriptionFetchError(description: "Ответ не по HTTP.", statusCode: nil)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String { headers[key] = "\(value)" }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data, finalURL: http.url)
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.resume()
        }
    }

    public func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let original = task.originalRequest?.url
        let next = request.url
        if original?.scheme?.lowercased() == "https", next?.scheme?.lowercased() == "http" {
            completionHandler(nil)
            return
        }
        if URLSessionTransport.origin(original) == URLSessionTransport.origin(next) {
            completionHandler(request)
            return
        }
        var stripped = request
        for (name, _) in request.allHTTPHeaderFields ?? [:] where URLSessionTransport.sensitiveHeaders.contains(name.lowercased()) {
            stripped.setValue(nil, forHTTPHeaderField: name)
        }
        completionHandler(stripped)
    }

    static func origin(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}
