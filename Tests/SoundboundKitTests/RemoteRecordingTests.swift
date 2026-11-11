import XCTest
@testable import SoundboundKit

final class RemoteRecordingTests: XCTestCase {
    private func setup() throws -> (HubStore, Identity, PeerCard) {
        let owner = try Identity(ephemeral: true), peer = try Identity(ephemeral: true)
        let store = HubStore(identity: owner, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let (_, invite) = try SignedEnvelope.from(link: store.inviteLink)
        let card = PeerCard(publicKey: peer.publicKey, name: "Phone", kind: "iphone")
        let join = JoinMessage(requestID: UUID().uuidString, inviteNonce: invite.nonce, peer: card, created: Date())
        store.receive(try peer.sign(join)) { _ in }
        store.decide(try XCTUnwrap(store.requests.first), approve: true)
        var microphone = LocalAudioDevice(id: "mic", name: "Mic", icon: "mic", detail: "Input", status: "Available")
        microphone.hasInput = true
        store.reportedAudioDevices = [microphone]
        return (store, peer, card)
    }
    func testPairedRequestNeedsSourceApprovalAndCannotReplay() throws {
        let (store, peer, card) = try setup()
        let request = RemoteRecordingRequest(sender: card, recipient: store.deviceID, inputID: "mic")
        let envelope = try peer.sign(request)
        var replies = 0
        XCTAssertTrue(store.receiveRecordingRequest(envelope) { _ in replies += 1 })
        XCTAssertEqual(store.recordingRequest?.id, request.id)
        XCTAssertFalse(store.mesh.active)
        store.decideRecordingRequest(allow: false)
        XCTAssertEqual(replies, 1)
        XCTAssertNil(store.recordingRequest)
        XCTAssertTrue(store.receiveRecordingRequest(envelope) { _ in replies += 1 })
        XCTAssertNil(store.recordingRequest)
        XCTAssertEqual(replies, 1)
    }
    func testStaleAndWrongRecipientCannotOpenMicrophone() throws {
        let (store, peer, card) = try setup()
        var request = RemoteRecordingRequest(sender: card, recipient: "someone-else", inputID: "mic")
        XCTAssertTrue(store.receiveRecordingRequest(try peer.sign(request)) { _ in XCTFail() })
        request.recipient = store.deviceID; request.created = Date().addingTimeInterval(-60)
        XCTAssertTrue(store.receiveRecordingRequest(try peer.sign(request)) { _ in XCTFail() })
        XCTAssertNil(store.recordingRequest)
        XCTAssertFalse(store.mesh.active)
    }
    func testMissingInputIsRejected() throws {
        let (store, peer, card) = try setup()
        let request = RemoteRecordingRequest(sender: card, recipient: store.deviceID, inputID: "missing")
        var reply: RemoteRecordingReply?
        XCTAssertTrue(store.receiveRecordingRequest(try peer.sign(request)) { reply = try? $0.verified(as: RemoteRecordingReply.self) })
        XCTAssertEqual(reply?.accepted, false)
        XCTAssertNil(store.recordingRequest)
    }
}
