import Foundation
import Libbox
import Network
import NetworkExtension

/// The platform services the sing-box core asks the extension for: the TUN
/// device, network monitoring and service control.
final class LibboxPlatform: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private unowned let provider: PacketTunnelProvider
    private var networkSettings: NEPacketTunnelNetworkSettings?
    private var pathMonitor: NWPathMonitor?

    init(provider: PacketTunnelProvider) {
        self.provider = provider
    }

    func reset() {
        networkSettings = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    // MARK: TUN

    func openTun(_ options: (any LibboxTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options else { throw platformError("missing TUN options") }
        guard let ret0_ else { throw platformError("missing return pointer") }
        let settings = try makeSettings(options)
        try blocking { [provider] in
            try await provider.setTunnelNetworkSettings(settings)
        }
        networkSettings = settings
        if let descriptor = provider.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = descriptor
            return
        }
        let descriptor = LibboxGetTunnelFileDescriptor()
        guard descriptor != -1 else { throw platformError("missing TUN file descriptor") }
        ret0_.pointee = descriptor
    }

    private func makeSettings(_ options: any LibboxTunOptionsProtocol) throws -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        if options.getAutoRoute() {
            settings.mtu = NSNumber(value: options.getMTU())

            var dnsServers: [String] = []
            let dnsIterator = try options.getDNSServerAddress()
            while dnsIterator.hasNext() {
                dnsServers.append(dnsIterator.next())
            }
            let dns = NEDNSSettings(servers: dnsServers.isEmpty ? ["172.19.0.2"] : dnsServers)
            dns.matchDomains = [""]
            settings.dnsSettings = dns

            var ipv4Addresses: [String] = []
            var ipv4Masks: [String] = []
            if let iterator = options.getInet4Address() {
                while iterator.hasNext() {
                    guard let prefix = iterator.next() else { continue }
                    ipv4Addresses.append(prefix.address())
                    ipv4Masks.append(prefix.mask())
                }
            }
            let ipv4 = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: ipv4Masks)
            var ipv4Routes: [NEIPv4Route] = []
            if let iterator = options.getInet4RouteAddress() {
                while iterator.hasNext() {
                    guard let prefix = iterator.next() else { continue }
                    ipv4Routes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
                }
            }
            if ipv4Routes.isEmpty { ipv4Routes = [NEIPv4Route.default()] }
            var ipv4Excluded: [NEIPv4Route] = []
            if let iterator = options.getInet4RouteExcludeAddress() {
                while iterator.hasNext() {
                    guard let prefix = iterator.next() else { continue }
                    ipv4Excluded.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
                }
            }
            ipv4.includedRoutes = ipv4Routes
            ipv4.excludedRoutes = ipv4Excluded
            settings.ipv4Settings = ipv4

            var ipv6Addresses: [String] = []
            var ipv6Prefixes: [NSNumber] = []
            if let iterator = options.getInet6Address() {
                while iterator.hasNext() {
                    guard let prefix = iterator.next() else { continue }
                    ipv6Addresses.append(prefix.address())
                    ipv6Prefixes.append(NSNumber(value: prefix.prefix()))
                }
            }
            if !ipv6Addresses.isEmpty {
                let ipv6 = NEIPv6Settings(addresses: ipv6Addresses, networkPrefixLengths: ipv6Prefixes)
                var ipv6Routes: [NEIPv6Route] = []
                if let iterator = options.getInet6RouteAddress() {
                    while iterator.hasNext() {
                        guard let prefix = iterator.next() else { continue }
                        ipv6Routes.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
                    }
                }
                if ipv6Routes.isEmpty { ipv6Routes = [NEIPv6Route.default()] }
                var ipv6Excluded: [NEIPv6Route] = []
                if let iterator = options.getInet6RouteExcludeAddress() {
                    while iterator.hasNext() {
                        guard let prefix = iterator.next() else { continue }
                        ipv6Excluded.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
                    }
                }
                ipv6.includedRoutes = ipv6Routes
                ipv6.excludedRoutes = ipv6Excluded
                settings.ipv6Settings = ipv6
            }
        }
        if options.isHTTPProxyEnabled() {
            let proxy = NEProxySettings()
            let server = NEProxyServer(address: options.getHTTPProxyServer(), port: Int(options.getHTTPProxyServerPort()))
            proxy.httpServer = server
            proxy.httpsServer = server
            proxy.httpEnabled = true
            proxy.httpsEnabled = true
            var bypass: [String] = []
            if let iterator = options.getHTTPProxyBypassDomain() {
                while iterator.hasNext() {
                    bypass.append(iterator.next())
                }
            }
            if !bypass.isEmpty { proxy.exceptionList = bypass }
            var match: [String] = []
            if let iterator = options.getHTTPProxyMatchDomain() {
                while iterator.hasNext() {
                    match.append(iterator.next())
                }
            }
            if !match.isEmpty { proxy.matchDomains = match }
            settings.proxySettings = proxy
        }
        return settings
    }

    func clearDNSCache() {
        guard let networkSettings else { return }
        try? blocking { [provider] in
            provider.reasserting = true
            defer { provider.reasserting = false }
            try await provider.setTunnelNetworkSettings(nil)
            try await provider.setTunnelNetworkSettings(networkSettings)
        }
    }

    // MARK: Network monitoring

    func startDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {
        guard let listener else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        let firstUpdate = DispatchSemaphore(value: 0)
        let once = OnceFlag()
        monitor.pathUpdateHandler = { path in
            LibboxPlatform.report(path, to: listener)
            if once.claim() { firstUpdate.signal() }
        }
        monitor.start(queue: DispatchQueue(label: "personaltunnel.path-monitor"))
        _ = firstUpdate.wait(timeout: .now() + 5)
    }

    private static func report(_ path: Network.NWPath, to listener: any LibboxInterfaceUpdateListenerProtocol) {
        guard path.status != .unsatisfied, let interface = path.availableInterfaces.first else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(interface.name, interfaceIndex: Int32(interface.index), isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }

    func closeDefaultInterfaceMonitor(_: (any LibboxInterfaceUpdateListenerProtocol)?) throws {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    func getInterfaces() throws -> any LibboxNetworkInterfaceIteratorProtocol {
        guard let pathMonitor else { throw platformError("path monitor is not running") }
        let path = pathMonitor.currentPath
        guard path.status != .unsatisfied else { return InterfaceIterator([]) }
        let interfaces: [LibboxNetworkInterface] = path.availableInterfaces.map { item in
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
        }
        return InterfaceIterator(interfaces)
    }

    final class InterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        private var items: [LibboxNetworkInterface]
        private var current: LibboxNetworkInterface?

        init(_ items: [LibboxNetworkInterface]) {
            self.items = items
        }

        func hasNext() -> Bool {
            guard !items.isEmpty else {
                current = nil
                return false
            }
            current = items.removeFirst()
            return true
        }

        func next() -> LibboxNetworkInterface? {
            current
        }
    }

    func underNetworkExtension() -> Bool { true }

    func includeAllNetworks() -> Bool {
        (provider.protocolConfiguration as? NETunnelProviderProtocol)?.includeAllNetworks ?? false
    }

    func usePlatformAutoDetectControl() -> Bool { false }

    func autoDetectControl(_: Int32) throws {}

    func useProcFS() -> Bool { false }

    func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32, destinationAddress _: String?, destinationPort _: Int32) throws -> LibboxConnectionOwner {
        throw platformError("connection owner lookup is not available on iOS")
    }

    func readWIFIState() -> LibboxWIFIState? { nil }

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }

    // MARK: Notifications (unused)

    func send(_: LibboxNotification?) throws {}

    func cancelNotification(_: String?, typeID _: Int32) throws {}

    // MARK: Features this client does not use

    func startNeighborMonitor(_: (any LibboxNeighborUpdateListenerProtocol)?) throws {}

    func closeNeighborMonitor(_: (any LibboxNeighborUpdateListenerProtocol)?) throws {}

    func registerMyInterface(_: String?) {}

    func usePlatformShell() -> Bool { false }

    func checkPlatformShell() throws {
        throw platformError("shell is not available")
    }

    func openShellSession(_: LibboxPlatformUser?, command _: String?, environ _: (any LibboxStringIteratorProtocol)?, term _: String?, rows _: Int32, cols _: Int32) throws -> any LibboxShellSessionProtocol {
        throw platformError("shell is not available")
    }

    func lookupUser(_: String?) throws -> LibboxPlatformUser {
        throw platformError("users are not available")
    }

    func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        error?.pointee = platformError("SFTP is not available")
        return ""
    }

    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        error?.pointee = platformError("SSH is not available")
        return ""
    }

    func tailscaleHostname() -> String { "" }

    func usePlatformBridge() -> Bool { false }

    func createBridge(_: LibboxBridgeOptions?) throws -> any LibboxBridgeSessionProtocol {
        throw platformError("bridges are not available")
    }

    // MARK: Command server handler

    func serviceStop() throws {
        provider.stopService()
    }

    func serviceReload() throws {
        try provider.reloadService()
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        let status = LibboxSystemProxyStatus()
        if let proxy = networkSettings?.proxySettings, proxy.httpServer != nil {
            status.available = true
            status.enabled = proxy.httpEnabled
        }
        return status
    }

    func setSystemProxyEnabled(_ isEnabled: Bool) throws {
        guard let networkSettings, let proxy = networkSettings.proxySettings, proxy.httpServer != nil, proxy.httpEnabled != isEnabled else { return }
        proxy.httpEnabled = isEnabled
        proxy.httpsEnabled = isEnabled
        networkSettings.proxySettings = proxy
        try blocking { [provider] in
            try await provider.setTunnelNetworkSettings(networkSettings)
        }
    }

    func triggerNativeCrash() throws {
        throw platformError("not available")
    }

    func writeDebugMessage(_ message: String?) {
        guard let message else { return }
        provider.writeLog(message)
    }

    func connectSSHAgent(_: UnsafeMutablePointer<Int32>?) throws {
        throw platformError("SSH agent is not available")
    }

    // MARK: Helpers

    private func platformError(_ message: String) -> NSError {
        NSError(domain: "PersonalTunnel.Platform", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Runs async work from a synchronous core callback (a Go thread).
    private func blocking(_ work: @escaping @Sendable () async throws -> Void) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ErrorBox()
        Task.detached {
            do {
                try await work()
            } catch {
                box.error = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = box.error { throw error }
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
