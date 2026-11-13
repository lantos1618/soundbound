import Foundation
import Combine

struct PeerPingRequest: Codable {
    var kind = "peer-ping"
    var id = UUID().uuidString
    var sender: String
    var recipient: String
    var created = Date()
}
struct PeerPingReply: Codable {
    var kind = "peer-pong"
    var id: String
    var sender: String
    var recipient: String
}

/// Prefers RTT from encrypted echoes on the persistent audio connection.
/// Idle probes include TCP setup and a signed reply, and are labeled separately.
public final class PeerPingMonitor: ObservableObject {
    public enum State: Equatable {
        case measuring
        case available(milliseconds: Int, measuredAt: Date)
        case unavailable
    }
    @Published public private(set) var states: [String: State] = [:]
    @Published private var probePaths: [String: LocalConnectionPath] = [:]
    @Published private var mediaPaths: [String: [String: LocalConnectionPath]] = [:]
    @Published private var mediaRoundTrips: [String: [String: (milliseconds: Double, measuredAt: Date)]] = [:]
    @Published private var routeDetails: [String: [String: String]] = [:]
    @Published private var probeDetails: [String: String] = [:]
    func recordRouteDetails(peerID: String, sessionID: String, details: ConnectionRouteDetails?) {
        routeDetails[peerID, default: [:]][sessionID] = details?.text
    }
    public func diagnostics(for peerID: String) -> String {
        let live = routeDetails[peerID]?.values.sorted() ?? []
        if !live.isEmpty { return "Live audio connection\n" + live.joined(separator: "\n\n") }
        if let probe = probeDetails[peerID] { return "Last idle connection probe (not a live audio stream)\n" + probe }
        return "No route observed. Open the peer app and connect to capture route details."
    }
    @Published private var routeReports: [String: String] = [:]
    @Published private var routeTrials: [String: UUID] = [:]
    private var testedCandidates: [String: [String]] = [:]
    public func testingRoutes(for peerID: String) -> Bool { routeTrials[peerID] != nil }
    /// One way of reaching a device: an address, what interface it uses and how long a round trip took.
    public struct RouteChoice: Identifiable {
        public var host: String
        public var milliseconds: Double?
        public var interface: String
        public var id: String { host }
    }
    /// The routes measured to each device, fastest first.
    @Published public internal(set) var routeChoices: [String: [RouteChoice]] = [:]
    /// A route chosen by hand for a device. Absent means automatic: use the fastest measured.
    @Published public internal(set) var pinnedRoutes: [String: String] = [:]
    /// Choose a route for a device, or nil for automatic, and reconnect its streams on it.
    public func selectRoute(_ host: String?, for peerID: String) {
        pinnedRoutes[peerID] = host
        if let host { store?.network.preferEndpoint(host, for: peerID); store?.roomAudio.reconnect(peerID: peerID) }
        else { store?.network.clearPreference(for: peerID); testRoutes(to: peerID); store?.roomAudio.reconnect(peerID: peerID) }
    }
    /// The route in use died. A hand-picked route is dropped so the device can be reached another way.
    func routeLost(for peerID: String) {
        if pinnedRoutes.removeValue(forKey: peerID) != nil { store?.notice = "The chosen network route dropped, so Soundbound went back to automatic." }
    }
    public func routeReport(for peerID: String) -> String { routeReports[peerID] ?? "Routes not tested yet." }
    private var online: Set<String> = []
    private var pending: [String: UUID] = [:]
    private var lastProbe = Date.distantPast
    private var seen: [String: Date] = [:]
    private weak var store: HubStore?
    func attach(_ store: HubStore) { self.store = store }

