import XCTest
@testable import SoundboundKit

final class InvitationTests: XCTestCase {
    func testSignedInviteRoundTrip() throws {
        let identity = try Identity(ephemeral: true)
        let card = PeerCard(publicKey: identity.publicKey, name: "Test phone", kind: "iphone")
        let invitation = Invitation(peer: card, nonce: UUID().uuidString, expires: Date().addingTimeInterval(600))
        let signed = try identity.sign(invitation)
        let (_, decoded) = try SignedEnvelope.from(link: signed.link)
        XCTAssertEqual(decoded, invitation)
        XCTAssertEqual(decoded.code.count, 6)
        XCTAssertEqual(decoded.peer.id, identity.id)
    }
    func testTamperedInviteRejected() throws {
        let identity = try Identity(ephemeral: true)
        let invitation = Invitation(peer: PeerCard(publicKey: identity.publicKey, name: "Mac", kind: "mac"), nonce: UUID().uuidString, expires: Date().addingTimeInterval(600))
        let signed = try identity.sign(invitation)
        let tampered = SignedEnvelope(payload: Data("tampered".utf8).url64, signature: signed.signature, signer: signed.signer)
        XCTAssertThrowsError(try SignedEnvelope.from(link: tampered.link))
    }
    func testExpiredInviteRejected() throws {
        let identity = try Identity(ephemeral: true)
        let invite = Invitation(peer: PeerCard(publicKey: identity.publicKey, name: "Mac", kind: "mac"), nonce: UUID().uuidString, expires: Date().addingTimeInterval(-1))
        XCTAssertThrowsError(try SignedEnvelope.from(link: identity.sign(invite).link))
    }
    func testMismatchedSignerRejected() throws {
        let identity = try Identity(ephemeral: true), other = try Identity(ephemeral: true)
        let invite = Invitation(peer: PeerCard(publicKey: other.publicKey, name: "Mac", kind: "mac"), nonce: UUID().uuidString, expires: Date().addingTimeInterval(600))
        XCTAssertThrowsError(try SignedEnvelope.from(link: identity.sign(invite).link))
    }
    func testRoomDraftStartsWithNoOmniAndHalfVolume() throws {
        let room = AudioRoom(name: "Desk", region: "Home", owner: "owner")
        XCTAssertFalse(room.omni)
        XCTAssertEqual(room.level, 0.5)
        XCTAssertEqual(room.policy, .request)
    }
}
