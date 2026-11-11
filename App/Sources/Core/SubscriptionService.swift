import Foundation
import TunnelCore
import UIKit

/// Downloads subscriptions. Happ identity first (Remnawave serves Xray JSON and
/// counts devices by HWID), a plain client as the fallback.
enum SubscriptionService {
    struct Fetched {
        var nodes: [ServerNode]
        var title: String?
        var info: SubscriptionInfo
        var summary: String?
    }

    private static let userAgents = ["Happ/3.13.0", "PersonalTunnel/2.0"]

    static func fetch(url text: String, sendIdentity: Bool) async throws -> Fetched {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { throw ImportError("Это не адрес подписки.") }
        var lastError: Error = ImportError("Подписка не загрузилась.")
        for agent in userAgents {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/plain, application/json, */*", forHTTPHeaderField: "Accept")
            if sendIdentity, agent.hasPrefix("Happ/") {
                request.setValue(DeviceIdentity.hwid, forHTTPHeaderField: "X-HWID")
                request.setValue("iOS", forHTTPHeaderField: "X-Device-OS")
                request.setValue(UIDevice.current.systemVersion, forHTTPHeaderField: "X-Ver-OS")
                request.setValue(DeviceIdentity.model, forHTTPHeaderField: "X-Device-Model")
                request.setValue(Locale.current.identifier, forHTTPHeaderField: "X-Device-Locale")
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ImportError("Сервер подписки не ответил.") }
                guard (200 ..< 300).contains(http.statusCode) else {
                    throw ImportError("Сервер подписки ответил кодом \(http.statusCode).")
                }
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields { headers["\(key)"] = "\(value)" }
                var info = SubscriptionInfo()
                let title = SubscriptionHeaders.parse(headers, into: &info)
                let result = try ContentImporter.parse(String(decoding: data, as: UTF8.self))
                return Fetched(nodes: NodeAssembler.assemble(result.nodes), title: title, info: info, summary: result.summary)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
