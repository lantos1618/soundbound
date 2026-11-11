import Foundation
import Network

struct LocalEndpoint { var host: String; var port: UInt16 }

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
        peers[ObjectIdentifier(service)] = NearbyPeer(invitation: invite, link: link, endpoint: LocalEndpoint(host: host, port: UInt16(service.port)))
        emit()
    }
    private func emit() { changed?(Array(peers.values).sorted { $0.invitation.peer.name < $1.invitation.peer.name }) }

    private func keep(_ connection: NWConnection) -> UUID {
        let id = UUID(); connections[id] = connection
        let timeout = DispatchWorkItem { [weak self] in self?.finish(id) }
        timeouts[id] = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timeout)
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
    private func accept(_ connection: NWConnection) {
        guard connections.count < 24 else { connection.cancel(); return }
        let id = keep(connection); connection.start(queue: .main)
        readEnvelope(connection) { [weak self] result in
            guard let self else { return }
            guard case let .success(envelope) = result else { self.finish(id); return }
            self.incoming?(envelope) { [weak self] reply in
                guard let self else { return }
                self.send(reply, on: connection) { _ in self.finish(id) }
            }
        }
    }
    func request(_ envelope: SignedEnvelope, endpoint: LocalEndpoint, completion: @escaping (Result<SignedEnvelope, Error>) -> Void) {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { completion(.failure(InviteError.malformed)); return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: parameters)
        let id = keep(connection)
        // The signed request and reply contain public pairing metadata only.
        // No audio, tokens, or private keys use this channel. Paired hosts may
        // exchange signed device inventories and room layouts.
        var completed = false
        func complete(_ result: Result<SignedEnvelope, Error>) {
            guard !completed else { return }; completed = true
            completion(result); self.finish(id)
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
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
