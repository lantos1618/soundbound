import XCTest
@testable import SoundboundKit

final class PairingTests: XCTestCase {
    private func store() throws -> HubStore {
        let defaults = UserDefaults(suiteName: "app.soundbound.test.\(UUID().uuidString)")!
        return HubStore(identity: try Identity(ephemeral: true), defaults: defaults)
    }
    func testPairingRequiresExplicitApprovalAndRejectsReplay() throws {
        let host = try store(), guest = try Identity(ephemeral: true)
        let (_, invitation) = try SignedEnvelope.from(link: host.inviteLink)
        let card = PeerCard(publicKey: guest.publicKey, name: "Guest phone", kind: "iphone")
        let request = JoinMessage(requestID: UUID().uuidString, inviteNonce: invitation.nonce, peer: card, created: Date())
        let envelope = try guest.sign(request)
        var reply: SignedEnvelope?
        host.receive(envelope) { reply = $0 }
        XCTAssertEqual(host.requests.count, 1)
        XCTAssertTrue(host.friends.isEmpty)
        XCTAssertNil(reply)
        host.decide(try XCTUnwrap(host.requests.first), approve: true)
        XCTAssertEqual(host.friends.first?.id, card.id)
        XCTAssertTrue(try XCTUnwrap(reply).verified(as: JoinReply.self).approved)
        host.receive(envelope) { _ in XCTFail("Replay must not be accepted") }
        XCTAssertTrue(host.requests.isEmpty)
    }
    func testDevicesCanJoinMultipleRoomsAndLeaveOne() throws {
        let hub = try store()
        hub.addRoom(name: "One", region: "Home", policy: .request)
        hub.addRoom(name: "Two", region: "Home", policy: .request)
        let one = hub.rooms[0].id, two = hub.rooms[1].id
        hub.moveDevice(to: one); hub.moveDevice(to: two)
        XCTAssertEqual(hub.deviceRooms, Set([one, two]))
        hub.removeDevice(from: one)
        XCTAssertEqual(hub.deviceRooms, Set([two]))
        hub.moveAudioDevice("headset", to: one); hub.moveAudioDevice("headset", to: two)
        XCTAssertEqual(hub.audioMemberships["headset"], Set([one, two]))
        hub.removeAudioDevice("headset", from: one)
        XCTAssertEqual(hub.audioMemberships["headset"], Set([two]))
    }

    func testOnlyPairedPeersCanBeGroupedAndGroupingPersists() throws {
        let defaults = UserDefaults(suiteName: "app.soundbound.peer-test.\(UUID().uuidString)")!
        let identity = try Identity(ephemeral: true)
        let host = HubStore(identity: identity, defaults: defaults)
        let guest = try Identity(ephemeral: true)
        let card = PeerCard(publicKey: guest.publicKey, name: "Phone", kind: "iphone")
        host.addRoom(name: "Desk", region: "Home", policy: .request)
        let room = try XCTUnwrap(host.rooms.first)
        host.movePeer(card.id, to: room.id)
        XCTAssertNil(host.peerRooms[card.id])
        let (_, invitation) = try SignedEnvelope.from(link: host.inviteLink)
        let message = JoinMessage(requestID: UUID().uuidString, inviteNonce: invitation.nonce, peer: card, created: Date())
        host.receive(try guest.sign(message)) { _ in }
        host.decide(try XCTUnwrap(host.requests.first), approve: true)
        host.movePeer(card.id, to: room.id)
        host.addRoom(name: "Second", region: "Home", policy: .request)
        let second = host.rooms[1].id
        host.movePeer(card.id, to: second)
        XCTAssertEqual(host.peerMemberships[card.id], Set([room.id, second]))
        host.removePeer(card.id, from: second)
        XCTAssertEqual(host.peerMemberships[card.id], Set([room.id]))
        XCTAssertEqual(host.peerRooms[card.id], room.id)
        let restored = HubStore(identity: identity, defaults: defaults)
        XCTAssertEqual(restored.peerRooms[card.id], room.id)
        restored.movePeer(card.id, to: "unknown-room")
        XCTAssertEqual(restored.peerRooms[card.id], room.id)
        restored.movePeer(card.id, to: nil)
        XCTAssertNil(restored.peerRooms[card.id])
    }

