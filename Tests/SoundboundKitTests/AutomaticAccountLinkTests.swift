import XCTest
import Security
@testable import SoundboundKit

final class AutomaticAccountLinkTests: XCTestCase {
    private var signingKey: SecKey!
    private var appleKey: AppleAccountProof.Key!

    override func setUpWithError() throws {
        signingKey = try XCTUnwrap(SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048
        ] as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(signingKey))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        appleKey = AppleAccountProof.Key(kid: "test", n: der.subdata(in: 9..<265).url64, e: der.suffix(3).url64)
    }

    private func token(for identity: Identity, subject: String = "my-apple-account", age: TimeInterval = 60) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "test"]).url64
        let body = try JSONSerialization.data(withJSONObject: [
            "iss": "https://appleid.apple.com", "aud": "app.soundbound.ios", "sub": subject,
            "iat": Date().timeIntervalSince1970 - age, "nonce": AppleAccountProof.nonce(forDevice: identity.publicKey)
        ]).url64
        let signature = try XCTUnwrap(SecKeyCreateSignature(signingKey, .rsaSignatureMessagePKCS1v15SHA256,
            Data((header + "." + body).utf8) as CFData, nil)) as Data
        return header + "." + body + "." + signature.url64
    }

    private func store(subject: String = "my-apple-account") throws -> HubStore {
        let identity = try Identity(ephemeral: true)
        let store = HubStore(identity: identity, defaults: UserDefaults(suiteName: "account-link-test." + UUID().uuidString)!)
        let proof = try token(for: identity, subject: subject)
        store.accountID = { subject }; store.accountProof = { proof }
        store.appleKeyCache = ([appleKey], Date())
        store.setDiscovery(true)
        addTeardownBlock { store.setDiscovery(false) }
        return store
    }

    private func nearby(_ store: HubStore) throws -> NearbyPeer {
        let (_, invitation) = try SignedEnvelope.from(link: store.inviteLink)
        return NearbyPeer(invitation: invitation, link: store.inviteLink, endpoint: LocalEndpoint(host: "127.0.0.1", port: 9))
    }

    private func probe(from sender: HubStore, to receiver: HubStore) throws -> AccountLinkProbe {
        let (_, invitation) = try SignedEnvelope.from(link: receiver.inviteLink)
        return AccountLinkProbe(recipient: receiver.deviceID, peer: sender.card, inviteNonce: invitation.nonce,
            hint: HubStore.accountHint(subject: try XCTUnwrap(sender.accountID()), sender: sender.deviceID, recipient: receiver.deviceID))
    }

    private func challengedRequest(from sender: HubStore, to receiver: HubStore) throws -> AccountLinkRequest {
        let probe = try probe(from: sender, to: receiver)
        var result: SignedEnvelope?
        receiver.receive(try XCTUnwrap(sender.identity).sign(probe)) { result = $0 }
        let challenge = try XCTUnwrap(result).verified(as: AccountLinkChallenge.self)
        return AccountLinkRequest(id: probe.id, recipient: receiver.deviceID, peer: sender.card,
            challenge: challenge.challenge, proof: try XCTUnwrap(sender.accountProof()))
    }

    func testDiscoveryLinksBothDevicesWithoutManualPairingAndReconcilesAccountOwnership() throws {
        let mac = try store(), phone = try store()
        var exchanges = 0
        mac.accountLinkTransport = { envelope, _, completion in
            exchanges += 1
            phone.receive(envelope) { completion(.success($0)) }
        }
        mac.observeNearby([try nearby(phone)])
        XCTAssertEqual(exchanges, 2)
        XCTAssertEqual(mac.ownDevices.map(\.id), [phone.deviceID])
        XCTAssertEqual(phone.ownDevices.map(\.id), [mac.deviceID])
        XCTAssertTrue(mac.requests.isEmpty); XCTAssertTrue(phone.requests.isEmpty)
        XCTAssertEqual(mac.automaticAccountPeers[phone.deviceID], "my-apple-account")
        XCTAssertEqual(phone.automaticAccountPeers[mac.deviceID], "my-apple-account")
        // The regular signed inventory protocol can now return speakers and rooms.
        var speaker = LocalAudioDevice(id: "speaker", name: "Phone speaker", icon: "speaker", detail: "", status: "")
        speaker.hasOutput = true; phone.reportedAudioDevices = [speaker]
        let inventory = InventoryRequest(recipient: phone.deviceID)
        var reply: SignedEnvelope?
        phone.receive(try XCTUnwrap(mac.identity).sign(inventory)) { reply = $0 }
        XCTAssertEqual(try XCTUnwrap(reply).verified(as: InventoryReply.self).devices.map(\.id), ["speaker"])
        mac.refreshAccountDevices()
        XCTAssertEqual(exchanges, 2, "Already-linked devices must not be probed repeatedly")
    }

    func testDifferentAccountsExchangeNoProofAndGainNoAccess() throws {
        let mac = try store(), stranger = try store(subject: "other-account")
        let request = try probe(from: stranger, to: mac)
        mac.receive(try XCTUnwrap(stranger.identity).sign(request)) { _ in XCTFail("No challenge for a different account") }
        XCTAssertTrue(mac.friends.isEmpty); XCTAssertTrue(mac.requests.isEmpty)
    }

    func testAlreadyPairedDevicesRepairMissingAccountVerification() throws {
        let mac = try store(), phone = try store()
        mac.recordFriend(phone.card); phone.recordFriend(mac.card)
        XCTAssertFalse(mac.isOwnDevice(phone.deviceID))
        var exchanges = 0
        mac.accountLinkTransport = { envelope, _, completion in
            exchanges += 1
            phone.receive(envelope) { completion(.success($0)) }
        }
        mac.inventoryTransport = { _, _, _, _ in }
        mac.observeNearby([try nearby(phone)])
        XCTAssertEqual(exchanges, 2)
        XCTAssertTrue(mac.isOwnDevice(phone.deviceID))
        XCTAssertTrue(phone.isOwnDevice(mac.deviceID))
        mac.refreshAccountDevices()
        XCTAssertEqual(exchanges, 2, "Verified devices should not keep repeating the handshake")
    }

    func testRoomCommandVerifiesOwnerWithoutWaitingForInventory() throws {
        let mac = try store(), phone = try store()
        phone.recordFriend(mac.card)
        phone.addRoom(name: "Phone room", region: "Home", policy: .invite)
        let room = try XCTUnwrap(phone.rooms.first)
        XCTAssertFalse(phone.isOwnDevice(mac.deviceID))
        XCTAssertNil(phone.peerAudioDevices[mac.deviceID])
        let request = RoomComponentRequest(sender: mac.deviceID, recipient: phone.deviceID,
            roomID: room.id, component: "newly-connected-airpods", included: true,
            host: mac.deviceID, accountProof: mac.accountProof())
        var reply: RoomComponentReply?
        phone.receive(try XCTUnwrap(mac.identity).sign(request)) { reply = try? $0.verified(as: RoomComponentReply.self) }
        XCTAssertEqual(reply?.accepted, true)
        XCTAssertTrue(phone.isOwnDevice(mac.deviceID))
        let key = HubStore.remoteComponentID(peer: mac.deviceID, component: request.component)
        XCTAssertTrue(phone.audioMemberships[key]?.contains(room.id) == true)
        phone.receive(try XCTUnwrap(mac.identity).sign(request)) { _ in XCTFail("Replayed command") }
    }

    func testRoomEditsVerifyProofAndRejectDifferentAccountsAndStolenProofs() throws {
        let phone = try store(), mac = try store(), stranger = try store(subject: "someone-else")
        phone.recordFriend(mac.card); phone.recordFriend(stranger.card)
        phone.addRoom(name: "Original", region: "Home", policy: .invite)
        let room = try XCTUnwrap(phone.rooms.first)
        var updated = room; updated.name = "Updated"
        func edit(from sender: HubStore, proof: String?) throws -> Bool? {
            let request = RoomEditRequest(sender: sender.deviceID, recipient: phone.deviceID,
                roomID: room.id, room: updated, accountProof: proof)
            var accepted: Bool?
            phone.receive(try XCTUnwrap(sender.identity).sign(request)) {
                accepted = try? $0.verified(as: RoomComponentReply.self).accepted
            }
            return accepted
        }
        XCTAssertEqual(try edit(from: stranger, proof: stranger.accountProof()), false)
        XCTAssertEqual(try edit(from: stranger, proof: mac.accountProof()), false)
        XCTAssertEqual(phone.rooms.first?.name, "Original")
        XCTAssertEqual(try edit(from: mac, proof: mac.accountProof()), true)
        XCTAssertEqual(phone.rooms.first?.name, "Updated")
        XCTAssertEqual(phone.rooms.first?.owner, phone.deviceID)
        // An old verified link must not override a newly supplied different account.
        updated.name = "Should not apply"
        let different = try token(for: XCTUnwrap(mac.identity), subject: "different-account")
        XCTAssertEqual(try edit(from: mac, proof: different), false)
        XCTAssertEqual(phone.rooms.first?.name, "Updated")
    }

    func testUnverifiedGuestCannotAddAnUnreportedComponent() throws {
        let phone = try store(), stranger = try store(subject: "someone-else")
        phone.recordFriend(stranger.card)
        phone.addRoom(name: "Room", region: "Home", policy: .invite)
        let room = try XCTUnwrap(phone.rooms.first)
        phone.setGuest(stranger.deviceID, role: .control, in: room.id)
        let request = RoomComponentRequest(sender: stranger.deviceID, recipient: phone.deviceID,
            roomID: room.id, component: "unknown", included: true,
            host: stranger.deviceID, accountProof: stranger.accountProof())
        var accepted: Bool?
        phone.receive(try XCTUnwrap(stranger.identity).sign(request)) {
            accepted = try? $0.verified(as: RoomComponentReply.self).accepted
        }
        XCTAssertEqual(accepted, false)
        XCTAssertTrue(phone.audioMemberships.isEmpty)
    }

    func testFirstInventoriesFlowBothWaysOnlyAfterMutualAccountTrust() throws {
        let mac = try store(), phone = try store()
        mac.reportedAudioDevices = [LocalAudioDevice(id: "mac-speaker", name: "Mac speaker", icon: "speaker", detail: "", status: "")]
        phone.reportedAudioDevices = [LocalAudioDevice(id: "phone-speaker", name: "Phone speaker", icon: "speaker", detail: "", status: "")]
        // Let the Mac initiate; the Phone's competing probe need not finish.
        phone.accountLinkTransport = { _, _, _ in }
        phone.observeNearby([try nearby(mac)])
        var exchangedProofs = false
        let reverseInventory = expectation(description: "Phone received Mac inventory")
        phone.inventoryTransport = { envelope, _, timeout, completion in
            XCTAssertTrue(exchangedProofs, "Responder must not request inventory before returning its proof")
            XCTAssertTrue(mac.isOwnDevice(phone.deviceID))
            XCTAssertEqual(timeout, 5)
            mac.receive(envelope) { completion(.success($0)) }
            reverseInventory.fulfill()
        }
        mac.inventoryTransport = { envelope, _, _, completion in
            XCTAssertTrue(phone.isOwnDevice(mac.deviceID))
            phone.receive(envelope) { completion(.success($0)) }
        }
        mac.accountLinkTransport = { envelope, _, completion in
            phone.receive(envelope) { reply in
                if (try? reply.verified(as: AccountLinkReply.self)) != nil { exchangedProofs = true }
                completion(.success(reply))
            }
        }
        mac.observeNearby([try nearby(phone)])
        wait(for: [reverseInventory], timeout: 2)
        XCTAssertEqual(mac.peerAudioDevices[phone.deviceID]?.map(\.id), ["phone-speaker"])
        XCTAssertEqual(phone.peerAudioDevices[mac.deviceID]?.map(\.id), ["mac-speaker"])
    }

    func testSameHintCannotHideADifferentSignedAccountOrWrongReplyIdentity() throws {
        let mac = try store(), phone = try store()
        var request = try challengedRequest(from: phone, to: mac)
        request.proof = try token(for: XCTUnwrap(phone.identity), subject: "another-account")
        mac.receive(try XCTUnwrap(phone.identity).sign(request)) { _ in XCTFail("Signed subject must match") }
        XCTAssertTrue(mac.friends.isEmpty)
        let forged = AccountLinkReply(requestID: request.id, recipient: phone.deviceID, peer: mac.card,
            proof: try XCTUnwrap(mac.accountProof()))
        var completed = false
        phone.acceptAccountLinkReply(try XCTUnwrap(phone.identity).sign(forged), request: request, expected: mac.card,
            subject: "my-apple-account", proof: try XCTUnwrap(phone.accountProof())) { completed = true }
        XCTAssertTrue(completed); XCTAssertTrue(phone.friends.isEmpty)
    }

    func testLocalProofMustBeCurrentAndBoundToTheCurrentInstallation() throws {
        let device = try Identity(ephemeral: true), other = try Identity(ephemeral: true)
        let proof = try token(for: device)
        XCTAssertTrue(AppleAccountProof.isBound(proof, to: device.publicKey))
        XCTAssertFalse(AppleAccountProof.isBound(proof, to: other.publicKey))
        XCTAssertFalse(AppleAccountProof.isBound(try token(for: device, age: 181 * 86400), to: device.publicKey))
    }

    func testMatchingHintDoesNotGrantTrustAndStolenProofDoesNotWorkWithAnotherDeviceKey() throws {
        let mac = try store(), stranger = try store()
        var request = try challengedRequest(from: stranger, to: mac)
        XCTAssertTrue(mac.friends.isEmpty, "Matching an account hint alone grants nothing")
        request.proof = try token(for: XCTUnwrap(mac.identity))
        mac.receive(try XCTUnwrap(stranger.identity).sign(request)) { _ in XCTFail("Proof bound to a different key") }
        XCTAssertTrue(mac.friends.isEmpty)
    }

    func testExpiredOrForgedProofCannotAutoLink() throws {
        for expired in [false, true] {
            let mac = try store(), phone = try store()
            var request = try challengedRequest(from: phone, to: mac)
            request.proof = expired ? try token(for: XCTUnwrap(phone.identity), age: 181 * 86_400) : "forged.token.signature"
            mac.receive(try XCTUnwrap(phone.identity).sign(request)) { _ in XCTFail("Invalid proof") }
            XCTAssertTrue(mac.friends.isEmpty)
        }
    }

    func testChallengeIsSingleUseAndWrongRecipientCannotLink() throws {
        let mac = try store(), phone = try store()
        let request = try challengedRequest(from: phone, to: mac)
        var wrong = request; wrong.recipient = "another-device"
        mac.receive(try XCTUnwrap(phone.identity).sign(wrong)) { _ in XCTFail("Wrong recipient") }
        XCTAssertTrue(mac.friends.isEmpty)
        let envelope = try XCTUnwrap(phone.identity).sign(request)
        var replies = 0
        mac.receive(envelope) { _ in replies += 1 }
        mac.receive(envelope) { _ in XCTFail("Replayed challenge") }
        XCTAssertEqual(replies, 1); XCTAssertEqual(mac.ownDevices.count, 1)
    }

    func testSigningOutOrChangingAccountRevokesAutomaticTrustButKeepsManualPeers() throws {
        let mac = try store(), phone = try store()
        let request = try challengedRequest(from: phone, to: mac)
        mac.receive(try XCTUnwrap(phone.identity).sign(request)) { _ in }
        let manual = try Identity(ephemeral: true)
        mac.recordFriend(PeerCard(publicKey: manual.publicKey, name: "Friend", kind: "mac"))
        mac.accountID = { "different-account" }
        mac.refreshAccountDevices()
        XCTAssertEqual(mac.friends.map(\.id), [manual.id])
        XCTAssertTrue(mac.automaticAccountPeers.isEmpty)
        XCTAssertFalse(mac.isOwnDevice(phone.deviceID))
        phone.accountID = { nil }; phone.accountProof = { nil }
        phone.refreshAccountDevices()
        XCTAssertTrue(phone.friends.isEmpty)
    }

    func testRemoteSignOutRevokesTrustAndExplicitRemovalDoesNotImmediatelyRelink() throws {
        let mac = try store(), phone = try store()
        let request = try challengedRequest(from: phone, to: mac)
        mac.receive(try XCTUnwrap(phone.identity).sign(request)) { _ in }
        mac.observeAccountProof(nil, from: phone.deviceID, publicKey: phone.card.publicKey)
        XCTAssertTrue(mac.friends.isEmpty)
        XCTAssertFalse(mac.ignoredAccountPeers.contains(phone.deviceID), "Sign-out must allow a future sign-in")
        // Create another fresh challenge after the inbound rate limit.
        mac.accountLinkInbound = [:]
        let next = try challengedRequest(from: phone, to: mac)
        mac.receive(try XCTUnwrap(phone.identity).sign(next)) { _ in }
        mac.removeFriend(phone.deviceID)
        XCTAssertTrue(mac.ignoredAccountPeers.contains(phone.deviceID))
        mac.accountLinkTransport = { _, _, _ in XCTFail("Removed device must not reappear automatically") }
        mac.observeNearby([try nearby(phone)])
        XCTAssertTrue(mac.friends.isEmpty)
    }

    func testSignOutDuringVerificationOrDiscoveryOptOutCannotAddDevice() throws {
        let mac = try store(), phone = try store()
        let request = try challengedRequest(from: phone, to: mac)
        mac.appleKeyCache = nil
        mac.appleKeyWaiters = [{ _ in }] // Simulate an in-flight Apple key fetch without network.
        mac.receive(try XCTUnwrap(phone.identity).sign(request)) { _ in XCTFail("Late account verification") }
        XCTAssertEqual(mac.appleKeyWaiters.count, 2)
        mac.accountID = { nil }; mac.accountProof = { nil }
        let callbacks = mac.appleKeyWaiters; mac.appleKeyWaiters = []
        callbacks.forEach { $0([appleKey]) }
        XCTAssertTrue(mac.friends.isEmpty)
        phone.setDiscovery(false)
        phone.refreshAccountDevices()
        XCTAssertFalse(phone.discovering, "Background ticks must respect discovery opt-out")
    }

    func testDisablingAndReenablingDiscoveryInvalidatesPendingVerification() throws {
        let mac = try store(), phone = try store()
        let request = try challengedRequest(from: phone, to: mac)
        mac.appleKeyCache = nil; mac.appleKeyWaiters = [{ _ in }]
        mac.receive(try XCTUnwrap(phone.identity).sign(request)) { _ in XCTFail("Stale discovery generation") }
        mac.setDiscovery(false); mac.setDiscovery(true)
        let callbacks = mac.appleKeyWaiters; mac.appleKeyWaiters = []
        callbacks.forEach { $0([appleKey]) }
        XCTAssertTrue(mac.friends.isEmpty)
    }

    func testStartupCredentialCheckKeepsRememberedDevicesWithoutOpeningDiscovery() throws {
        let mac = try store(), phone = try store()
        let request = try challengedRequest(from: phone, to: mac)
        mac.receive(try XCTUnwrap(phone.identity).sign(request)) { _ in }
        mac.setDiscovery(false)
        mac.accountReady = { false }; mac.accountID = { nil }
        mac.refreshAccountDevices(); mac.setDiscovery(true)
        XCTAssertEqual(mac.friends.map(\.id), [phone.deviceID])
        XCTAssertFalse(mac.discovering)
        // A resolved sign-out, unlike an in-flight credential check, removes the link.
        mac.accountReady = { true }; mac.refreshAccountDevices()
        XCTAssertTrue(mac.friends.isEmpty)
    }
}
