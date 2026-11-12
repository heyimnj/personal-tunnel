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
        /// For the service log: what the subscription served and to which client name.
        var format: String
        var agent: String
        var issues: [ImportIssue]
        /// Servers only the plain list had (see `SubscriptionMerge`).
        var added = 0
    }

    /// Panels pick the answer by the client's name: Incy gets the full Xray JSON
    /// (Hysteria servers included, which some panels leave out for Happ), Happ the
    /// next, a plain client the list of links. A panel's "unsupported client" stub
    /// moves on to the next name.
    private static let userAgents = ["INCY/2.7.2", "Happ/3.13.0", "PersonalTunnel/2.0"]
    private static func sendsIdentity(_ agent: String) -> Bool { agent.hasPrefix("Happ/") || agent.hasPrefix("INCY/") }

    static func fetch(url text: String, sendIdentity: Bool) async throws -> Fetched {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { throw ImportError(L("Это не адрес подписки.")) }
        var lastError: Error = ImportError(L("Подписка не загрузилась."))
        for agent in userAgents {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/plain, application/json, */*", forHTTPHeaderField: "Accept")
            if sendIdentity, sendsIdentity(agent) {
                request.setValue(DeviceIdentity.hwid, forHTTPHeaderField: "X-HWID")
                request.setValue("iOS", forHTTPHeaderField: "X-Device-OS")
                request.setValue(UIDevice.current.systemVersion, forHTTPHeaderField: "X-Ver-OS")
                request.setValue(DeviceIdentity.model, forHTTPHeaderField: "X-Device-Model")
                request.setValue(Locale.current.identifier, forHTTPHeaderField: "X-Device-Locale")
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ImportError(L("Сервер подписки не ответил.")) }
                guard (200 ..< 300).contains(http.statusCode) else {
                    throw ImportError(Lf("Сервер подписки ответил кодом %@.", "\(http.statusCode)"))
                }
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields { headers["\(key)"] = "\(value)" }
                var info = SubscriptionInfo()
                let title = SubscriptionHeaders.parse(headers, into: &info)
                let result = try ContentImporter.parse(String(decoding: data, as: UTF8.self))
                if SubscriptionStub.isStub(result.nodes.map(\.name)) {
                    throw ImportError(Lf("Панель подписки не отдала серверы клиенту «%@»: %@", agent, result.nodes.map(\.name).joined(separator: " / ")))
                }
                var nodes = result.nodes
                var added = 0
                if result.format == .xray, agent != userAgents.last, let plain = await plainList(url) {
                    let extra = SubscriptionMerge.missing(from: plain, in: nodes)
                    nodes += extra
                    added = extra.count
                }
                return Fetched(nodes: NodeAssembler.assemble(nodes), title: title, info: info, summary: result.summary,
                               format: result.format.rawValue, agent: agent, issues: result.issues, added: added)
            } catch let error as URLError {
                // The network did not get through: another client name will not help,
                // and would only add another wait.
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// The same subscription as a plain client sees it (no Happ identity): some
    /// panels leave servers out of the Xray JSON they give Happ.
    private static func plainList(_ url: URL) async -> [ParsedNode]? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(userAgents.last, forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain, application/json, */*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let result = try? ContentImporter.parse(String(decoding: data, as: UTF8.self)),
              !SubscriptionStub.isStub(result.nodes.map(\.name)) else { return nil }
        return result.nodes
    }
}
