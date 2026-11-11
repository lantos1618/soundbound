import XCTest
import CryptoKit
import Network
@testable import SoundboundKit

final class AudioMeshTests: XCTestCase {
    func testDirectionalKeyAgreementAndEncryptedAudio() throws {
        let source = Curve25519.KeyAgreement.PrivateKey(), sink = Curve25519.KeyAgreement.PrivateKey()
        let a = try AudioSessionCipher.keys(privateKey: source, remote: sink.publicKey.rawRepresentation.url64,
                                            session: "session", source: "source", sink: "sink")
        let b = try AudioSessionCipher.keys(privateKey: sink, remote: source.publicKey.rawRepresentation.url64,
                                            session: "session", source: "source", sink: "sink")
        var sender = AudioSessionCipher(key: a.0, context: Data("session".utf8))
        var receiver = AudioSessionCipher(key: b.0, context: Data("session".utf8))
        let pcm = Data([1, 0, 2, 0, 3, 0])
        let encrypted = try sender.seal(kind: "audio", pcm: pcm)
        XCTAssertNotEqual(encrypted, pcm)
        XCTAssertEqual(try receiver.open(encrypted).pcm, pcm)
        XCTAssertThrowsError(try receiver.open(encrypted), "Replayed packets must be rejected")
        var reflected = AudioSessionCipher(key: b.1, context: Data("session".utf8))
        XCTAssertThrowsError(try reflected.open(encrypted), "Direction keys must be distinct")
    }
    func testTamperingAndWrongSessionAreRejected() throws {
        let key = SymmetricKey(size: .bits256)
        var sender = AudioSessionCipher(key: key, context: Data("one".utf8))
        var encrypted = try sender.seal(kind: "audio", pcm: Data([0, 0]))
        var wrongSession = AudioSessionCipher(key: key, context: Data("two".utf8))
        XCTAssertThrowsError(try wrongSession.open(encrypted))
        encrypted[encrypted.count - 1] ^= 1
        var receiver = AudioSessionCipher(key: key, context: Data("one".utf8))
        XCTAssertThrowsError(try receiver.open(encrypted))
    }
    func testUnpairedSenderCannotPromptForAudio() throws {
        let identity = try Identity(ephemeral: true), stranger = try Identity(ephemeral: true)
        let own = PeerCard(publicKey: identity.publicKey, name: "Me", kind: "mac")
        let other = PeerCard(publicKey: stranger.publicKey, name: "Stranger", kind: "iphone")
        let offer = AudioOffer(id: UUID().uuidString, from: other, to: own.id,
            ephemeralKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.url64, port: 1234, created: Date())
        let mesh = AudioMesh()
        XCTAssertTrue(mesh.receive(try stranger.sign(offer), nearby: [], friends: [], identity: identity, card: own) { _ in
            XCTFail("Unpaired sender should not receive a grant")
        })
        XCTAssertNil(mesh.incoming)
        XCTAssertFalse(mesh.active)
    }
    func testPairedSenderWaitsForExplicitApproval() throws {
        let identity = try Identity(ephemeral: true), guest = try Identity(ephemeral: true)
        let own = PeerCard(publicKey: identity.publicKey, name: "Me", kind: "mac")
        let other = PeerCard(publicKey: guest.publicKey, name: "Friend", kind: "iphone")
        let offer = AudioOffer(id: UUID().uuidString, from: other, to: own.id,
            ephemeralKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.url64, port: 1234, created: Date())
        let invitation = Invitation(peer: other, nonce: UUID().uuidString, expires: Date().addingTimeInterval(600))
        let peer = NearbyPeer(invitation: invitation, link: "", endpoint: LocalEndpoint(host: "localhost", port: 1234))
        let mesh = AudioMesh()
        var response: SignedEnvelope?
        _ = mesh.receive(try guest.sign(offer), nearby: [peer], friends: [KnownPeer(card: other, acceptedAt: Date())],
                         identity: identity, card: own) { response = $0 }
        XCTAssertNotNil(mesh.incoming)
        XCTAssertFalse(mesh.active)
        XCTAssertNil(response)
        mesh.decide(allow: false)
        XCTAssertFalse(try XCTUnwrap(response).verified(as: AudioReply.self).accepted)
        XCTAssertFalse(mesh.active)
    }
    func testSpecificOutputMustExistBeforePrompting() throws {
        let identity = try Identity(ephemeral: true), guest = try Identity(ephemeral: true)
        let own = PeerCard(publicKey: identity.publicKey, name: "Me", kind: "mac")
        let other = PeerCard(publicKey: guest.publicKey, name: "Friend", kind: "iphone")
        let invitation = Invitation(peer: other, nonce: UUID().uuidString, expires: Date().addingTimeInterval(600))
        let peer = NearbyPeer(invitation: invitation, link: "", endpoint: LocalEndpoint(host: "localhost", port: 1234))
        var offer = AudioOffer(id: UUID().uuidString, from: other, to: own.id,
            ephemeralKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.url64,
            port: 1234, created: Date(), source: "test-tone", outputID: "missing-output")
        offer.version = 2
        let mesh = AudioMesh()
        var response: SignedEnvelope?
        _ = mesh.receive(try guest.sign(offer), nearby: [peer], friends: [KnownPeer(card: other, acceptedAt: Date())],
                         identity: identity, card: own, devices: []) { response = $0 }
        XCTAssertNil(mesh.incoming)
        XCTAssertFalse(mesh.active)
        XCTAssertFalse(try XCTUnwrap(response).verified(as: AudioReply.self).accepted)
    }

    func testEncryptedLoopbackCarriesAudioAndStops() throws {
        let received = expectation(description: "Received encrypted audio")
        let sourceKey = SymmetricKey(size: .bits256), sinkKey = SymmetricKey(size: .bits256)
        let listener = try NWListener(using: .tcp, on: .any)
        var source: AudioMeshChannel?
        var sink: AudioMeshChannel?
        let pcm = Data([0, 0, 2, 0, 4, 0, 6, 0])
        listener.newConnectionHandler = { connection in
            let channel = AudioMeshChannel(connection: connection, sendKey: sourceKey, receiveKey: sinkKey, session: "test", source: true)
            source = channel
            channel.ready = { channel.sendAudio(pcm) }
            channel.start()
        }
        listener.stateUpdateHandler = { state in
            guard case .ready = state, let port = listener.port else { return }
            let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            let channel = AudioMeshChannel(connection: connection, sendKey: sinkKey, receiveKey: sourceKey, session: "test", source: false)
            sink = channel
            channel.audio = { data in XCTAssertEqual(data, pcm); received.fulfill() }
            channel.start()
        }
        listener.start(queue: DispatchQueue(label: "mesh-test-listener"))
        wait(for: [received], timeout: 8)
        source?.stop(); sink?.stop(); listener.cancel()
    }
}
