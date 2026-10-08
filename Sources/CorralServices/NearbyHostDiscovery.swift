import CorralContracts
import CorralProtocol
import Darwin
import Foundation
import Network

/// A Corral host found nearby. Everything here is an unauthenticated hint: it becomes a device only
/// after `/pair/identify` proves a route under the user's pairing token.
public struct NearbyHost: Equatable, Sendable, Identifiable {
    public enum Channel: String, Sendable { case bonjour, tailscale }

    public let hostID: String
    public var name: String
    public var port: Int
    /// IPv4 addresses the host reported through whoami, plus the one it was seen at.
    public var addresses: [String]
    public var channels: Set<Channel>
    public var id: String { hostID }

    public init(hostID: String, name: String, port: Int, addresses: [String], channels: Set<Channel>) {
        self.hostID = hostID; self.name = name; self.port = port; self.addresses = addresses; self.channels = channels
    }

    /// Candidate routes in dial order (Tailscale first); unproven until identify succeeds.
    public var routes: [ApprovedEndpoint] {
        ApprovedEndpoint.dialOrder(addresses.compactMap { try? ApprovedEndpoint(host: $0, port: port, pairingHostID: hostID) })
            .filter { $0.route != .loopback }
    }
    public var tailnetAddress: String? { routes.first { $0.route == .tailnet }?.host }
    public var lanAddress: String? { routes.first { $0.route == .lan }?.host }
}

/// Somewhere an agentmirrord may answer: a Bonjour resolution or a Tailscale peer.
public struct NearbyHostSighting: Hashable, Sendable {
    public let host: String
    public let port: Int
    /// The DNS-SD `id`; whoami must report the same host or the sighting is dropped.
    public let advertisedHostID: String?
    public let channel: NearbyHost.Channel

    public init(host: String, port: Int, advertisedHostID: String? = nil, channel: NearbyHost.Channel) {
        self.host = host; self.port = port; self.advertisedHostID = advertisedHostID; self.channel = channel
    }
}

public protocol NearbyHostSource: Sendable {
    func sightings() -> AsyncStream<NearbyHostSighting>
}

/// Merges sightings from every source into hosts keyed by `host_id`, enriched through `/pair/whoami`.
@MainActor
public final class NearbyHostDiscovery {
    public private(set) var hosts: [NearbyHost] = []
    public var onUpdate: (([NearbyHost]) -> Void)?
    private let sources: [any NearbyHostSource]
    private let probe: HostIdentityProbe
    private let excludedAddresses: Set<String>
    private var tasks: [Task<Void, Never>] = []
    private var probed = Set<String>()

    /// Sightings at `excludedAddresses` (this Mac's own) are never probed: its daemon is already the local device.
    public init(
        sources: [any NearbyHostSource] = [BonjourHostSource(), TailscalePeerSource()],
        probe: HostIdentityProbe = HostIdentityProbe(timeout: 2.5),
        excludedAddresses: Set<String> = NearbyHostDiscovery.localIPv4Addresses()
    ) {
        self.sources = sources; self.probe = probe; self.excludedAddresses = excludedAddresses
    }

    public func start() {
        stop()
        hosts = []
        probed = []
        for source in sources {
            let stream = source.sightings()
            tasks.append(Task { [weak self] in
                for await sighting in stream {
                    guard !Task.isCancelled, let self else { return }
                    self.enrich(sighting)
                }
            })
        }
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    private func enrich(_ sighting: NearbyHostSighting) {
        guard !excludedAddresses.contains(sighting.host), probed.insert("\(sighting.host):\(sighting.port)").inserted else { return }
        let probe = probe
        tasks.append(Task { [weak self] in
            guard let identity = try? await probe.whoami(host: sighting.host, port: sighting.port),
                  sighting.advertisedHostID == nil || sighting.advertisedHostID == identity.hostID,
                  !Task.isCancelled else { return }
            self?.merge(identity, seenAt: sighting)
        })
    }

    private func merge(_ identity: AgentMirrorWhoAmIResponse, seenAt sighting: NearbyHostSighting) {
        // Only the sighting decides "this Mac": hosts may share virtual-bridge addresses (192.168.64.1).
        let reported = identity.addresses + [sighting.host]
        if let index = hosts.firstIndex(where: { $0.hostID == identity.hostID }) {
            hosts[index].addresses += reported.filter { !hosts[index].addresses.contains($0) }
            hosts[index].channels.insert(sighting.channel)
        } else {
            var unique: [String] = []
            for address in reported where !unique.contains(address) { unique.append(address) }
            let name = identity.name.trimmingCharacters(in: .whitespacesAndNewlines)
            hosts.append(NearbyHost(hostID: identity.hostID, name: name.isEmpty ? identity.hostID : name,
                                    port: Int(identity.port), addresses: unique, channels: [sighting.channel]))
        }
        hosts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        onUpdate?(hosts)
    }

    public nonisolated static func localIPv4Addresses() -> Set<String> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var addresses = Set<String>()
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let octets = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
            addresses.insert(octets.map(String.init).joined(separator: "."))
        }
        return addresses.subtracting(["127.0.0.1"])
    }
}