    func testDecliningDoesNotAddFriend() throws {
        let host = try store(), guest = try Identity(ephemeral: true)
        let (_, invite) = try SignedEnvelope.from(link: host.inviteLink)
        let card = PeerCard(publicKey: guest.publicKey, name: "Guest", kind: "mac")
        let message = JoinMessage(requestID: UUID().uuidString, inviteNonce: invite.nonce, peer: card, created: Date())
        var response: SignedEnvelope?
        host.receive(try guest.sign(message)) { response = $0 }
        host.decide(try XCTUnwrap(host.requests.first), approve: false)
        XCTAssertTrue(host.friends.isEmpty)
        XCTAssertFalse(try XCTUnwrap(response).verified(as: JoinReply.self).approved)
    }
    func testWrongIdentityCannotRequestAsSomeoneElse() throws {
        let host = try store(), signer = try Identity(ephemeral: true), victim = try Identity(ephemeral: true)
        let (_, invite) = try SignedEnvelope.from(link: host.inviteLink)
        let message = JoinMessage(requestID: UUID().uuidString, inviteNonce: invite.nonce,
            peer: PeerCard(publicKey: victim.publicKey, name: "Victim", kind: "mac"), created: Date())
        host.receive(try signer.sign(message)) { _ in XCTFail("Spoofed request accepted") }
        XCTAssertTrue(host.requests.isEmpty)
    }
    func testMovingDeviceDoesNotAllowUnknownRoom() throws {
        let hub = try store()
        hub.moveDevice(to: "unapproved-room")
        XCTAssertNil(hub.deviceRoom)
        hub.addRoom(name: "Desk", region: "Home", policy: .request)
        hub.moveDevice(to: hub.rooms.first?.id)
        XCTAssertEqual(hub.deviceRoom, hub.rooms.first?.id)
    }
    func testDeviceCanMoveBetweenRoomsAndBackOutWithoutEnablingOmni() throws {
        let hub = try store()
        hub.addRoom(name: "Desk", region: "Home", policy: .request)
        hub.addRoom(name: "Kitchen", region: "Home", policy: .request)
        hub.moveDevice(to: hub.rooms[0].id)
        hub.moveDevice(to: hub.rooms[1].id)
        XCTAssertEqual(hub.deviceRoom, hub.rooms[1].id)
        XCTAssertTrue(hub.rooms.allSatisfy { !$0.omni })
        hub.moveDevice(to: nil)
        XCTAssertNil(hub.deviceRoom)
    }

    func testAudioRoomAssignmentPersistsAndRejectsUnknownRoom() throws {
        let defaults = UserDefaults(suiteName: "app.soundbound.test.\(UUID().uuidString)")!
        let identity = try Identity(ephemeral: true)
        let hub = HubStore(identity: identity, defaults: defaults)
        hub.addRoom(name: "Desk", region: "Home", policy: .request)
        let room = try XCTUnwrap(hub.rooms.first)
        hub.moveAudioDevice("headphones", to: room.id)
        hub.moveAudioDevice("headphones", to: "not-approved")
        XCTAssertEqual(hub.audioRooms["headphones"], room.id)
        let restored = HubStore(identity: identity, defaults: defaults)
        XCTAssertEqual(restored.audioRooms["headphones"], room.id)
        restored.moveAudioDevice("headphones", to: nil)
        XCTAssertNil(restored.audioRooms["headphones"])
    }

}

final class DevicePolicyTests: XCTestCase {
    private func makeStore() throws -> HubStore {
        HubStore(identity: try Identity(ephemeral: true), defaults: UserDefaults(suiteName: "app.soundbound.policy-test.\(UUID().uuidString)")!)
    }
    private func device(available: Bool, selected: Bool = false) -> LocalAudioDevice {
        var device = LocalAudioDevice(id: "headphones", name: "Headphones", icon: "headphones", detail: "", status: "")
        device.isAvailable = available
        device.selectedOutput = selected
        return device
    }
    func testRemovalWaitsForSustainedDisconnect() throws {
        let store = try makeStore()
        store.addRoom(name: "Desk", region: "Home", policy: .request)
        store.moveAudioDevice("headphones", to: store.rooms[0].id)
        var policy = AudioDevicePolicy(); policy.removeWhenDisconnected = true
        store.setPolicy(policy, for: "headphones")
        let start = Date()
        store.observeAudioDevices([device(available: true)], now: start)
        store.observeAudioDevices([device(available: false)], now: start.addingTimeInterval(1))
        store.observeAudioDevices([device(available: false)], now: start.addingTimeInterval(3))
        XCTAssertNotNil(store.audioRooms["headphones"])
        store.observeAudioDevices([device(available: false)], now: start.addingTimeInterval(4))
        XCTAssertNil(store.audioRooms["headphones"])
    }
    func testReconnectCancelsAutomaticRemoval() throws {
        let store = try makeStore()
        store.addRoom(name: "Desk", region: "Home", policy: .request)
        store.moveAudioDevice("headphones", to: store.rooms[0].id)
        var policy = AudioDevicePolicy(); policy.removeWhenDisconnected = true
        store.setPolicy(policy, for: "headphones")
        let start = Date()
        store.observeAudioDevices([device(available: false)], now: start)
        store.observeAudioDevices([device(available: true)], now: start.addingTimeInterval(2))
        store.observeAudioDevices([device(available: true)], now: start.addingTimeInterval(5))
        XCTAssertNotNil(store.audioRooms["headphones"])
    }
    func testNotificationsFollowPerDeviceSetting() throws {
        let store = try makeStore()
        store.observeAudioDevices([device(available: true)])
        XCTAssertNil(store.audioNotice)
        store.observeAudioDevices([device(available: true, selected: true)])
        XCTAssertNotNil(store.audioNotice)
        store.audioNotice = nil
        var policy = AudioDevicePolicy(); policy.notifyChanges = false
        store.setPolicy(policy, for: "headphones")
        store.observeAudioDevices([device(available: false)])
        XCTAssertNil(store.audioNotice)
    }
}
