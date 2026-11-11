import XCTest
@testable import SoundboundKit

final class RoomSyncTests: XCTestCase {
    private func pair(_ host: HubStore, with guest: Identity) throws {
        let (_, invite) = try SignedEnvelope.from(link: host.inviteLink)
        let card = PeerCard(publicKey: guest.publicKey, name: "Peer", kind: "mac")
        let join = JoinMessage(requestID: UUID().uuidString, inviteNonce: invite.nonce, peer: card, created: Date())
        host.receive(try guest.sign(join)) { _ in }
        host.decide(try XCTUnwrap(host.requests.first), approve: true)
    }
    private func store(_ identity: Identity) -> HubStore {
        HubStore(identity: identity, defaults: UserDefaults(suiteName: "room-sync-test." + UUID().uuidString)!)
    }
    func testMirrorsOwnerLayoutWithCorrectLocalHostAndComponentIDs() throws {
        let ownerIdentity = try Identity(ephemeral: true), phoneIdentity = try Identity(ephemeral: true)
        let owner = store(ownerIdentity), phone = store(phoneIdentity)
        try pair(owner, with: phoneIdentity); try pair(phone, with: ownerIdentity)
        owner.addRoom(name: "Studio", region: "Home", policy: .request)
        let room = try XCTUnwrap(owner.rooms.first)
        owner.moveDevice(to: room.id)
        owner.movePeer(phoneIdentity.id, to: room.id)
        owner.moveAudioDevice(HubStore.remoteComponentID(peer: phoneIdentity.id, component: "speaker"), to: room.id)
        XCTAssertTrue(phone.mergeRoomLayouts(owner.ownedRoomLayouts(), from: ownerIdentity.id))
        XCTAssertEqual(phone.rooms.first?.name, "Studio")
        XCTAssertTrue(phone.deviceRooms.contains(room.id))
        XCTAssertTrue(phone.peerMemberships[ownerIdentity.id]?.contains(room.id) == true)
        XCTAssertTrue(phone.audioMemberships["speaker"]?.contains(room.id) == true)
        var renamed = room; renamed.name = "Office"
        owner.updateRoom(renamed)
        XCTAssertTrue(phone.mergeRoomLayouts(owner.ownedRoomLayouts(), from: ownerIdentity.id))
        XCTAssertEqual(phone.rooms.first?.name, "Office")
        owner.deleteRoom(room.id)
        XCTAssertTrue(owner.rooms.isEmpty)
        XCTAssertTrue(owner.deviceRooms.isEmpty)
        XCTAssertTrue(phone.mergeRoomLayouts(owner.ownedRoomLayouts(), from: ownerIdentity.id))
        XCTAssertTrue(phone.rooms.isEmpty)
        XCTAssertFalse(phone.deviceRooms.contains(room.id))
    }
    func testUnpairedOrForgedOwnerCannotReplaceRoom() throws {
        let a = try Identity(ephemeral: true), b = try Identity(ephemeral: true)
        let host = store(a)
        host.addRoom(name: "Mine", region: "Home", policy: .request)
        let room = try XCTUnwrap(host.rooms.first)
        XCTAssertFalse(host.mergeRoomLayouts([RoomLayout(room: room, hosts: [], components: [])], from: b.id))
        try pair(host, with: b)
        XCTAssertFalse(host.mergeRoomLayouts([RoomLayout(room: room, hosts: [], components: [])], from: b.id))
        XCTAssertEqual(host.rooms.first?.owner, a.id)
    }
    func testMoveRequiresPairedSenderAndExplicitApproval() throws {
        let a = try Identity(ephemeral: true), b = try Identity(ephemeral: true)
        let host = store(a)
        let card = PeerCard(publicKey: b.publicKey, name: "Phone", kind: "iphone")
        let request = DeviceMoveRequest(sender: card, recipient: a.id, deviceName: "Headphones")
        let signed = try b.sign(request)
        host.receive(signed) { _ in XCTFail("Unpaired sender received a reply") }
        XCTAssertNil(host.deviceMoveRequest)
        try pair(host, with: b)
        var didConnect = false
        host.onApprovedDeviceMove = { _ in didConnect = true }
        host.receive(signed) { _ in }
        XCTAssertNotNil(host.deviceMoveRequest)
        XCTAssertFalse(didConnect)
        host.decideDeviceMove(approve: true)
        XCTAssertTrue(didConnect)
        host.receive(signed) { _ in XCTFail("Replay was accepted") }
        XCTAssertNil(host.deviceMoveRequest)
    }

    func testBuiltInCannotRequestHostMove() throws {
        let host = store(try Identity(ephemeral: true))
        var speaker = LocalAudioDevice(id: "speaker", name: "Speaker", icon: "speaker", detail: "", status: "")
        speaker.connection = .builtIn
        host.requestDeviceMove(speaker, to: host.deviceID)
        XCTAssertNil(host.deviceMoveRequest)
        speaker.connection = .bluetooth
        host.requestDeviceMove(speaker, to: host.deviceID)
        XCTAssertNotNil(host.deviceMoveRequest)
    }
}
