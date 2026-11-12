import Foundation

/// Some panels give a client that calls itself Happ a shorter Xray JSON than the
/// plain list of links (servers Happ cannot run left out). The servers only the
/// second answer has are added after the first answer's.
public enum SubscriptionMerge {
    /// Where a server connects: protocol, address and port of every hop it uses.
    static func endpoints(_ node: ParsedNode) -> Set<String> {
        var result = Set<String>()
        for object in [node.outbound] + node.members {
            let type = object["type"]?.stringValue?.lowercased() ?? ""
            if let server = object["server"]?.stringValue?.lowercased(), !server.isEmpty {
                let port = object["server_port"]?.intValue ?? 0
                result.insert("\(type)|\(server)|\(port)")
            }
            for peer in object["peers"]?.arrayValue ?? [] {
                if let address = peer["address"]?.stringValue?.lowercased() {
                    result.insert("\(type)|\(address)|\(peer["port"]?.intValue ?? 0)")
                }
            }
        }
        return result
    }

    /// The servers of `extra` none of whose endpoints `base` already has.
    public static func missing(from extra: [ParsedNode], in base: [ParsedNode]) -> [ParsedNode] {
        var known = Set<String>()
        for node in base { known.formUnion(endpoints(node)) }
        return extra.filter { node in
            let own = endpoints(node)
            return !own.isEmpty && own.isDisjoint(with: known)
        }
    }
}

public extension Library {
    /// Every server address in the library, for hiding them in shared text.
    var serverHosts: Set<String> {
        var hosts = Set<String>()
        for subscription in subscriptions {
            for node in subscription.nodes {
                for object in [node.outbound] + node.members {
                    if let server = object["server"]?.stringValue { hosts.insert(server) }
                    for peer in object["peers"]?.arrayValue ?? [] {
                        if let address = peer["address"]?.stringValue { hosts.insert(address) }
                    }
                }
            }
        }
        return hosts
    }
}
