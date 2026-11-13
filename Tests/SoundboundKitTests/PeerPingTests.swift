import XCTest
import Network
import CryptoKit
@testable import SoundboundKit

final class PeerPingTests: XCTestCase {
    func testTunnelInterfaceHintsDoNotClaimPhysicalRoutesBypassVPN() {
        XCTAssertTrue(LocalConnectionPath.isTunnelInterface("utun4"))
        XCTAssertFalse(LocalConnectionPath.isTunnelInterface("en0"))
        XCTAssertTrue(PeerPingMonitor.connectionLabel(paths: [.wifi]).contains("VPN status unknown"))
        XCTAssertEqual(PeerPingMonitor.connectionLabel(paths: [.tunnel]), "TCP · Tunnel interface (possible VPN)")
    }
    func testUsesMonotonicRoundTripInMilliseconds() {
        XCTAssertEqual(PeerPingMonitor.milliseconds(start: 9_000_000, end: 21_000_000), 12)
        XCTAssertEqual(PeerPingMonitor.milliseconds(start: 0, end: 1_600_000), 2)
        XCTAssertEqual(PeerPingMonitor.milliseconds(start: 10, end: 1), 0)
    }
    func testOfflineAndStaleReadingsNeverShowOldPing() {
        let now = Date()
        let sample = PeerPingMonitor.State.available(milliseconds: 12, measuredAt: now)
        XCTAssertEqual(PeerPingMonitor.label(state: sample, online: true, now: now), "Connection probe: 12 ms")
        XCTAssertEqual(PeerPingMonitor.label(state: sample, online: false, now: now), "Offline")
        XCTAssertEqual(PeerPingMonitor.label(state: sample, online: true, now: now.addingTimeInterval(16)), "Measuring network RTT…")
        XCTAssertEqual(PeerPingMonitor.label(state: .unavailable, online: true, now: now), "Network RTT unavailable")
    }
    func testReplyMustMatchRequestIdentityAndRecipient() throws {
        let peer = try Identity(ephemeral: true), attacker = try Identity(ephemeral: true)
        let card = PeerCard(publicKey: peer.publicKey, name: "Phone", kind: "iphone")
        let known = KnownPeer(card: card, acceptedAt: Date())
        let request = PeerPingRequest(sender: "mac", recipient: card.id)
        var reply = PeerPingReply(id: request.id, sender: card.id, recipient: "mac")
        XCTAssertTrue(PeerPingMonitor.validReply(try peer.sign(reply), request: request, peer: known))
        XCTAssertFalse(PeerPingMonitor.validReply(try attacker.sign(reply), request: request, peer: known))
        reply.id = UUID().uuidString
        XCTAssertFalse(PeerPingMonitor.validReply(try peer.sign(reply), request: request, peer: known))
        reply.id = request.id; reply.recipient = "other"
        XCTAssertFalse(PeerPingMonitor.validReply(try peer.sign(reply), request: request, peer: known))
    }
    func testOnlyPairedFreshRequestsGetRepliesAndReplaysAreRejected() throws {
        let local = try Identity(ephemeral: true), peer = try Identity(ephemeral: true)
        let store = HubStore(identity: local, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let request = PeerPingRequest(sender: peer.id, recipient: local.id)
        let envelope = try peer.sign(request)
        XCTAssertTrue(store.ping.receive(envelope) { _ in XCTFail("Unpaired request") })
        let (_, invite) = try SignedEnvelope.from(link: store.inviteLink)
        let card = PeerCard(publicKey: peer.publicKey, name: "Peer", kind: "mac")
        store.receive(try peer.sign(JoinMessage(requestID: UUID().uuidString, inviteNonce: invite.nonce, peer: card, created: Date()))) { _ in }
        store.decide(try XCTUnwrap(store.requests.first), approve: true)
        var result: SignedEnvelope?
        XCTAssertTrue(store.ping.receive(envelope) { result = $0 })
        XCTAssertTrue(PeerPingMonitor.validReply(try XCTUnwrap(result), request: request, peer: KnownPeer(card: store.card, acceptedAt: Date())))
        XCTAssertTrue(store.ping.receive(envelope) { _ in XCTFail("Replayed request") })
        var stale = PeerPingRequest(sender: peer.id, recipient: local.id)
        stale.created = Date().addingTimeInterval(-60)
        XCTAssertTrue(store.ping.receive(try peer.sign(stale)) { _ in XCTFail("Expired request") })
    }
    func testProbeTimeoutDoesNotUseLongApprovalTimeout() throws {
        let finished = expectation(description: "Short request timeout")
        let identity = try Identity(ephemeral: true)
        let request = try identity.sign(PeerPingRequest(sender: identity.id, recipient: "peer"))
        let network = LocalNetwork()
        let listener = try NWListener(using: .tcp, on: .any)
        var connections: [NWConnection] = []
        listener.newConnectionHandler = { connection in connections.append(connection); connection.start(queue: .main) }
        listener.stateUpdateHandler = { state in
            guard case .ready = state, let port = listener.port else { return }
            network.request(request, endpoint: LocalEndpoint(host: "127.0.0.1", port: port.rawValue), timeout: 0.1) { result in
                if case .success = result { XCTFail("No server response should succeed") }
                finished.fulfill()
            }
        }
        listener.start(queue: .main)
        wait(for: [finished], timeout: 3)
        listener.cancel(); connections.forEach { $0.cancel() }
    }
    func testPlaybackQueueBudgetAndOneMillisecondPackets() {
        XCTAssertEqual(AudioBufferPolicy.wireFrameBytes / 2 * 1000 / AudioBufferPolicy.sampleRate, 1)
        XCTAssertTrue(AudioBufferPolicy.canQueue(frames: 480, queued: 1440))
        XCTAssertFalse(AudioBufferPolicy.canQueue(frames: 480, queued: 1441))
        XCTAssertFalse(AudioBufferPolicy.canQueue(frames: -1, queued: 0))
        XCTAssertEqual(AudioBufferPolicy.maximumPlaybackFrames * 1000 / AudioBufferPolicy.sampleRate, 80)
        let parameters = AudioBufferPolicy.tcpParameters()
        let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
        XCTAssertEqual(tcp?.noDelay, true)
        XCTAssertEqual(tcp?.disableAckStretching, true)
        XCTAssertTrue(parameters.includePeerToPeer)
    }
    func testConnectionLabelDescribesObservedTransportWithoutInventingServices() {
        XCTAssertEqual(PeerPingMonitor.connectionLabel(paths: [.wifi]), "TCP · Wi-Fi · VPN status unknown")
        XCTAssertEqual(PeerPingMonitor.connectionLabel(paths: [.ethernet]), "TCP · Ethernet · VPN status unknown")
        XCTAssertEqual(PeerPingMonitor.connectionLabel(paths: [.other]), "TCP · Interface unknown · VPN status unknown")
    }
    func testMediaPathIsClearedAfterStopAndOfflinePeersHaveNoLiveRoute() throws {
        let local = try Identity(ephemeral: true), remote = try Identity(ephemeral: true)
        let store = HubStore(identity: local, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let (_, invite) = try SignedEnvelope.from(link: store.inviteLink)
        let card = PeerCard(publicKey: remote.publicKey, name: "Phone", kind: "iphone")
        store.receive(try remote.sign(JoinMessage(requestID: UUID().uuidString, inviteNonce: invite.nonce, peer: card, created: Date()))) { _ in }
        store.decide(try XCTUnwrap(store.requests.first), approve: true)
        let nearby = NearbyPeer(invitation: Invitation(peer: card, nonce: UUID().uuidString, expires: Date().addingTimeInterval(60)),
            link: "", endpoint: LocalEndpoint(host: "localhost", port: 1))
        store.network.changed?([nearby])
        store.ping.recordMediaPath(peerID: card.id, sessionID: "session", path: .wifi)
        XCTAssertEqual(store.ping.connectionLabel(for: card.id), "TCP · Wi-Fi · VPN status unknown")
        let measuredAt = Date()
        store.ping.recordRoundTrip(peerID: card.id, sessionID: "session", milliseconds: 5.2, now: measuredAt)
        XCTAssertEqual(store.ping.label(for: card.id, now: measuredAt), "Network RTT: 5.2 ms")
        XCTAssertEqual(store.ping.label(for: card.id, now: measuredAt.addingTimeInterval(6)), "Measuring network RTT…")
        store.ping.recordMediaPath(peerID: card.id, sessionID: "session", path: nil)
        XCTAssertNil(store.ping.connectionLabel(for: card.id))
        store.ping.recordMediaPath(peerID: card.id, sessionID: "session", path: .wifi)
        store.network.changed?([])
        XCTAssertNil(store.ping.connectionLabel(for: card.id))
        XCTAssertEqual(store.ping.label(for: card.id), "Offline")
    }
    func testEncryptedHeartbeatSupportsEchoAndLegacyPeers() throws {
        let key = SymmetricKey(size: .bits256)
        var sender = AudioSessionCipher(key: key, context: Data("session".utf8))
        var receiver = AudioSessionCipher(key: key, context: Data("session".utf8))
        let id = UUID().uuidString
        let measured = try receiver.open(sender.seal(kind: "ping", pingID: id, echo: false))
        XCTAssertEqual(measured.pingID, id)
        XCTAssertEqual(measured.echo, false)
        let legacy = try receiver.open(sender.seal(kind: "ping"))
        XCTAssertNil(legacy.pingID)
        XCTAssertNil(legacy.echo)
    }
}
