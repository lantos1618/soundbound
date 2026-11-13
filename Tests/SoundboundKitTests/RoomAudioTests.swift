import XCTest
import CryptoKit
import Network
@testable import SoundboundKit

final class RoomAudioTests: XCTestCase {
    func testFailedOutputRetriesWithFreshHandshakeWithoutDiscoveryChange() throws {
        let host = try makeStore(), identity = try Identity(ephemeral: true)
        let card = try pair(host, identity)
        let listening = expectation(description: "Control listener ready")
        let retried = expectation(description: "Fresh audio offer after failed connection")
        let listener = try NWListener(using: .tcp, on: .any)
        var offers: [AudioOffer] = []
        var connections: [NWConnection] = []
        func read(_ connection: NWConnection, buffered: Data = Data()) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                var bytes = buffered
                if let data { bytes.append(data) }
                guard let newline = bytes.firstIndex(of: 10) else {
                    if !complete && error == nil { read(connection, buffered: bytes) }
                    return
                }
                defer { connection.cancel() }
                guard let envelope = try? JSONDecoder().decode(SignedEnvelope.self, from: bytes.prefix(upTo: newline)),
                      let offer = try? envelope.verified(as: AudioOffer.self), offer.kind == "audio-offer" else { return }
                offers.append(offer)
                // Drop the control connection during the handshake.
                if offers.count == 2 { retried.fulfill() }
            }
        }
        listener.newConnectionHandler = { connection in
            connections.append(connection); connection.start(queue: .main); read(connection)
        }
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.start(queue: .main)
        wait(for: [listening], timeout: 3)
        defer { host.roomAudio.stop(); connections.forEach { $0.cancel() }; listener.cancel() }
        host.addRoom(name: "Studio", region: "Home", policy: .request)
        let room = try XCTUnwrap(host.rooms.first)
        host.moveDevice(to: room.id); host.movePeer(card.id, to: room.id); host.setActiveRoom(room.id)
        host.peerAudioDevices[card.id] = [output("speaker")]
        host.observeNearby([NearbyPeer(invitation: Invitation(peer: card, nonce: UUID().uuidString,
            expires: Date().addingTimeInterval(600)), link: "",
            endpoint: LocalEndpoint(host: "127.0.0.1", port: try XCTUnwrap(listener.port).rawValue))])
        host.onApplicationAudioStart = {}
        host.shareApplicationAudioWithRoom()
        wait(for: [retried], timeout: 9)
        XCTAssertTrue(host.roomAudio.active, "Explicit sharing intent survives a network failure")
        XCTAssertEqual(offers.count, 2)
        guard offers.count == 2 else { return }
        XCTAssertNotEqual(offers[0].id, offers[1].id)
        XCTAssertNotEqual(offers[0].ephemeralKey, offers[1].ephemeralKey)
    }

    private func output(_ id: String, available: Bool = true) -> LocalAudioDevice {
        var device = LocalAudioDevice(id: id, name: id, icon: "speaker", detail: "", status: "")
        device.hasOutput = true; device.isAvailable = available
        return device
    }
    private func makeStore() throws -> HubStore {
        HubStore(identity: try Identity(ephemeral: true), defaults: UserDefaults(suiteName: "room-audio." + UUID().uuidString)!)
    }
    private func pair(_ host: HubStore, _ peer: Identity) throws -> PeerCard {
        let (_, invite) = try SignedEnvelope.from(link: host.inviteLink)
        let card = PeerCard(publicKey: peer.publicKey, name: "Peer", kind: "mac")
        host.receive(try peer.sign(JoinMessage(requestID: UUID().uuidString, inviteNonce: invite.nonce, peer: card, created: Date()))) { _ in }
        host.decide(try XCTUnwrap(host.requests.first), approve: true)
        return card
    }
    func testAllMemberOutputsAreIncludedOnce() throws {
        let host = try makeStore(), peer = try Identity(ephemeral: true)
        _ = try pair(host, peer)
        let result = RoomAudioRoutes.outputs(roomID: "room", hostID: host.deviceID,
            devices: [output("local"), output("local")], hostRooms: ["room"],
            peerRooms: [peer.id: ["room"]],
            componentRooms: [HubStore.remoteComponentID(peer: peer.id, component: "speaker"): ["room"]],
            peers: host.friends, online: [peer.id], peerDevices: [peer.id: [output("speaker"), output("headphones")]])
        XCTAssertEqual(result, [RoomAudioDestination(peerID: nil, outputID: "local"),
            RoomAudioDestination(peerID: peer.id, outputID: "speaker"), RoomAudioDestination(peerID: peer.id, outputID: "headphones")])
    }
    func testOfflineUnpairedUnavailableAndInputDevicesAreExcluded() throws {
        let host = try makeStore(), peer = try Identity(ephemeral: true)
        _ = try pair(host, peer)
        var input = output("input"); input.hasOutput = false; input.hasInput = true
        var busy = output("busy"); busy.busy = true
        let result = RoomAudioRoutes.outputs(roomID: "room", hostID: host.deviceID,
            devices: [input, busy, output("disconnected", available: false)], hostRooms: ["room"],
            peerRooms: [peer.id: ["room"], "stranger": ["room"]], componentRooms: [:],
            peers: host.friends, online: ["stranger"], peerDevices: [peer.id: [output("offline")], "stranger": [output("unknown")]])
        XCTAssertTrue(result.isEmpty)
    }
    func testComponentMembershipDoesNotIncludeSiblingOutputs() throws {
        let host = try makeStore(), peer = try Identity(ephemeral: true)
        _ = try pair(host, peer)
        let result = RoomAudioRoutes.outputs(roomID: "room", hostID: host.deviceID,
            devices: [output("local"), output("other")], hostRooms: [], peerRooms: [:],
            componentRooms: ["local": ["room"], HubStore.remoteComponentID(peer: peer.id, component: "headphones"): ["room"]],
            peers: host.friends, online: [peer.id], peerDevices: [peer.id: [output("speaker"), output("headphones")]])
        XCTAssertEqual(result, [RoomAudioDestination(peerID: nil, outputID: "local"), RoomAudioDestination(peerID: peer.id, outputID: "headphones")])
    }
    func testADeviceAddedWholeCanBeRemoved() throws {
        let host = try makeStore(), peer = try Identity(ephemeral: true)
        _ = try pair(host, peer)
        host.addRoom(name: "Studio", region: "Home", policy: .request)
        let room = try XCTUnwrap(host.rooms.first)
        host.reportedAudioDevices = [output("speaker"), output("headphones")]
        host.moveDevice(to: room.id); host.movePeer(peer.id, to: room.id)
        // Taking one part out of a device added whole leaves the other parts in the room.
        host.removeAudioDevice("speaker", from: room.id)
        XCTAssertFalse(host.audioDevice("speaker", belongsTo: room.id))
        XCTAssertTrue(host.audioDevice("headphones", belongsTo: room.id))
        // Removing the device takes everything out.
        host.removeHost(host.deviceID, from: room)
        XCTAssertFalse(host.host(host.deviceID, isIn: room.id))
        XCTAssertTrue(host.host(peer.id, isIn: room.id))
        host.removeHost(peer.id, from: room)
        XCTAssertFalse(host.host(peer.id, isIn: room.id))
    }
    func testReceivingRequiresActiveRoomAndBothMemberships() throws {
        let host = try makeStore(), peer = try Identity(ephemeral: true)
        let card = try pair(host, peer)
        host.addRoom(name: "Studio", region: "Home", policy: .request)
        let room = try XCTUnwrap(host.rooms.first)
        host.moveDevice(to: room.id); host.movePeer(peer.id, to: room.id)
        host.reportedAudioDevices = [output("speaker")]
        let offer = AudioOffer(version: 4, id: UUID().uuidString, from: card, to: host.deviceID,
            ephemeralKey: "", port: 1, created: Date(), source: "room-audio", outputID: "speaker", roomID: room.id, sourceID: peer.id)
        XCTAssertFalse(host.acceptsRoomAudio(offer))
        host.setActiveRoom(room.id)
        XCTAssertTrue(host.acceptsRoomAudio(offer))
        host.removePeer(peer.id, from: room.id)
        XCTAssertFalse(host.acceptsRoomAudio(offer))
        host.movePeer(peer.id, to: room.id); host.removeDevice(from: room.id)
        XCTAssertFalse(host.acceptsRoomAudio(offer))
    }
    func testJoiningStartsCaptureWhenSetToSendAndRemovingSourceStopsIt() throws {
        let host = try makeStore()
        host.addRoom(name: "Studio", region: "Home", policy: .request)
        let room = try XCTUnwrap(host.rooms.first)
        var starts = 0, stops = 0
        host.onApplicationAudioStart = { starts += 1 }
        host.onApplicationAudioStop = { stops += 1 }
        // Putting the device in a room is not enough; joining it is what starts sending, when the device is set
        // to send. There is no separate Share switch.
        host.audioDirection = .both
        host.moveDevice(to: room.id)
        XCTAssertEqual(starts, 0)
        host.setActiveRoom(room.id)
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(host.roomAudio.sharingApplications)
        host.removeDevice(from: room.id)
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(host.roomAudio.active)
        host.roomAudio.stop()
        XCTAssertEqual(stops, 1)
    }
    func testPausingRoomStopsEmitter() throws {
        let host = try makeStore()
        host.addRoom(name: "Studio", region: "Home", policy: .request)
        let room = try XCTUnwrap(host.rooms.first)
        host.moveDevice(to: room.id); host.setActiveRoom(room.id)
        host.onApplicationAudioStart = {}
        host.shareApplicationAudioWithRoom()
        host.setActiveRoom(nil)
        XCTAssertFalse(host.roomAudio.active)
        XCTAssertFalse(host.roomAudio.sharingApplications)
    }
    func testOutputMembershipCanPublishButNoReceiversDoesNotClaimSending() throws {
        let host = try makeStore()
        host.addRoom(name: "Studio", region: "Home", policy: .request)
        let room = try XCTUnwrap(host.rooms.first)
        var speaker = output("speaker"); speaker.selectedOutput = true
        host.reportedAudioDevices = [speaker]
        host.moveAudioDevice(speaker.id, to: room.id)
        host.setActiveRoom(room.id)
        host.onApplicationAudioStart = {}
        XCTAssertEqual(host.applicationSourceID(in: room.id), speaker.id)
        host.shareApplicationAudioWithRoom()
        XCTAssertTrue(host.roomAudio.sharingApplications)
        XCTAssertTrue(host.roomAudio.status.hasPrefix("Waiting for an online output"))
        host.roomAudio.appendApplicationPCM(Data([1, 0, 2, 0]))
        host.roomAudio.updateEmissionStatus()
        XCTAssertTrue(host.roomAudio.status.hasPrefix("Waiting for an online output"))
        host.setActiveRoom(nil)
    }
    func testExpiredPairingHistoryFreesCapacity() throws {
        let host = try makeStore(), peer = try Identity(ephemeral: true)
        let (_, invitation) = try SignedEnvelope.from(link: host.inviteLink)
        let card = PeerCard(publicKey: peer.publicKey, name: "Peer", kind: "mac")
        let now = Date()
        for index in 0..<1000 {
            let message = JoinMessage(requestID: "request-\(index)", inviteNonce: invitation.nonce, peer: card, created: now)
            host.receive(try peer.sign(message), now: now) { _ in }
            host.decide(try XCTUnwrap(host.requests.first), approve: false)
        }
        let full = JoinMessage(requestID: "next", inviteNonce: invitation.nonce, peer: card, created: now)
        host.receive(try peer.sign(full), now: now) { _ in XCTFail("History is still at capacity") }
        XCTAssertTrue(host.requests.isEmpty)
        let later = now.addingTimeInterval(121)
        let fresh = JoinMessage(requestID: "fresh", inviteNonce: invitation.nonce, peer: card, created: later)
        host.receive(try peer.sign(fresh), now: later) { _ in }
        XCTAssertEqual(host.requests.first?.id, "fresh")
    }
    func testMoveRequestExpiresAndDiscoveryOffClearsApprovals() throws {
        let host = try makeStore(), peer = try Identity(ephemeral: true)
        let card = try pair(host, peer)
        var reply: DeviceMoveReply?
        let request = DeviceMoveRequest(sender: card, recipient: host.deviceID, deviceName: "Headphones")
        host.receive(try peer.sign(request)) { reply = try? $0.verified(as: DeviceMoveReply.self) }
        host.expireDeviceMoveRequest("unrelated")
        XCTAssertNotNil(host.deviceMoveRequest)
        host.expireDeviceMoveRequest(request.id)
        XCTAssertNil(host.deviceMoveRequest)
        XCTAssertEqual(reply?.accepted, false)
        let next = DeviceMoveRequest(sender: card, recipient: host.deviceID, deviceName: "Headphones")
        host.receive(try peer.sign(next)) { _ in }
        XCTAssertNotNil(host.deviceMoveRequest)
        host.setDiscovery(false)
        XCTAssertNil(host.deviceMoveRequest)
    }
    func testEachDestinationUsesIndependentEncryptionKeys() throws {
        let source = Curve25519.KeyAgreement.PrivateKey()
        let a = Curve25519.KeyAgreement.PrivateKey(), b = Curve25519.KeyAgreement.PrivateKey()
        let keyA = try AudioSessionCipher.keys(privateKey: source, remote: a.publicKey.rawRepresentation.url64, session: "a", source: "source", sink: "a").0
        let keyB = try AudioSessionCipher.keys(privateKey: source, remote: b.publicKey.rawRepresentation.url64, session: "b", source: "source", sink: "b").0
        var sender = AudioSessionCipher(key: keyA, context: Data("a".utf8))
        let packet = try sender.seal(kind: "audio", pcm: Data([1, 0]))
        var other = AudioSessionCipher(key: keyB, context: Data("b".utf8))
        XCTAssertThrowsError(try other.open(packet))
    }
    func testSamePCMReachesTwoIndependentEncryptedReceivers() throws {
        let delivered = expectation(description: "Both room outputs receive PCM")
        delivered.expectedFulfillmentCount = 2
        let transmitted = expectation(description: "Both encrypted audio writes complete")
        transmitted.expectedFulfillmentCount = 2
        let measured = expectation(description: "Both persistent audio connections measure RTT")
        measured.expectedFulfillmentCount = 2
        var measuredPeers = Set<String>()
        let sourceIdentity = try Identity(ephemeral: true)
        let sourceCard = PeerCard(publicKey: sourceIdentity.publicKey, name: "Mac", kind: "mac")
        let pcm = Data([1, 0, 2, 0, 3, 0])
        var senders: [AudioMesh] = []
        var receivers: [AudioMeshChannel] = []
        for index in 0..<2 {
            let identity = try Identity(ephemeral: true)
            let card = PeerCard(publicKey: identity.publicKey, name: "Receiver", kind: "mac")
            let peer = NearbyPeer(invitation: Invitation(peer: card, nonce: UUID().uuidString, expires: Date().addingTimeInterval(60)),
                link: "", endpoint: LocalEndpoint(host: "127.0.0.1", port: 1))
            let sender = AudioMesh()
            sender.request = { signed, _, complete in
                do {
                    let offer = try signed.verified(as: AudioOffer.self)
                    XCTAssertEqual(offer.version, 4)
                    XCTAssertEqual(offer.roomID, "room")
                    XCTAssertEqual(offer.outputID, "output-\(index)")
                    let key = Curve25519.KeyAgreement.PrivateKey()
                    let keys = try AudioSessionCipher.keys(privateKey: key, remote: offer.ephemeralKey,
                        session: offer.id, source: sourceCard.id, sink: card.id)
                    let reply = AudioReply(id: offer.id, from: card, to: sourceCard.id, accepted: true,
                        ephemeralKey: key.publicKey.rawRepresentation.url64, created: Date())
                    complete(.success(try identity.sign(reply)))
                    let channel = AudioMeshChannel(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: offer.port)!, using: .tcp),
                        sendKey: keys.1, receiveKey: keys.0, session: offer.id, source: false)
                    channel.audio = { received in XCTAssertEqual(received, pcm); delivered.fulfill() }
                    receivers.append(channel); channel.start()
                } catch { XCTFail("\(error)"); complete(.failure(error)) }
            }
            sender.onReady = { [weak sender] in sender?.appendPCM(pcm) }
            sender.onAudioSent = { transmitted.fulfill() }
            sender.onRoundTrip = { peerID, _, milliseconds in
                XCTAssertGreaterThanOrEqual(milliseconds, 0)
                if measuredPeers.insert(peerID).inserted { measured.fulfill() }
            }
            senders.append(sender)
            sender.sendPCM(to: peer, identity: sourceIdentity, card: sourceCard,
                outputID: "output-\(index)", roomID: "room", sourceID: sourceCard.id)
        }
        wait(for: [delivered, transmitted, measured], timeout: 8)
        senders.forEach { $0.stop() }; receivers.forEach { $0.stop() }
    }
}
