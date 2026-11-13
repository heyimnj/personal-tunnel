import Foundation

/// sing-box JSON → servers. Used for files the user adds and for the
/// configurations 1.x stored, which are sing-box documents built around a
/// `proxy` selector.
public enum SingBoxImport {
    static let groupTypes: Set<String> = ["selector", "urltest"]
    static let plumbingTypes: Set<String> = ["direct", "block", "dns", "bypass"]

    public static func isSingBox(_ document: JSONValue) -> Bool {
        let items = (document["outbounds"]?.arrayValue ?? []) + (document["endpoints"]?.arrayValue ?? [])
        return items.contains { $0["type"]?.stringValue != nil }
    }

    public static func parse(_ document: JSONValue) -> [ParsedNode] {
        let items = (document["outbounds"]?.arrayValue ?? []) + (document["endpoints"]?.arrayValue ?? [])
        var byTag: [String: JSONValue] = [:]
        var order: [String] = []
        for item in items {
            guard let tag = item["tag"]?.stringValue, !tag.isEmpty, let type = item["type"]?.stringValue else { continue }
            if plumbingTypes.contains(type.lowercased()) { continue }
            if byTag[tag] == nil { order.append(tag) }
            byTag[tag] = item
        }
        func isGroup(_ tag: String) -> Bool {
            groupTypes.contains(byTag[tag]?["type"]?.stringValue?.lowercased() ?? "")
        }

        // The servers are the members of the root selector when there is one
        // (the app's own layout), otherwise every leaf in file order.
        var heads: [String]
        if let root = byTag["proxy"], isGroup("proxy") {
            heads = (root["outbounds"]?.stringList ?? []).filter { $0 != "auto" && byTag[$0] != nil }
        } else {
            heads = order.filter { !isGroup($0) }
        }

        var result: [ParsedNode] = []
        for head in heads {
            guard var main = byTag[head] else { continue }
            // Collect what the head needs: group members and detours, recursively.
            var needed: [String] = []
            var queue = dependencies(of: main)
            while let next = queue.first {
                queue.removeFirst()
                guard next != head, !needed.contains(next), let object = byTag[next] else { continue }
                needed.append(next)
                queue.append(contentsOf: dependencies(of: object))
            }
            if isGroup(head) {
                // A group whose members are all gone cannot be used.
                let members = (main["outbounds"]?.stringList ?? []).filter { byTag[$0] != nil }
                guard !members.isEmpty else { continue }
                main["outbounds"] = JSONValue(members)
            }
            main["tag"] = nil
            result.append(ParsedNode(name: head, outbound: main, members: needed.compactMap { byTag[$0] }))
        }
        return result
    }

    private static func dependencies(of object: JSONValue) -> [String] {
        var result = object["outbounds"]?.stringList ?? []
        if let detour = object["detour"]?.stringValue, !detour.isEmpty { result.append(detour) }
        return result
    }
}

/// Gives parsed servers their final, collision-free outbound tags.
public enum NodeAssembler {
    public static func assemble(_ parsed: [ParsedNode]) -> [ServerNode] {
        var allocator = TagAllocator()
        var result: [ServerNode] = []
        for item in parsed {
            let tag = allocator.make(item.name)
            var rename: [String: String] = [:]
            for (offset, member) in item.members.enumerated() {
                guard let old = member["tag"]?.stringValue else { continue }
                rename[old] = allocator.make("\(tag) · \(offset + 1)")
            }
            func relink(_ object: JSONValue) -> JSONValue {
                var object = object
                if let members = object["outbounds"]?.stringList, !members.isEmpty {
                    object["outbounds"] = JSONValue(members.map { rename[$0] ?? $0 })
                }
                if let detour = object["detour"]?.stringValue { object["detour"] = .string(rename[detour] ?? detour) }
                return object
            }
            var main = relink(item.outbound)
            main["tag"] = .string(tag)
            let members = item.members.map { member -> JSONValue in
                var member = relink(member)
                if let old = member["tag"]?.stringValue, let new = rename[old] { member["tag"] = .string(new) }
                return member
            }
            result.append(ServerNode(id: tag, name: item.name, outbound: main, members: members, link: item.link))
        }
        return result
    }
}

public struct ImportResult: Equatable {
    public enum Format: String, Equatable {
        case links = "ссылки"
        case xray = "Xray JSON"
        case singBox = "sing-box JSON"
    }

    public var nodes: [ParsedNode]
    public var issues: [ImportIssue]
    public var format: Format
    /// A name the content suggests for the subscription (sing-box/Xray files have none).
    public var suggestedName: String?

    public var summary: String? {
        guard !issues.isEmpty else { return nil }
        let reasons = Array(Set(issues.map(\.reason))).sorted().prefix(3).joined(separator: " ")
        return CoreText.f("Добавлено %@ из %@. Пропущено: %@. %@", "\(nodes.count)", "\(nodes.count + issues.count)", "\(issues.count)", "\(reasons)")
    }
}

/// Works out what a pasted text, a file or a subscription response contains
/// and turns it into servers.
public enum ContentImporter {
    public static func parse(_ raw: String) throws -> ImportResult {
        try parse(raw, depth: 0)
    }

