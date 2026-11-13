import Foundation
import Network
import Darwin

struct LocalEndpoint {
    var host: String
    var port: UInt16
    var alternatives: [String] = []
    var candidates: [String] {
        var seen = Set<String>()
        return ([host] + alternatives).filter { seen.insert($0).inserted }.prefix(8).map { $0 }
    }
}

final class LocalNetwork: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var changed: (([NearbyPeer]) -> Void)?
    var status: ((String) -> Void)?
    var incoming: ((SignedEnvelope, @escaping (SignedEnvelope) -> Void) -> Void)?
    private var listener: NWListener?
    private var published: NetService?
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var peers: [ObjectIdentifier: NearbyPeer] = [:]
    private var connections: [UUID: NWConnection] = [:]
    private var timeouts: [UUID: DispatchWorkItem] = [:]
    private var advertised: SignedEnvelope?
    private var ownID = ""
    private var preferredHosts: [String: String] = [:]

    func start(invite: SignedEnvelope, ownID: String) {
        guard listener == nil else { update(invite: invite); return }
        self.ownID = ownID; advertised = invite
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener?.port else { return }
                    let service = NetService(domain: "local.", type: "_soundbound._tcp.", name: String(ownID.prefix(12)), port: Int32(port.rawValue))
                    service.includesPeerToPeer = true
                    self.published = service
                    self.update(invite: invite)
                    service.publish()
                    self.browser.includesPeerToPeer = true
                    self.browser.delegate = self
                    self.browser.searchForServices(ofType: "_soundbound._tcp.", inDomain: "local.")
                    self.status?("Discoverable on this local network")
                case .failed:
                    self.status?("Local discovery could not start. Check local network permission.")
                    self.stop()
                default: break
                }
            }
            listener.start(queue: .main)
        } catch { status?("Local discovery could not start.") }
    }
    func update(invite: SignedEnvelope) {
        advertised = invite
        let bytes = Array(invite.link.utf8)
        var dict: [String: Data] = [:]
        for i in stride(from: 0, to: bytes.count, by: 200) {
            dict["i\(i / 200)"] = Data(bytes[i..<min(i + 200, bytes.count)])
        }
        published?.setTXTRecord(NetService.data(fromTXTRecord: dict))
    }
    func stop() {
        browser.stop(); listener?.cancel(); listener = nil
        published?.stop(); published = nil
        services.forEach { $0.stop() }; services = []; peers = [:]
        for c in connections.values { c.cancel() }; connections = [:]
        for t in timeouts.values { t.cancel() }; timeouts = [:]
        changed?([])
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.includesPeerToPeer = true
        service.delegate = self; services.append(service); service.resolve(withTimeout: 8)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        peers.removeValue(forKey: ObjectIdentifier(service)); services.removeAll { $0 == service }; emit()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        status?("Nearby discovery is unavailable. Allow local network access in Settings.")
    }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        status?("Could not advertise Soundbound. Check local network permission.")
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        sender.startMonitoring(); read(sender)
    }
    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) { read(sender) }
    private func read(_ service: NetService) {
        guard let txt = service.txtRecordData(), let host = service.hostName, service.port > 0 else { return }
        let fields = NetService.dictionary(fromTXTRecord: txt)
        var data = Data()
        for i in 0..<16 {
            guard let chunk = fields["i\(i)"] else { break }; data.append(chunk)
        }
        guard let link = String(data: data, encoding: .utf8), let (_, invite) = try? SignedEnvelope.from(link: link), invite.peer.id != ownID else { return }
        let addresses = (service.addresses ?? []).compactMap(Self.numericHost)
        let preferred = preferredHosts[invite.peer.id].flatMap { addresses.contains($0) || $0 == host ? $0 : nil } ?? host
        peers[ObjectIdentifier(service)] = NearbyPeer(invitation: invite, link: link,
            endpoint: LocalEndpoint(host: preferred, port: UInt16(service.port), alternatives: [host] + addresses))
        emit()
    }
    static func numericHost(_ data: Data) -> String? {
        data.withUnsafeBytes { bytes in
            guard bytes.count >= MemoryLayout<sockaddr>.size, let base = bytes.baseAddress else { return nil }
            let address = base.assumingMemoryBound(to: sockaddr.self)
            let family = Int32(address.pointee.sa_family)
            guard (family == AF_INET && bytes.count >= MemoryLayout<sockaddr_in>.size) ||
                  (family == AF_INET6 && bytes.count >= MemoryLayout<sockaddr_in6>.size) else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(bytes.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return String(cString: host)
        }
    }
    func preferEndpoint(_ host: String, for peerID: String) {
        guard peers.values.contains(where: { $0.id == peerID && $0.endpoint.candidates.contains(host) }) else { return }
        preferredHosts[peerID] = host
        for key in Array(peers.keys) where peers[key]?.id == peerID {
            guard var peer = peers[key], peer.endpoint.candidates.contains(host) else { continue }
            peer.endpoint.alternatives = peer.endpoint.candidates
            peer.endpoint.host = host
            peers[key] = peer
        }
        emit()
    }

    /// Forget the address a device was pinned to (usually the fastest one measured) and go back to its network
    /// name, which the system resolves to whichever interface still works. Called when a connection to the device
    /// dies, so pulling a cable falls back to Wi-Fi instead of retrying the dead address.
    func clearPreference(for peerID: String) {
        guard preferredHosts.removeValue(forKey: peerID) != nil || peers.values.contains(where: { $0.id == peerID }) else { return }
        var changedAny = false
        for key in Array(peers.keys) where peers[key]?.id == peerID {
            guard var peer = peers[key] else { continue }
            let named = peer.endpoint.candidates.first { $0.hasSuffix(".local") || $0.hasSuffix(".local.") } ?? peer.endpoint.host
            guard named != peer.endpoint.host else { continue }
            peer.endpoint.alternatives = peer.endpoint.candidates
            peer.endpoint.host = named
            peers[key] = peer; changedAny = true
        }
        if changedAny { emit() }
    }

    private func emit() { changed?(Array(peers.values).sorted { $0.invitation.peer.name < $1.invitation.peer.name }) }

    private func keep(_ connection: NWConnection, timeout seconds: TimeInterval = 120) -> UUID {
        let id = UUID(); connections[id] = connection
        let timeout = DispatchWorkItem { [weak self] in self?.finish(id) }
        timeouts[id] = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timeout)
        return id
    }
    private func finish(_ id: UUID) {
        timeouts.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
    private func readEnvelope(_ connection: NWConnection, data: Data = Data(), completion: @escaping (Result<SignedEnvelope, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, done, error in
            var combined = data; if let chunk { combined.append(chunk) }
            if combined.count > 65_536 { completion(.failure(InviteError.malformed)); return }
            if let end = combined.firstIndex(of: 10) {
                do { completion(.success(try JSONDecoder().decode(SignedEnvelope.self, from: combined.prefix(upTo: end)))) }
                catch { completion(.failure(InviteError.malformed)) }; return
            }
            if error != nil || done { completion(.failure(InviteError.unavailable)); return }
            self?.readEnvelope(connection, data: combined, completion: completion)
        }
    }
    private func send(_ envelope: SignedEnvelope, on connection: NWConnection, completion: @escaping (Error?) -> Void) {
        guard var data = try? JSONEncoder().encode(envelope) else { completion(InviteError.malformed); return }
        data.append(10)
        connection.send(content: data, completion: .contentProcessed(completion))
    }
    /// The address each recent request came from, by who signed it.
    private var arrivals: [String: (host: String, at: Date)] = [:]
    func arrivalHost(signer: String) -> String? {
        guard let entry = arrivals[signer], entry.at.timeIntervalSinceNow > -10, !entry.host.isEmpty else { return nil }
        return entry.host
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 24 else { connection.cancel(); return }
        let id = keep(connection); connection.start(queue: .main)
        readEnvelope(connection) { [weak self] result in
            guard let self else { return }
            guard case let .success(envelope) = result else { self.finish(id); return }
            if case let .hostPort(host, _) = connection.currentPath?.remoteEndpoint ?? connection.endpoint {
                self.arrivals = self.arrivals.filter { $0.value.at.timeIntervalSinceNow > -30 }
                self.arrivals[envelope.signer] = ("\(host)", Date())
            }
            self.incoming?(envelope) { [weak self] reply in
                guard let self else { return }
                self.send(reply, on: connection) { _ in self.finish(id) }
            }
        }
    }
    /// Tries each of the device's addresses in turn. An address that cannot be reached within a couple of seconds
    /// is skipped, so one dead route (a pulled cable, a dropped interface) does not block the others.
    func request(_ envelope: SignedEnvelope, endpoint: LocalEndpoint, timeout: TimeInterval = 120,
                 pathObserved: ((LocalConnectionPath) -> Void)? = nil, routeObserved: ((ConnectionRouteDetails) -> Void)? = nil, completion: @escaping (Result<SignedEnvelope, Error>) -> Void) {
        let hosts = endpoint.candidates
        func attempt(_ index: Int) {
            let last = index >= hosts.count - 1
            requestOne(envelope, host: hosts[index], port: endpoint.port, timeout: timeout, connectWithin: last ? timeout : 2.5,
                       pathObserved: pathObserved, routeObserved: routeObserved) { result, reached in
                if case .failure = result, !reached, !last { attempt(index + 1) } else { completion(result) }
            }
        }
        guard !hosts.isEmpty else { completion(.failure(InviteError.unavailable)); return }
        attempt(0)
    }
    /// One address. `reached` says whether a connection was made at all, which is what decides trying the next one.
    private func requestOne(_ envelope: SignedEnvelope, host: String, port: UInt16, timeout: TimeInterval, connectWithin: TimeInterval,
                            pathObserved: ((LocalConnectionPath) -> Void)?, routeObserved: ((ConnectionRouteDetails) -> Void)?,
                            completion: @escaping (Result<SignedEnvelope, Error>, Bool) -> Void) {
        guard let port = NWEndpoint.Port(rawValue: port) else { completion(.failure(InviteError.malformed), true); return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let id = keep(connection, timeout: timeout)
        // The signed request and reply contain public pairing metadata only.
        // Account linking also exchanges Apple identity assertions bound to the
        // signing device key; these are not reusable access/refresh tokens.
        // Audio and private keys never use this channel. Trusted hosts may
        // exchange signed device inventories and room layouts.
        var completed = false, reached = false
        func complete(_ result: Result<SignedEnvelope, Error>) {
            guard !completed else { return }; completed = true
            completion(result, reached); self.finish(id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + connectWithin) { if !reached { complete(.failure(InviteError.unavailable)) } }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                reached = true
                pathObserved?(LocalConnectionPath(connection.currentPath))
                routeObserved?(ConnectionRouteDetails(connection))
                self.send(envelope, on: connection) { error in
                    if let error { complete(.failure(error)); return }
                    self.readEnvelope(connection, completion: complete)
                }
            } else if case let .failed(error) = state { complete(.failure(error)) }
            else if case .cancelled = state, !completed { complete(.failure(InviteError.unavailable)) }
        }
        connection.start(queue: .main)
    }
}
