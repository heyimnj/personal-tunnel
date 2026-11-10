import Foundation
import Libbox
import Network
import NetworkExtension

/// What the sing-box core asks the extension for: the TUN device, the state of
/// the physical network and control of the service.
final class TunnelPlatform: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private unowned let provider: PacketTunnelProvider
    private let lock = NSLock()
    private var appliedSettings: NEPacketTunnelNetworkSettings?
    private var pathMonitor: NWPathMonitor?

    init(provider: PacketTunnelProvider) {
        self.provider = provider
    }

    func reset() {
        lock.lock()
        appliedSettings = nil
        let monitor = pathMonitor
        pathMonitor = nil
        lock.unlock()
        monitor?.cancel()
    }

    // MARK: TUN

    func openTun(_ options: (any LibboxTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options, let ret0_ else { throw failure("ядро не передало параметры TUN") }
        let settings = try networkSettings(from: options)
        try apply(settings)
        lock.lock()
        appliedSettings = settings
        lock.unlock()
        if let descriptor = provider.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = descriptor
            return
        }
        let descriptor = LibboxGetTunnelFileDescriptor()
        guard descriptor != -1 else { throw failure("не найден файловый дескриптор TUN") }
        ret0_.pointee = descriptor
    }

    /// Applies settings from a core thread and waits for the system to accept them.
    private func apply(_ settings: NEPacketTunnelNetworkSettings?) throws {
        let done = DispatchSemaphore(value: 0)
        let result = ErrorBox()
        provider.setTunnelNetworkSettings(settings) { error in
            result.error = error
            done.signal()
        }
        if done.wait(timeout: .now() + 20) == .timedOut { throw failure("система не применила настройки туннеля за 20 с") }
        if let error = result.error { throw error }
    }

    /// Drains a core iterator without naming its generated protocol type.
    private func drain<Element>(hasNext: () -> Bool, next: () -> Element?) -> [Element] {
        var result: [Element] = []
        while hasNext() {
            if let element = next() { result.append(element) }
        }
        return result
    }

    private func strings(_ iterator: (any LibboxStringIteratorProtocol)?) -> [String] {
        var result: [String] = []
        guard let iterator else { return result }
        while iterator.hasNext() { result.append(iterator.next()) }
        return result
    }

    private func networkSettings(from options: any LibboxTunOptionsProtocol) throws -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        if options.getAutoRoute() {
            settings.mtu = NSNumber(value: options.getMTU())

            var servers = strings(try options.getDNSServerAddress())
            if servers.isEmpty { servers = ["172.19.0.2"] }
            let dns = NEDNSSettings(servers: servers)

            let v4Source = options.getInet4Address()
            let v4 = drain(hasNext: { v4Source?.hasNext() ?? false }, next: { v4Source?.next() })
            let ipv4 = NEIPv4Settings(addresses: v4.map { $0.address() }, subnetMasks: v4.map { $0.mask() })
            let v4RouteSource = options.getInet4RouteAddress()
            var v4Routes = drain(hasNext: { v4RouteSource?.hasNext() ?? false }, next: { v4RouteSource?.next() }).map {
                NEIPv4Route(destinationAddress: $0.address(), subnetMask: $0.mask())
            }
            if v4Routes.isEmpty { v4Routes = [NEIPv4Route.default()] }
            ipv4.includedRoutes = v4Routes
            let v4ExcludeSource = options.getInet4RouteExcludeAddress()
            ipv4.excludedRoutes = drain(hasNext: { v4ExcludeSource?.hasNext() ?? false }, next: { v4ExcludeSource?.next() }).map {
                NEIPv4Route(destinationAddress: $0.address(), subnetMask: $0.mask())
            }
            settings.ipv4Settings = ipv4

            let v6Source = options.getInet6Address()
            let v6 = drain(hasNext: { v6Source?.hasNext() ?? false }, next: { v6Source?.next() })
            if !v6.isEmpty {
                let ipv6 = NEIPv6Settings(addresses: v6.map { $0.address() }, networkPrefixLengths: v6.map { NSNumber(value: $0.prefix()) })
                let v6RouteSource = options.getInet6RouteAddress()
                var v6Routes = drain(hasNext: { v6RouteSource?.hasNext() ?? false }, next: { v6RouteSource?.next() }).map {
                    NEIPv6Route(destinationAddress: $0.address(), networkPrefixLength: NSNumber(value: $0.prefix()))
                }
                if v6Routes.isEmpty { v6Routes = [NEIPv6Route.default()] }
                ipv6.includedRoutes = v6Routes
                let v6ExcludeSource = options.getInet6RouteExcludeAddress()
                ipv6.excludedRoutes = drain(hasNext: { v6ExcludeSource?.hasNext() ?? false }, next: { v6ExcludeSource?.next() }).map {
                    NEIPv6Route(destinationAddress: $0.address(), networkPrefixLength: NSNumber(value: $0.prefix()))
                }
                settings.ipv6Settings = ipv6
            }

            // Without a default route the tunnel must still receive every DNS query.
            let hasDefaultRoute = v4Routes.contains { $0.destinationAddress == "0.0.0.0" && $0.destinationSubnetMask == "0.0.0.0" }
            if !hasDefaultRoute {
                dns.matchDomains = [""]
                dns.matchDomainsNoSearch = true
            }
            settings.dnsSettings = dns
        }
        if options.isHTTPProxyEnabled() {
            let proxy = NEProxySettings()
            let server = NEProxyServer(address: options.getHTTPProxyServer(), port: Int(options.getHTTPProxyServerPort()))
            proxy.httpServer = server
            proxy.httpsServer = server
            proxy.httpEnabled = true
            proxy.httpsEnabled = true
            let bypass = strings(options.getHTTPProxyBypassDomain())
            if !bypass.isEmpty { proxy.exceptionList = bypass }
            let match = strings(options.getHTTPProxyMatchDomain())
            if !match.isEmpty { proxy.matchDomains = match }
            settings.proxySettings = proxy
        }
        return settings
    }

    func clearDNSCache() {
        lock.lock()
        let settings = appliedSettings
        lock.unlock()
        guard let settings else { return }
        // Re-applying the settings makes the system drop its resolver cache.
        provider.reasserting = true
        try? apply(nil)
        try? apply(settings)
        provider.reasserting = false
    }

    // MARK: Physical network

    func startDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {
        guard let listener else { return }
        let monitor = NWPathMonitor()
        lock.lock()
        pathMonitor = monitor
        lock.unlock()
        let first = DispatchSemaphore(value: 0)
        let once = OnceFlag()
        monitor.pathUpdateHandler = { path in
            TunnelPlatform.report(path, to: listener)
            if once.claim() { first.signal() }
        }
        monitor.start(queue: DispatchQueue(label: "personaltunnel.path", qos: .utility))
        // The core needs the first answer before it dials anything.
        _ = first.wait(timeout: .now() + 5)
    }

    private static func report(_ path: Network.NWPath, to listener: any LibboxInterfaceUpdateListenerProtocol) {
        guard path.status != .unsatisfied, let interface = path.availableInterfaces.first else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(interface.name, interfaceIndex: Int32(interface.index),
                                        isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }

    func closeDefaultInterfaceMonitor(_: (any LibboxInterfaceUpdateListenerProtocol)?) throws {
        lock.lock()
        let monitor = pathMonitor
        pathMonitor = nil
        lock.unlock()
        monitor?.cancel()
    }

    func getInterfaces() throws -> any LibboxNetworkInterfaceIteratorProtocol {
        lock.lock()
        let monitor = pathMonitor
        lock.unlock()
        guard let monitor else { throw failure("монитор сети не запущен") }
        let path = monitor.currentPath
        guard path.status != .unsatisfied else { return InterfaceList([]) }
        return InterfaceList(path.availableInterfaces.map { item in
            let interface = LibboxNetworkInterface()
            interface.name = item.name
            interface.index = Int32(item.index)
            switch item.type {
            case .wifi: interface.type = LibboxInterfaceTypeWIFI
            case .cellular: interface.type = LibboxInterfaceTypeCellular
            case .wiredEthernet: interface.type = LibboxInterfaceTypeEthernet
            default: interface.type = LibboxInterfaceTypeOther
            }
            return interface
        })
    }

    private final class InterfaceList: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        private var remaining: [LibboxNetworkInterface]
        private var current: LibboxNetworkInterface?

        init(_ items: [LibboxNetworkInterface]) {
            remaining = items
        }

        func hasNext() -> Bool {
            guard !remaining.isEmpty else {
                current = nil
                return false
            }
            current = remaining.removeFirst()
            return true
        }

        func next() -> LibboxNetworkInterface? { current }
    }

    func underNetworkExtension() -> Bool { true }

    func includeAllNetworks() -> Bool {
        (provider.protocolConfiguration as? NETunnelProviderProtocol)?.includeAllNetworks ?? false
    }

    func usePlatformAutoDetectControl() -> Bool { false }

    func autoDetectControl(_: Int32) throws {}

    func useProcFS() -> Bool { false }

    func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32, destinationAddress _: String?,
                             destinationPort _: Int32) throws -> LibboxConnectionOwner
    {
        throw failure("владелец соединения на iOS недоступен")
    }

    func readWIFIState() -> LibboxWIFIState? { nil }

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }

    // MARK: Things this client does not use

    func send(_: LibboxNotification?) throws {}

    func cancelNotification(_: String?, typeID _: Int32) throws {}

    func startNeighborMonitor(_: (any LibboxNeighborUpdateListenerProtocol)?) throws {}

    func closeNeighborMonitor(_: (any LibboxNeighborUpdateListenerProtocol)?) throws {}

    func registerMyInterface(_: String?) {}

    func usePlatformShell() -> Bool { false }

    func checkPlatformShell() throws {
        throw failure("оболочка недоступна")
    }

    func openShellSession(_: LibboxPlatformUser?, command _: String?, environ _: (any LibboxStringIteratorProtocol)?,
                          term _: String?, rows _: Int32, cols _: Int32) throws -> any LibboxShellSessionProtocol
    {
        throw failure("оболочка недоступна")
    }

    func lookupUser(_: String?) throws -> LibboxPlatformUser {
        throw failure("пользователи недоступны")
    }

    func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        error?.pointee = failure("SFTP недоступен")
        return ""
    }

    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        error?.pointee = failure("SSH недоступен")
        return ""
    }

    func tailscaleHostname() -> String { "" }

    func usePlatformBridge() -> Bool { false }

    func createBridge(_: LibboxBridgeOptions?) throws -> any LibboxBridgeSessionProtocol {
        throw failure("мосты недоступны")
    }

    // MARK: Service control from the command channel

    func serviceStop() throws {
        provider.closeService()
    }

    func serviceReload() throws {
        try provider.reload()
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        LibboxSystemProxyStatus()
    }

    func setSystemProxyEnabled(_: Bool) throws {}

    func triggerNativeCrash() throws {
        throw failure("недоступно")
    }

    func writeDebugMessage(_ message: String?) {
        if let message { provider.log(message) }
    }

    func connectSSHAgent(_: UnsafeMutablePointer<Int32>?) throws {
        throw failure("SSH-агент недоступен")
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "PersonalTunnel.Platform", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class ErrorBox: @unchecked Sendable {
    var error: Error?
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// `true` the first time only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