    private static func parse(_ raw: String, depth: Int) throws -> ImportResult {
        let text = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard !text.isEmpty else { throw ImportError(CoreText.t("Пустой ответ: серверов нет.")) }

        if text.hasPrefix("{") || text.hasPrefix("[") {
            let document: JSONValue
            do {
                document = try JSONValue.parse(text)
            } catch {
                throw ImportError(CoreText.f("Файл похож на JSON, но прочитать его не удалось: %@", "\(error)"))
            }
            if XrayImport.isXray(document) {
                let (nodes, issues) = XrayImport.parse(document)
                return try finish(ImportResult(nodes: nodes, issues: issues, format: .xray, suggestedName: nil))
            }
            if SingBoxImport.isSingBox(document) {
                return try finish(ImportResult(nodes: SingBoxImport.parse(document), issues: [], format: .singBox, suggestedName: nil))
            }
            throw ImportError(CoreText.t("В JSON нет серверов: это не конфигурация Xray или sing-box."))
        }

        let lower = text.prefix(400).lowercased()
        if lower.hasPrefix("<!doctype") || lower.hasPrefix("<html") || lower.contains("<head>") {
            throw ImportError(CoreText.t("Провайдер вернул веб-страницу вместо подписки. Проверьте ссылку."))
        }
        if lower.contains("proxies:") || lower.contains("proxy-groups:") {
            throw ImportError(CoreText.t("Это конфигурация Clash (YAML). В этой версии она не поддерживается: используйте ссылку подписки или ссылки серверов."))
        }
        if lower.contains("[interface]"), lower.contains("privatekey") {
            throw ImportError(CoreText.t("Это файл WireGuard (.conf). В этой версии он не поддерживается: добавьте сервер ссылкой wireguard://."))
        }

        if text.contains("://") {
            var nodes: [ParsedNode] = []
            var issues: [ImportIssue] = []
            for line in text.split(whereSeparator: \.isNewline) {
                let link = line.trimmingCharacters(in: .whitespaces)
                guard !link.isEmpty, !link.hasPrefix("#"), !link.hasPrefix("//") else { continue }
                guard ShareLink.isLink(link) else {
                    if link.contains("://"), !link.lowercased().hasPrefix("http") {
                        let scheme = link.components(separatedBy: "://").first ?? ""
                        issues.append(ImportIssue(name: String(link.prefix(24)), reason: CoreText.f("Ссылки «%@://» не поддерживаются.", "\(scheme)")))
                    }
                    continue
                }
                do {
                    nodes.append(try ShareLink.parse(link))
                } catch {
                    let title = LinkParts(link)?.fragment ?? ""
                    issues.append(ImportIssue(name: title.isEmpty ? String(link.prefix(24)) + "…" : title,
                                              reason: (error as? ImportError)?.message ?? error.localizedDescription))
                }
            }
            if !nodes.isEmpty || !issues.isEmpty {
                return try finish(ImportResult(nodes: nodes, issues: issues, format: .links, suggestedName: nodes.count == 1 ? nodes[0].name : nil))
            }
        }

        if depth == 0, let decoded = TextCoding.decodeBase64String(text), !decoded.isEmpty {
            return try parse(decoded, depth: 1)
        }
        throw ImportError(CoreText.t("Не удалось распознать содержимое: это не ссылки серверов, не подписка и не JSON."))
    }

    /// Words panels put into the names of fake servers that carry a message.
    private static let placeholderWords = [
        "hwid", "device", "устройств", "limit", "лимит", "expired", "истек", "истёк", "not supported", "не поддерж",
        "update", "обнов", "app", "приложени", "subscription", "подписк",
    ]

    private static func finish(_ result: ImportResult) throws -> ImportResult {
        guard !result.nodes.isEmpty else {
            if let issue = result.issues.first {
                throw ImportError(result.issues.count == 1 ? issue.reason : CoreText.f("Ни один сервер не подошёл. %@", "\(issue.reason)"))
            }
            throw ImportError(CoreText.t("В содержимом нет серверов."))
        }
        // Panels answer an unknown or over-limit device with servers that point
        // nowhere and whose names are the message.
        let fake = result.nodes.filter { node in
            let host = node.outbound["server"]?.stringValue?.lowercased() ?? ""
            let port = node.outbound["server_port"]?.intValue ?? 0
            return ["0.0.0.0", "127.0.0.1", "localhost"].contains(host) || port <= 1
        }
        if fake.count == result.nodes.count, result.nodes.count <= 5 {
            let message = result.nodes.map(\.name).joined(separator: " · ")
            let mentionsReason = placeholderWords.contains { message.lowercased().contains($0) }
            if mentionsReason || result.nodes.allSatisfy({ ["0.0.0.0", "127.0.0.1", "localhost"].contains($0.outbound["server"]?.stringValue?.lowercased() ?? "") }) {
                throw ImportError(CoreText.f("Провайдер вернул сообщение вместо серверов: «%@». Проверьте лимит устройств и срок подписки.", "\(message)"))
            }
        }
        return result
    }
}
