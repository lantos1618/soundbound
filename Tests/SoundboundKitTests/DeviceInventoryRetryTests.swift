import XCTest
@testable import SoundboundKit

final class DeviceInventoryRetryTests: XCTestCase {
    private func fixture() throws -> (HubStore, Identity, NearbyPeer) {
        let host = HubStore(identity: try Identity(ephemeral: true), defaults: UserDefaults(suiteName: "inventory-retry." + UUID().uuidString)!)
        host.accountID = { nil }; host.accountProof = { nil }
        let remote = try Identity(ephemeral: true)
        let card = PeerCard(publicKey: remote.publicKey, name: "Mac", kind: "mac")
        let invitation = Invitation(peer: card, nonce: UUID().uuidString, expires: Date().addingTimeInterval(600))
        let peer = NearbyPeer(invitation: invitation, link: try remote.sign(invitation).link,
                              endpoint: LocalEndpoint(host: "127.0.0.1", port: 9))
        host.recordFriend(card)
        host.setDiscovery(true)
        host.observeNearby([peer])
        addTeardownBlock { host.setDiscovery(false) }
        return (host, remote, peer)
    }

    func testUnansweredFirstRequestRetriesAfterFiveSecondsAndIgnoresLateReply() throws {
        let (host, remote, peer) = try fixture()
        var requests: [InventoryRequest] = []
        var callbacks: [(Result<SignedEnvelope, Error>) -> Void] = []
        host.inventoryTransport = { envelope, _, timeout, completion in
            XCTAssertEqual(timeout, 5)
            requests.append(try! envelope.verified(as: InventoryRequest.self))
            callbacks.append(completion)
        }
        let start = Date()
        host.refreshPeerInventories(now: start)
        host.refreshPeerInventories(now: start.addingTimeInterval(4))
        XCTAssertEqual(requests.count, 1)
        // Reproduces an initial inventory ignored while the peer is still linking.
        host.refreshPeerInventories(now: start.addingTimeInterval(5.1))
        XCTAssertEqual(requests.count, 2, "A lost request must not block inventory for two minutes")
        let stale = InventoryReply(requestID: requests[0].id, recipient: host.deviceID,
            devices: [LocalAudioDevice(id: "old", name: "Old speaker", icon: "speaker", detail: "", status: "")])
        callbacks[0](.success(try remote.sign(stale)))
        XCTAssertEqual(host.inventoryPending[peer.id]?.id, requests[1].id)
        XCTAssertNil(host.peerAudioDevices[peer.id])
        let fresh = InventoryReply(requestID: requests[1].id, recipient: host.deviceID,
            devices: [LocalAudioDevice(id: "new", name: "Mac speaker", icon: "speaker", detail: "", status: "")])
        callbacks[1](.success(try remote.sign(fresh)))
        XCTAssertEqual(host.peerAudioDevices[peer.id]?.map(\.id), ["new"])
        XCTAssertNil(host.inventoryPending[peer.id])
    }

    func testDisconnectClearsPendingInventoryAndReconnectFetchesAgain() throws {
        let (host, _, peer) = try fixture()
        var sent = 0
        host.inventoryTransport = { _, _, _, _ in sent += 1 }
        let start = Date()
        host.refreshPeerInventories(now: start)
        XCTAssertEqual(sent, 1)
        host.observeNearby([])
        host.refreshPeerInventories(now: start.addingTimeInterval(1))
        XCTAssertNil(host.inventoryPending[peer.id])
        host.observeNearby([peer])
        host.refreshPeerInventories(now: start.addingTimeInterval(5.1))
        XCTAssertEqual(sent, 2)
        host.setDiscovery(false)
        XCTAssertTrue(host.inventoryPending.isEmpty)
    }

    func testEmptyInventoryCountsAsAReplyAndDoesNotCauseReciprocalPollingLoop() throws {
        let (host, remote, peer) = try fixture()
        var sent = 0
        host.inventoryTransport = { envelope, _, _, completion in
            sent += 1
            let request = try! envelope.verified(as: InventoryRequest.self)
            let reply = InventoryReply(requestID: request.id, recipient: host.deviceID, devices: [])
            completion(.success(try! remote.sign(reply)))
        }
        host.refreshPeerInventories(now: Date())
        XCTAssertTrue(host.inventoryReceived.contains(peer.id))
        XCTAssertNil(host.peerAudioDevices[peer.id])
        let request = InventoryRequest(recipient: host.deviceID)
        host.receive(try remote.sign(request)) { _ in }
        let settled = expectation(description: "No reciprocal request for an already received empty inventory")
        DispatchQueue.main.async {
            XCTAssertEqual(sent, 1)
            settled.fulfill()
        }
        wait(for: [settled], timeout: 2)
    }

