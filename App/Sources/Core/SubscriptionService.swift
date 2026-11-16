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

    /// 3.3 (PT-13): the device data a panel gets: the HWID (`hwid`: the
    /// subscription's own, see `Subscription.hwid(device:)`), model, iOS version
    /// and language. The last two go only when a panel gave no servers without them.
    static func device(hwid: String) -> SubscriptionRequest.Device {
        SubscriptionRequest.Device(hwid: hwid, model: DeviceIdentity.model, osVersion: UIDevice.current.systemVersion, locale: Locale.current.identifier)
    }

    /// Panels pick the answer by the client's name: Incy gets the full Xray JSON
    /// (Hysteria servers included, which some panels leave out for Happ), Happ the
    /// next, a plain client the list of links. A panel's "unsupported client" stub
    /// (or no servers, or an error code) moves on to the next try
    /// (`SubscriptionRequest.attempts`). `device`: nil sends no device data.
    static func fetch(url text: String, device: SubscriptionRequest.Device?) async throws -> Fetched {
        let url = try SubscriptionRequest.address(text)
        var lastError: Error = ImportError(L("Подписка не загрузилась."))
        // 3.3 beta 4: a session of its own: no connection kept from before the VPN
        // came up or restarted (a launch after an update timed out on one).
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        for attempt in SubscriptionRequest.attempts(device: device) {
            let agent = attempt.agent
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/plain, application/json, */*", forHTTPHeaderField: "Accept")
            for (key, value) in attempt.headers { request.setValue(value, forHTTPHeaderField: key) }
            do {
                let (data, response) = try await session.data(for: request, delegate: RedirectGuard())
                guard let http = response as? HTTPURLResponse else { throw ImportError(L("Сервер подписки не ответил.")) }
                if (300 ..< 400).contains(http.statusCode) {
                    // RedirectGuard refused it: from https to http.
                    throw RedirectGuard.Refused()
                }
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
                if result.format == .xray, agent != SubscriptionRequest.plainAgent, let plain = await plainList(url, session: session) {
                    let extra = SubscriptionMerge.missing(from: plain, in: nodes)
                    nodes += extra
                    added = extra.count
                }
                return Fetched(nodes: NodeAssembler.assemble(nodes), title: title, info: info, summary: result.summary,
                               format: result.format.rawValue, agent: agent, issues: result.issues, added: added)
            } catch let error as RedirectGuard.Refused {
                throw error
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

    /// 3.3 (PT-13): a redirect to plain http is not followed; one to another host
    /// loses the device headers.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        struct Refused: LocalizedError {
            var errorDescription: String? { L("Сервер подписки перенаправил на незащищённый адрес http://: загрузка остановлена.") }
        }

        func urlSession(_: URLSession, task: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void)
        {
            guard let from = task.originalRequest?.url ?? task.currentRequest?.url, let to = request.url else {
                completionHandler(nil)
                return
            }
            var headers: [String: String] = [:]
            for (key, value) in request.allHTTPHeaderFields ?? [:] { headers[key] = value }
            guard let allowed = SubscriptionRequest.redirected(headers, from: from, to: to) else {
                completionHandler(nil)
                return
            }
            var next = request
            next.allHTTPHeaderFields = allowed
            completionHandler(next)
        }
    }

    /// The same subscription as a plain client sees it (no Happ identity): some
    /// panels leave servers out of the Xray JSON they give Happ.
    private static func plainList(_ url: URL, session: URLSession) async -> [ParsedNode]? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(SubscriptionRequest.plainAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain, application/json, */*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request, delegate: RedirectGuard()),
              let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let result = try? ContentImporter.parse(String(decoding: data, as: UTF8.self)),
              !SubscriptionStub.isStub(result.nodes.map(\.name)) else { return nil }
        return result.nodes
    }
}