/// DNS-SD `_agentmirror._tcp.local.`: each service is resolved to its IPv4 address and port.
public struct BonjourHostSource: NearbyHostSource {
    public static let serviceType = "_agentmirror._tcp"
    /// When set, only these host IDs are resolved (live tests stay off other daemons on the LAN).
    private let hostIDs: Set<String>?

    public init(onlyHostIDs hostIDs: Set<String>? = nil) { self.hostIDs = hostIDs }

    public func sightings() -> AsyncStream<NearbyHostSighting> {
        let hostIDs = hostIDs
        return AsyncStream { continuation in
            let queue = DispatchQueue(label: "corral.discovery.bonjour")
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: "local."), using: NWParameters())
            browser.browseResultsChangedHandler = { _, changes in
                for case let .added(result) in changes {
                    guard case let .service(name, _, _, _) = result.endpoint else { continue }
                    var hostID = name
                    if case let .bonjour(txt) = result.metadata, let id = txt["id"], !id.isEmpty { hostID = id }
                    guard hostIDs?.contains(hostID) ?? true else { continue }
                    Self.resolve(result.endpoint, advertisedHostID: hostID, queue: queue) { continuation.yield($0) }
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { continuation.finish() }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: queue)
        }
    }

    /// The daemon publishes only A records; a short TCP connect reveals the resolved IPv4 and port.
    private static func resolve(_ endpoint: NWEndpoint, advertisedHostID: String, queue: DispatchQueue,
                                found: @escaping @Sendable (NearbyHostSighting) -> Void) {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint, case let .ipv4(address) = host {
                    found(NearbyHostSighting(host: address.rawValue.map(String.init).joined(separator: "."), port: Int(port.rawValue),
                                             advertisedHostID: advertisedHostID, channel: .bonjour))
                }
                connection.cancel()
            case .waiting, .failed:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 4) { connection.cancel() }
    }
}

/// Peers of the user's tailnet, from the Tailscale CLI. Each is a sighting on the daemon
/// port; whoami, not cached Online/OS hints, decides whether a Corral host really answers there.
public struct TailscalePeerSource: NearbyHostSource {
    public struct Peer: Equatable, Sendable {
        public let name: String
        public let address: String
        public init(name: String, address: String) { self.name = name; self.address = address }
    }

    public static let defaultExecutables = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"
    ]
    private let executables: [String]
    private let ports: [Int]

    public init(executables: [String] = Self.defaultExecutables, ports: [Int] = [9900]) {
        self.executables = executables; self.ports = ports
    }

    public func sightings() -> AsyncStream<NearbyHostSighting> {
        let executables = executables, ports = ports
        return AsyncStream { continuation in
            let task = Task.detached {
                for peer in Self.peers(executables: executables) {
                    for port in ports { continuation.yield(NearbyHostSighting(host: peer.address, port: port, channel: .tailscale)) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Every peer with a Tailscale IPv4 is a probe candidate, regardless of Online/OS hints.
    public static func parsePeers(_ status: Data) -> [Peer] {
        guard let object = try? JSONSerialization.jsonObject(with: status) as? [String: Any],
              let peers = object["Peer"] as? [String: [String: Any]] else { return [] }
        return peers.values.compactMap { peer -> Peer? in
            guard let address = (peer["TailscaleIPs"] as? [String])?.first(where: { $0.hasPrefix("100.") && !$0.contains(":") }),
                  (try? ApprovedEndpoint(host: address, port: 9900, pairingHostID: "tailscale-peer"))?.route == .tailnet else { return nil }
            return Peer(name: peer["HostName"] as? String ?? address, address: address)
        }.sorted { $0.address < $1.address }
    }

    private static func peers(executables: [String]) -> [Peer] {
        guard let executable = executables.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["status", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return process.terminationStatus == 0 ? parsePeers(data) : []
    }
}