    func testSignedInventoryMirrorsPlaybackAndClearsItWhenPlaybackStops() throws {
        let (host, remote, peer) = try fixture()
        var playback = [DevicePlaybackSnapshot(id: "speaker", level: 0.42)]
        let speaker = LocalAudioDevice(id: "speaker", name: "Speaker", icon: "speaker", detail: "", status: "")
        host.inventoryTransport = { envelope, _, _, completion in
            let request = try! envelope.verified(as: InventoryRequest.self)
            completion(.success(try! remote.sign(InventoryReply(requestID: request.id,
                recipient: host.deviceID, devices: [speaker], playback: playback))))
        }
        host.addRoom(name: "Room", region: "Home", policy: .invite)
        let room = try XCTUnwrap(host.rooms.first)
        playback[0].roomID = room.id
        let key = HubStore.remoteComponentID(peer: peer.id, component: "speaker")
        host.moveAudioDevice(key, to: room.id)
        host.refreshPeerInventories(now: Date())
        XCTAssertEqual(host.activity.modes[key], .chirping)
        XCTAssertEqual(host.activity.levels[key], 0.42)
        XCTAssertTrue(host.roomHasPeerPlayback(room.id))
        host.addRoom(name: "Other room", region: "Home", policy: .invite)
        let other = try XCTUnwrap(host.rooms.first(where: { $0.id != room.id }))
        host.moveAudioDevice(key, to: other.id)
        XCTAssertFalse(host.roomHasPeerPlayback(other.id), "A shared speaker does not mean both rooms are playing")
        playback = []
        host.lastInventoryRefresh = .distantPast
        host.refreshPeerInventories(now: Date())
        XCTAssertNil(host.activity.modes[key])
        XCTAssertFalse(host.roomHasPeerPlayback(room.id))
    }

    func testUnreportedPlaybackIDsAreRejectedAndOldPlaybackExpires() throws {
        let (host, remote, peer) = try fixture()
        host.inventoryTransport = { envelope, _, _, completion in
            let request = try! envelope.verified(as: InventoryRequest.self)
            completion(.success(try! remote.sign(InventoryReply(requestID: request.id,
                recipient: host.deviceID, devices: [], playback: [.init(id: "unknown", level: 0.5)]))))
        }
        host.refreshPeerInventories(now: Date())
        XCTAssertNil(host.peerPlayback[peer.id])
        let start = Date()
        host.observePeerPlayback([.init(id: "speaker", level: 0.5)], peerID: peer.id, now: start)
        host.expirePeerPlayback(now: start.addingTimeInterval(7))
        XCTAssertNil(host.peerPlayback[peer.id])
        XCTAssertNil(host.activity.modes[HubStore.remoteComponentID(peer: peer.id, component: "speaker")])
    }

    func testPlaybackSnapshotExcludesRecordingMirroredAndStaleActivity() {
        let activity = DeviceAudioActivity()
        let pcm = Data([1, 0, 2, 0])
        activity.showStreamLevel("speaker", pcm: pcm, recording: false)
        activity.showStreamLevel("microphone", pcm: pcm, recording: true)
        activity.showPeerPlayback("remote:peer:speaker", level: 0.8)
        let ids: Set<String> = ["speaker", "microphone", "remote:peer:speaker"]
        XCTAssertEqual(activity.playbackSnapshot(ids: ids).map(\.id), ["speaker"])
        XCTAssertTrue(activity.playbackSnapshot(ids: ids, now: Date().addingTimeInterval(3)).isEmpty)
    }

    func testRoomKeepsRememberedSpeakerVisibleAfterPeerDisconnects() throws {
        let (host, _, peer) = try fixture()
        var speaker = LocalAudioDevice(id: "speaker", name: "Speaker", icon: "speaker", detail: "", status: "")
        speaker.connection = .builtIn; speaker.isAvailable = true
        host.observePeerAudioDevices([speaker], peerID: peer.id)
        host.observePeerPlayback([.init(id: speaker.id, level: 0.5)], peerID: peer.id)
        host.observeNearby([])
        host.refreshPeerInventories(now: Date())
        XCTAssertEqual(host.displayedPeerDevices(peer.id).map(\.id), [speaker.id])
        XCTAssertEqual(host.displayedPeerDevices(peer.id).first?.isAvailable, false)
        XCTAssertNil(host.peerPlayback[peer.id])
    }

    func testPartialMicrophoneInventoryDoesNotEraseRememberedSpeaker() throws {
        let (host, _, peer) = try fixture()
        var speaker = LocalAudioDevice(id: "speaker", name: "Speaker", icon: "speaker", detail: "", status: "")
        speaker.connection = .builtIn; speaker.hasOutput = true
        var microphone = LocalAudioDevice(id: "mic", name: "Microphone", icon: "mic", detail: "", status: "")
        microphone.connection = .builtIn; microphone.hasInput = true
        host.observePeerAudioDevices([speaker, microphone], peerID: peer.id)
        host.observePeerAudioDevices([microphone], peerID: peer.id)
        host.observePeerAudioDevices([], peerID: peer.id)
        XCTAssertEqual(Set(host.displayedPeerDevices(peer.id).map(\.id)), ["speaker", "mic"])
    }

    func testPhoneSpeakerStaysInInventoryWhileHeadphonesAreSelected() {
        var headphones = LocalAudioDevice(id: "headphones", name: "AirPods", icon: "headphones", detail: "", status: "")
        headphones.connection = .bluetooth; headphones.hasOutput = true; headphones.selectedOutput = true
        let devices = AudioDeviceInventory.phoneInventory([headphones], name: "iPhone")
        let speaker = devices.first { $0.id == AudioDeviceInventory.phoneSpeakerID }
        XCTAssertEqual(speaker?.hasOutput, true)
        XCTAssertEqual(speaker?.isAvailable, false, "Do not route audio to a speaker iOS has not selected")
        XCTAssertEqual(speaker?.selectedOutput, false)
        var selected = speaker!
        selected.isAvailable = true; selected.selectedOutput = true
        let changed = AudioDeviceInventory.phoneInventory([selected], name: "iPhone")
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed.first?.selectedOutput, true)
    }
}