    public func label(for peerID: String, now: Date = Date()) -> String {
        if online.contains(peerID), let milliseconds = streamRoundTrip(for: peerID, now: now) {
            return "Network RTT: \(String(format: "%.1f", milliseconds)) ms"
        }
        return Self.label(state: states[peerID], online: online.contains(peerID), now: now)
    }
    static func label(state: State?, online: Bool, now: Date) -> String {
        guard online else { return "Offline" }
        switch state {
        case .available(let milliseconds, let measuredAt) where now.timeIntervalSince(measuredAt) < 15:
            return "Connection probe: \(milliseconds) ms"
        case .unavailable: return "Network RTT unavailable"
        default: return "Measuring network RTT…"
        }
    }
    static func milliseconds(start: UInt64, end: UInt64) -> Int {
        guard end >= start else { return 0 }
        return Int((Double(end - start) / 1_000_000).rounded())
    }
    public func connectionLabel(for peerID: String) -> String? {
        guard online.contains(peerID) else { return nil }
        let paths = Set(mediaPaths[peerID]?.values.map { $0 } ?? [])
        if !paths.isEmpty { return Self.connectionLabel(paths: paths) }
        return probePaths[peerID].map { Self.connectionLabel(paths: [$0]) }
    }
    /// The interface carrying audio to this peer, or the last probe's when idle; short enough for a device row.
    public func transportLabel(for peerID: String) -> String? {
        guard online.contains(peerID) else { return nil }
        let paths = Set(mediaPaths[peerID]?.values.map { $0 } ?? [])
        if !paths.isEmpty { return paths.map(\.shortLabel).sorted().joined(separator: "/") }
        return probePaths[peerID]?.shortLabel
    }
    static func connectionLabel(paths: Set<LocalConnectionPath>) -> String {
        "TCP · " + paths.map(\.rawValue).sorted().joined(separator: "/") + (paths.contains(.tunnel) ? "" : " · VPN status unknown")
    }
    func recordMediaPath(peerID: String, sessionID: String, path: LocalConnectionPath?) {
        if let path { mediaPaths[peerID, default: [:]][sessionID] = path }
        else {
            mediaRoundTrips[peerID]?[sessionID] = nil
            mediaPaths[peerID]?[sessionID] = nil
            if mediaPaths[peerID]?.isEmpty == true { mediaPaths[peerID] = nil }
        }
    }
    func recordRoundTrip(peerID: String, sessionID: String, milliseconds: Double, now: Date = Date()) {
        guard milliseconds.isFinite, milliseconds >= 0, mediaPaths[peerID]?[sessionID] != nil else { return }
        mediaRoundTrips[peerID, default: [:]][sessionID] = (milliseconds, now)
    }
    /// The latest measured network round trip: on the live audio stream when one is open, otherwise the idle probe.
    public func roundTrip(for peerID: String, now: Date = Date()) -> (milliseconds: Double, live: Bool)? {
        guard online.contains(peerID) else { return nil }
        if let milliseconds = streamRoundTrip(for: peerID, now: now) { return (milliseconds, true) }
        if case let .available(milliseconds, measuredAt)? = states[peerID], now.timeIntervalSince(measuredAt) < 15 {
            return (Double(milliseconds), false)
        }
        return nil
    }
    private func streamRoundTrip(for peerID: String, now: Date) -> Double? {
        mediaRoundTrips[peerID]?.values.filter { now.timeIntervalSince($0.measuredAt) < 5 }.map(\.milliseconds).max()
    }
    static func validReply(_ envelope: SignedEnvelope, request: PeerPingRequest, peer: KnownPeer) -> Bool {
        guard envelope.signer == peer.card.publicKey,
              let reply = try? envelope.verified(as: PeerPingReply.self) else { return false }
        return reply.kind == "peer-pong" && reply.id == request.id && reply.sender == peer.id && reply.recipient == request.sender
    }
    func refresh(now: Date = Date()) {
        guard let store else { return }
        let trusted = Dictionary(store.friends.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let peers = store.nearby.filter { trusted[$0.id]?.card.publicKey == $0.invitation.peer.publicKey }
        let nextOnline = Set(peers.map(\.id))
        if online != nextOnline {
            online = nextOnline
            routeTrials = routeTrials.filter { online.contains($0.key) }
            testedCandidates = testedCandidates.filter { online.contains($0.key) }
            states = states.filter { online.contains($0.key) }
            routeDetails = routeDetails.filter { online.contains($0.key) }
            probeDetails = probeDetails.filter { online.contains($0.key) }
            probePaths = probePaths.filter { online.contains($0.key) }
            mediaPaths = mediaPaths.filter { online.contains($0.key) }
            mediaRoundTrips = mediaRoundTrips.filter { online.contains($0.key) }
            pending = pending.filter { online.contains($0.key) }
            lastProbe = .distantPast
        }
        for peer in peers where routeTrials[peer.id] == nil && testedCandidates[peer.id] == nil && mediaPaths[peer.id]?.isEmpty != false {
            testRoutes(to: peer.id)
        }
        guard store.discovering, let identity = store.identity, now.timeIntervalSince(lastProbe) >= 5 else { return }
        lastProbe = now
        for peer in peers where pending[peer.id] == nil {
            if streamRoundTrip(for: peer.id, now: now) != nil { continue }
            guard let known = trusted[peer.id] else { continue }
            let request = PeerPingRequest(sender: store.deviceID, recipient: peer.id)
            guard let signed = try? identity.sign(request) else { continue }
            let ticket = UUID(); pending[peer.id] = ticket
            if states[peer.id] == nil { states[peer.id] = .measuring }
            let started = DispatchTime.now().uptimeNanoseconds
            store.network.request(signed, endpoint: peer.endpoint, timeout: 2, pathObserved: { [weak self] path in
                guard let self, self.pending[peer.id] == ticket else { return }
                self.probePaths[peer.id] = path
            }, routeObserved: { [weak self] details in
                guard let self, self.pending[peer.id] == ticket else { return }
                self.probeDetails[peer.id] = details.text
            }) { [weak self] result in
                guard let self, self.pending[peer.id] == ticket else { return }
                self.pending.removeValue(forKey: peer.id)
                guard self.online.contains(peer.id), self.store?.friends.contains(where: { $0.id == known.id && $0.card.publicKey == known.card.publicKey }) == true else { return }
                if case let .success(envelope) = result, Self.validReply(envelope, request: request, peer: known) {
                    self.states[peer.id] = .available(milliseconds: Self.milliseconds(start: started, end: DispatchTime.now().uptimeNanoseconds), measuredAt: Date())
                } else { self.states[peer.id] = .unavailable }
            }
        }
    }
    func receive(_ envelope: SignedEnvelope, respond: @escaping (SignedEnvelope) -> Void) -> Bool {
        guard let request = try? envelope.verified(as: PeerPingRequest.self), request.kind == "peer-ping" else { return false }
        guard let store, let identity = store.identity else { return true }
        seen = seen.filter { $0.value > Date().addingTimeInterval(-120) }
        guard request.recipient == store.deviceID, UUID(uuidString: request.id) != nil,
              abs(request.created.timeIntervalSinceNow) < 30,
              store.friends.contains(where: { $0.id == request.sender && $0.card.publicKey == envelope.signer }),
              seen[request.id] == nil, seen.count < 1000 else { return true }
        seen[request.id] = Date()
        let reply = PeerPingReply(id: request.id, sender: store.deviceID, recipient: request.sender)
        if let signed = try? identity.sign(reply) { respond(signed) }
        return true
    }
}


struct RouteProbeScore {
    let host: String
    let samples: [Double]
    var median: Double? {
        guard samples.count >= 2 else { return nil }
        return samples.sorted()[samples.count / 2]
    }
    var score: Double? {
        guard let median else { return nil }
        return median + ((samples.max() ?? median) - (samples.min() ?? median)) / 2 + Double(3 - samples.count) * 100
    }
    static func best(_ results: [RouteProbeScore], current: String) -> String? {
        let valid = results.filter { $0.score != nil }
        guard let best = valid.min(by: { $0.score! < $1.score! }) else { return nil }
        if let existing = valid.first(where: { $0.host == current }), existing.score! <= best.score! + 3 { return current }
        return best.host
    }
}

extension PeerPingMonitor {
    public func testRoutes(to peerID: String) {
        guard routeTrials[peerID] == nil, let store, let identity = store.identity,
              let known = store.friends.first(where: { $0.id == peerID }),
              let peer = store.nearby.first(where: { $0.id == peerID && $0.invitation.peer.publicKey == known.card.publicKey }) else { return }
        let hosts = peer.endpoint.candidates
        let ticket = UUID(); routeTrials[peerID] = ticket
        testedCandidates[peerID] = hosts
        routeReports[peerID] = "Testing \(hosts.count) discovered TCP address(es), three probes each…"
        var results: [RouteProbeScore] = []
        var paths: [String: String] = [:]
        var remaining = hosts.count
        func finish(_ host: String, _ samples: [Double]) {
            guard self.routeTrials[peerID] == ticket else { return }
            results.append(RouteProbeScore(host: host, samples: samples)); remaining -= 1
            guard remaining == 0 else { return }
            self.routeTrials[peerID] = nil
            let best = RouteProbeScore.best(results, current: peer.endpoint.host)
            let rows = results.sorted { ($0.score ?? .infinity) < ($1.score ?? .infinity) }.map { result in
                let timing = result.median.map { String(format: "%.1f ms median", $0) } ?? "unreliable"
                return "\(result.host): \(timing), \(result.samples.count)/3 replies\(result.host == best ? " · selected" : "")\n  \(paths[result.host] ?? "Interface unavailable")"
            }
            self.routeReports[peerID] = rows.joined(separator: "\n") + "\nTCP setup + signed reply, not audible latency. Selection applies to new connections. VPN routing remains controlled by the OS.\nBLE audio, WebRTC and dedicated relay: not implemented."
            self.routeChoices[peerID] = results.sorted { ($0.score ?? .infinity) < ($1.score ?? .infinity) }.map {
                RouteChoice(host: $0.host, milliseconds: $0.median,
                            interface: (paths[$0.host] ?? "").replacingOccurrences(of: "Path interfaces:", with: "").trimmingCharacters(in: .whitespaces))
            }
            // A route picked by hand stays picked; otherwise take the fastest.
            if let pin = self.pinnedRoutes[peerID], hosts.contains(pin) { store.network.preferEndpoint(pin, for: peerID) }
            else if let best { store.network.preferEndpoint(best, for: peerID) }
        }
        func probe(_ host: String, attempt: Int, samples: [Double]) {
            guard self.routeTrials[peerID] == ticket else { return }
            guard attempt < 3 else { finish(host, samples); return }
            let request = PeerPingRequest(sender: store.deviceID, recipient: peerID)
            guard let signed = try? identity.sign(request) else { finish(host, samples); return }
            let started = DispatchTime.now().uptimeNanoseconds
            store.network.request(signed, endpoint: LocalEndpoint(host: host, port: peer.endpoint.port), timeout: 1.5,
                routeObserved: { details in paths[host] = details.text.components(separatedBy: "\n").first(where: { $0.hasPrefix("Path interfaces:") }) ?? "Interface unavailable" }) { result in
                guard self.routeTrials[peerID] == ticket else { return }
                var next = samples
                if case let .success(envelope) = result, Self.validReply(envelope, request: request, peer: known) {
                    let end = DispatchTime.now().uptimeNanoseconds
                    if end >= started { next.append(Double(end - started) / 1_000_000) }
                }
                probe(host, attempt: attempt + 1, samples: next)
            }
        }
        for host in hosts { probe(host, attempt: 0, samples: []) }
    }
}
