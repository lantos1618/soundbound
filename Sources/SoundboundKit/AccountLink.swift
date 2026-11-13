import Foundation
import CryptoKit
import Security

/// Proof that an Apple Account signed in on one particular Soundbound device.
///
/// At sign-in the app asks Apple to put a value derived from this device's public key into the
/// identity token (`nonce`). Apple signs the token, so anyone holding it can check, without a
/// server of ours, that account `sub` signed in on the device with that key. The token is only an
/// assertion about that one key: presented by any other device it fails the nonce check.
public enum AppleAccountProof {
    static let issuer = "https://appleid.apple.com"
    static let audiences: Set<String> = ["app.soundbound.ios", "app.soundbound.mac", "app.soundbound.web"]
    /// A proof older than this must be renewed by signing in again.
    static let maximumAge: TimeInterval = 180 * 86_400

    public struct Key: Codable, Equatable {
        public var kid: String
        public var n: String
        public var e: String
    }

    public static func nonce(forDevice publicKey: String) -> String {
        SHA256.hash(data: Data(("soundbound-device-v1:" + publicKey).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func isBound(_ token: String, to publicKey: String) -> Bool {
        let parts = token.split(separator: ".")
        guard token.utf8.count <= 4096, parts.count == 3, let data = Data(url64: String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issued = (claims["iat"] as? NSNumber)?.doubleValue else { return false }
        return claims["nonce"] as? String == nonce(forDevice: publicKey)
            && issued >= Date().timeIntervalSince1970 - maximumAge && issued <= Date().timeIntervalSince1970 + 300
    }

    /// Returns the Apple account subject when the token is genuine and bound to `devicePublicKey`.
    public static func verifiedSubject(_ token: String, devicePublicKey: String, keys: [Key], now: Date = Date()) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard token.utf8.count <= 4096, parts.count == 3,
              let headerData = Data(url64: parts[0]), let claimData = Data(url64: parts[1]), let signature = Data(url64: parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let jwk = keys.first(where: { $0.kid == kid }), let key = rsaKey(jwk),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              let claims = try? JSONSerialization.jsonObject(with: claimData) as? [String: Any],
              claims["iss"] as? String == issuer,
              let audience = claims["aud"] as? String, audiences.contains(audience),
              claims["nonce"] as? String == nonce(forDevice: devicePublicKey),
              let subject = claims["sub"] as? String, !subject.isEmpty, subject.count <= 255,
              let issued = (claims["iat"] as? NSNumber)?.doubleValue,
              issued <= now.timeIntervalSince1970 + 300,
              issued >= now.timeIntervalSince1970 - maximumAge else { return nil }
        return subject
    }

    static func rsaKey(_ key: Key) -> SecKey? {
        guard let modulus = Data(url64: key.n), let exponent = Data(url64: key.e),
              (256...1024).contains(modulus.count), (1...8).contains(exponent.count) else { return nil }
        func length(_ count: Int) -> [UInt8] {
            if count < 128 { return [UInt8(count)] }
            var bytes: [UInt8] = [], value = count
            while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
        func integer(_ data: Data) -> [UInt8] {
            var bytes = Array(data.drop { $0 == 0 })
            if bytes.isEmpty { bytes = [0] }
            if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
            return [0x02] + length(bytes.count) + bytes
        }
        let body = integer(modulus) + integer(exponent)
        let der = Data([0x30] + length(body.count) + body)
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }
}

struct RoomEditRequest: Codable {
    var kind = "room-edit-request"
    var id = UUID().uuidString
    var sender: String
    var recipient: String
    var roomID: String
    /// The room as it should now be. Nil deletes the room.
    var room: AudioRoom?
    var created = Date()
    var accountProof: String? = nil
}

struct LinkedAccount: Codable, Equatable {
    var subject: String
    var proofHash: String
    var validUntil: Date? = nil
}

// The first exchange discloses only a pair-specific account hint. It grants no trust.
// Full proofs are exchanged only after a matching hint and a fresh signed challenge.
struct AccountLinkProbe: Codable {
    var kind = "account-link-probe"
    var id = UUID().uuidString
    var recipient: String
    var peer: PeerCard
    var inviteNonce: String
    var hint: String
    var created = Date()
}
struct AccountLinkChallenge: Codable {
    var kind = "account-link-challenge"
    var requestID: String
    var recipient: String
    var challenge: String
    var created = Date()
}
struct AccountLinkRequest: Codable {
    var kind = "account-link-request"
    var id: String
    var recipient: String
    var peer: PeerCard
    var challenge: String
    var proof: String
    var created = Date()
}
struct AccountLinkReply: Codable {
    var kind = "account-link-reply"
    var requestID: String
    var recipient: String
    var peer: PeerCard
    var proof: String
    var created = Date()
}
struct AccountLinkChallengeState {
    var requestID: String
    var peer: PeerCard
    var account: String
    var proof: String
    var expires: Date
}

extension HubStore {
    private static let linkedKey = "Soundbound.linkedAccounts.v1"

    /// True when that paired device is signed in to the same Apple Account as this one,
    /// proven by an Apple-signed token bound to its device key.
    public func isOwnDevice(_ peerID: String) -> Bool {
        guard let mine = accountID(), let theirs = linkedAccounts[peerID],
              theirs.validUntil.map({ $0 > Date() }) ?? true else { return false }
        return mine == theirs.subject
    }
    /// The owner's device, or another device of the same person.
    public func canAdminister(_ room: AudioRoom) -> Bool { room.owner == deviceID || isOwnDevice(room.owner) }
    public var ownDevices: [KnownPeer] { friends.filter { isOwnDevice($0.id) } }

    private func saveLinkedAccounts() {
        if let data = try? JSONEncoder().encode(linkedAccounts) { defaults.set(data, forKey: Self.linkedKey) }
    }
    static func accountHint(subject: String, sender: String, recipient: String) -> String {
        SHA256.hash(data: Data(["soundbound-account-link-v1", subject, sender, recipient].joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    private static func linkedAccount(subject: String, proof: String) -> LinkedAccount {
        let parts = proof.split(separator: ".")
        let claims = parts.count == 3 ? Data(url64: String(parts[1])).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } : nil
        let issued = (claims?["iat"] as? NSNumber)?.doubleValue ?? 0
        return LinkedAccount(subject: subject,
            proofHash: SHA256.hash(data: Data(proof.utf8)).map { String(format: "%02x", $0) }.joined(),
            validUntil: Date(timeIntervalSince1970: issued + AppleAccountProof.maximumAge))
    }
    func forgetAccountPeer(_ id: String) {
        automaticAccountPeers[id] = nil
        linkedAccounts[id] = nil
        latestAccountProof[id] = nil
        accountLinkAttempts[id] = nil
        defaults.set(automaticAccountPeers, forKey: "Soundbound.automaticAccountPeers.v1")
        saveLinkedAccounts()
    }
    private func revokeAutomaticPeer(_ id: String) {
        guard automaticAccountPeers[id] != nil else { return }
        _ = mergeRoomLayouts([], from: id)
        // Revocation must not add the device to the user's explicit removal list.
        forgetAccountPeer(id)
        removeFriend(id)
    }
    private func rememberAutomaticPeer(_ peer: PeerCard, subject: String, proof: String) {
        if !friends.contains(where: { $0.id == peer.id }) {
            automaticAccountPeers[peer.id] = subject
            defaults.set(automaticAccountPeers, forKey: "Soundbound.automaticAccountPeers.v1")
        }
        linkedAccounts[peer.id] = Self.linkedAccount(subject: subject, proof: proof)
        saveLinkedAccounts()
        recordFriend(peer)
        lastInventoryRefresh = .distantPast
    }

    /// Called on sign-in changes, discovery changes and the ordinary one-second UI tick.
    func refreshAccountDevices(now: Date = Date()) {
        // During launch, keep remembered devices while Apple checks the stored
        // credential. The listener is not restored until that check finishes.
        guard accountReady() else { return }
        let subject = accountID(), proof = accountProof()
        if accountLinkAccount != subject || accountLinkProof != proof {
            accountLinkAccount = subject; accountLinkProof = proof
            accountLinkGeneration = UUID(); accountLinkInbound.removeAll()
            accountLinkAttempts.removeAll(); accountLinkLastAttempt.removeAll(); accountLinkChallenges.removeAll()
            for (id, owner) in automaticAccountPeers where owner != subject { revokeAutomaticPeer(id) }
            // A fresh sign-in is enough to discover this person's devices. An explicit
            // discovery opt-out persists across launches and is never undone by the tick.
        }
        if subject != nil, proof != nil, !discovering,
           !defaults.bool(forKey: "Soundbound.accountDiscoveryDisabled"), identity != nil {
            setDiscovery(true)
        }
        for id in Array(automaticAccountPeers.keys) {
            if linkedAccounts[id]?.validUntil.map({ $0 <= now }) ?? true { revokeAutomaticPeer(id) }
        }
        guard discovering, let identity, let subject, let proof else { return }
        accountLinkLastAttempt = accountLinkLastAttempt.filter { now.timeIntervalSince($0.value) < 60 }
        for peer in nearby.prefix(64) where !isOwnDevice(peer.id) && !ignoredAccountPeers.contains(peer.id) {
            guard accountLinkAttempts[peer.id] == nil,
                  accountLinkAttempts.count < 4,
                  now.timeIntervalSince(accountLinkLastAttempt[peer.id] ?? .distantPast) >= 30,
                  peer.invitation.expires > now else { continue }
            let attempt = UUID()
            accountLinkAttempts[peer.id] = attempt; accountLinkLastAttempt[peer.id] = now
            let probe = AccountLinkProbe(recipient: peer.id, peer: card, inviteNonce: peer.invitation.nonce,
                hint: Self.accountHint(subject: subject, sender: deviceID, recipient: peer.id))
            guard let signed = try? identity.sign(probe) else { accountLinkAttempts[peer.id] = nil; continue }
            sendAccountLink(signed, to: peer.endpoint) { [weak self] result in
                guard let self, self.accountLinkAttempts[peer.id] == attempt else { return }
                guard self.discovering, self.accountID() == subject, self.accountProof() == proof,
                      case let .success(envelope) = result, envelope.signer == peer.invitation.peer.publicKey,
                      let challenge = try? envelope.verified(as: AccountLinkChallenge.self),
                      challenge.kind == "account-link-challenge", challenge.requestID == probe.id,
                      challenge.recipient == self.deviceID, UUID(uuidString: challenge.challenge) != nil,
                      abs(challenge.created.timeIntervalSinceNow) < 30 else {
                    self.accountLinkAttempts[peer.id] = nil; return
                }
                let request = AccountLinkRequest(id: probe.id, recipient: peer.id, peer: self.card,
                    challenge: challenge.challenge, proof: proof)
                guard let signed = try? identity.sign(request) else { self.accountLinkAttempts[peer.id] = nil; return }
                self.sendAccountLink(signed, to: peer.endpoint) { [weak self] result in
                    guard let self, self.accountLinkAttempts[peer.id] == attempt else { return }
                    guard case let .success(reply) = result else { self.accountLinkAttempts[peer.id] = nil; return }
                    self.acceptAccountLinkReply(reply, request: request, expected: peer.invitation.peer, subject: subject, proof: proof) { [weak self] in
                        if self?.accountLinkAttempts[peer.id] == attempt { self?.accountLinkAttempts[peer.id] = nil }
                    }
                }
            }
        }
    }

    private func sendAccountLink(_ envelope: SignedEnvelope, to endpoint: LocalEndpoint,
                                 completion: @escaping (Result<SignedEnvelope, Error>) -> Void) {
        if let accountLinkTransport { accountLinkTransport(envelope, endpoint, completion) }
        else { network.request(envelope, endpoint: endpoint, timeout: 15, completion: completion) }
    }

    func acceptAccountLinkReply(_ envelope: SignedEnvelope, request: AccountLinkRequest, expected: PeerCard,
                                subject: String, proof: String, completion: @escaping () -> Void) {
        guard envelope.signer == expected.publicKey,
              let reply = try? envelope.verified(as: AccountLinkReply.self), reply.kind == "account-link-reply",
              reply.requestID == request.id, reply.recipient == deviceID,
              reply.peer.publicKey == expected.publicKey, !reply.peer.name.isEmpty, reply.peer.name.count <= 60,
              reply.peer.kind.count <= 32, reply.proof.utf8.count <= 4096,
              abs(reply.created.timeIntervalSinceNow) < 30 else { completion(); return }
        let generation = accountLinkGeneration
        appleKeys { [weak self] keys in
            defer { completion() }
            guard let self, self.accountLinkGeneration == generation, self.discovering, self.accountID() == subject, self.accountProof() == proof,
                  !self.ignoredAccountPeers.contains(expected.id), abs(reply.created.timeIntervalSinceNow) < 30,
                  AppleAccountProof.verifiedSubject(reply.proof, devicePublicKey: expected.publicKey, keys: keys) == subject else { return }
            self.rememberAutomaticPeer(reply.peer, subject: subject, proof: reply.proof)
            // The other side has accepted our proof and replied; both sides now
            // trust each other. The responder must not poll before this point.
            self.refreshPeerInventories(now: Date())
        }
    }

    func receiveAccountLink(_ envelope: SignedEnvelope, now: Date, respond: @escaping (SignedEnvelope) -> Void) -> Bool {
        if let probe = try? envelope.verified(as: AccountLinkProbe.self), probe.kind == "account-link-probe" {
            guard discovering, let identity, let subject = accountID(), let proof = accountProof(),
                  probe.recipient == deviceID, probe.peer.id != deviceID, probe.peer.publicKey == envelope.signer,
                  !probe.peer.name.isEmpty, probe.peer.name.count <= 60, probe.peer.kind.count <= 32,
                  UUID(uuidString: probe.id) != nil, abs(probe.created.timeIntervalSince(now)) < 30,
                  issuedAccountInviteIsValid(probe.inviteNonce, now: now), !ignoredAccountPeers.contains(probe.peer.id),
                  probe.hint == Self.accountHint(subject: subject, sender: probe.peer.id, recipient: deviceID) else { return true }
            accountLinkChallenges = accountLinkChallenges.filter { $0.value.expires > now }
            accountLinkInbound = accountLinkInbound.filter { now.timeIntervalSince($0.value) < 30 }
            guard accountLinkChallenges.count < 64, accountLinkInbound.count < 64,
                  accountLinkInbound[probe.peer.id] == nil else { return true }
            accountLinkInbound[probe.peer.id] = now
            let challenge = UUID().uuidString
            accountLinkChallenges[challenge] = AccountLinkChallengeState(requestID: probe.id, peer: probe.peer,
                account: subject, proof: proof, expires: now.addingTimeInterval(30))
            if let reply = try? identity.sign(AccountLinkChallenge(requestID: probe.id, recipient: probe.peer.id, challenge: challenge)) { respond(reply) }
            return true
        }
        guard let request = try? envelope.verified(as: AccountLinkRequest.self), request.kind == "account-link-request" else { return false }
        guard discovering, let identity, request.recipient == deviceID, request.peer.publicKey == envelope.signer,
              request.proof.utf8.count <= 4096, abs(request.created.timeIntervalSince(now)) < 30,
              let pending = accountLinkChallenges[request.challenge], pending.expires > now,
              pending.requestID == request.id, pending.peer == request.peer,
              pending.account == accountID(), pending.proof == accountProof(), !ignoredAccountPeers.contains(request.peer.id) else { return true }
        accountLinkChallenges[request.challenge] = nil // Consume before asynchronous verification.
        let generation = accountLinkGeneration
        appleKeys { [weak self] keys in
            guard let self, self.accountLinkGeneration == generation, self.discovering, pending.expires > Date(), self.accountID() == pending.account,
                  self.accountProof() == pending.proof, !self.ignoredAccountPeers.contains(request.peer.id),
                  AppleAccountProof.verifiedSubject(request.proof, devicePublicKey: envelope.signer, keys: keys) == pending.account else { return }
            let reply = AccountLinkReply(requestID: request.id, recipient: request.peer.id, peer: self.card, proof: pending.proof)
            guard let signed = try? identity.sign(reply) else { return }
            self.rememberAutomaticPeer(request.peer, subject: pending.account, proof: request.proof)
            respond(signed)
        }
        return true
    }
    /// Called with whatever proof a paired device included in its signed inventory reply.
    func observeAccountProof(_ proof: String?, from peerID: String, publicKey: String) {
        guard let proof, proof.utf8.count <= 4096 else {
            latestAccountProof[peerID] = nil
            if linkedAccounts.removeValue(forKey: peerID) != nil { saveLinkedAccounts() }
            revokeAutomaticPeer(peerID)
            return
        }
        let hash = SHA256.hash(data: Data(proof.utf8)).map { String(format: "%02x", $0) }.joined()
        latestAccountProof[peerID] = hash
        guard linkedAccounts[peerID]?.proofHash != hash, !proofsBeingChecked.contains(hash) else { return }
        proofsBeingChecked.insert(hash)
        appleKeys { [weak self] keys in
            guard let self else { return }
            self.proofsBeingChecked.remove(hash)
            guard self.latestAccountProof[peerID] == hash,
                  self.friends.contains(where: { $0.id == peerID && $0.card.publicKey == publicKey }) else { return }
            if let subject = AppleAccountProof.verifiedSubject(proof, devicePublicKey: publicKey, keys: keys) {
                self.linkedAccounts[peerID] = Self.linkedAccount(subject: subject, proof: proof)
                if let owner = self.automaticAccountPeers[peerID], owner != subject { self.revokeAutomaticPeer(peerID) }
            } else if !keys.isEmpty {
                self.linkedAccounts[peerID] = nil
                self.revokeAutomaticPeer(peerID)
            }
            self.saveLinkedAccounts()
        }
    }
    private func appleKeys(_ completion: @escaping ([AppleAccountProof.Key]) -> Void) {
        if let cached = appleKeyCache, cached.fetched.timeIntervalSinceNow > -6 * 3600 { completion(cached.keys); return }
        if appleKeyLastFailure.timeIntervalSinceNow > -30 { completion([]); return }
        appleKeyWaiters.append(completion)
        guard appleKeyWaiters.count == 1 else { return }
        var request = URLRequest(url: URL(string: AppleAccountProof.issuer + "/auth/keys")!)
        request.timeoutInterval = 15
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { [weak self] data, response, _ in
            session.finishTasksAndInvalidate()
            struct KeySet: Decodable { var keys: [AppleAccountProof.Key] }
            var keys: [AppleAccountProof.Key] = []
            if (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count < 32_768,
               let decoded = try? JSONDecoder().decode(KeySet.self, from: data) { keys = decoded.keys }
            DispatchQueue.main.async {
                guard let self else { return }
                if !keys.isEmpty { self.appleKeyCache = (keys, Date()) }
                else { self.appleKeyLastFailure = Date() }
                let callbacks = self.appleKeyWaiters; self.appleKeyWaiters = []
                callbacks.forEach { $0(keys) }
            }
        }.resume()
    }

    /// A room command can arrive before the next inventory refresh. Verify its
    /// device-bound proof instead of depending on the receiver's cached link.
    func verifyRoomAccount(_ proof: String?, peerID: String, publicKey: String,
                           completion: @escaping (Bool) -> Void) {
        guard let proof else { completion(isOwnDevice(peerID)); return }
        guard proof.utf8.count <= 4096, let subject = accountID() else { completion(false); return }
        let generation = accountLinkGeneration
        appleKeys { [weak self] keys in
            guard let self, self.accountLinkGeneration == generation, self.accountID() == subject,
                  self.friends.contains(where: { $0.id == peerID && $0.card.publicKey == publicKey }),
                  AppleAccountProof.verifiedSubject(proof, devicePublicKey: publicKey, keys: keys) == subject else {
                completion(false); return
            }
            self.linkedAccounts[peerID] = Self.linkedAccount(subject: subject, proof: proof)
            self.saveLinkedAccounts()
            completion(true)
        }
    }

    /// Change or delete a room that lives on another of this person's devices.
    func sendRoomEdit(roomID: String, owner ownerID: String, room: AudioRoom?) {
        guard let identity, let peer = nearby.first(where: { $0.id == ownerID }),
              let owner = friends.first(where: { $0.id == ownerID }) else {
            notice = "Open Soundbound on the device that holds this room, then try again."; return
        }
        let request = RoomEditRequest(sender: deviceID, recipient: ownerID, roomID: roomID, room: room, accountProof: accountProof())
        guard let signed = try? identity.sign(request) else { return }
        network.request(signed, endpoint: peer.endpoint, timeout: request.accountProof == nil ? 5 : 20) { [weak self] result in
            guard let self else { return }
            // Either way, mirror the holder's copy again straight away.
            self.lastInventoryRefresh = .distantPast
            guard case let .success(envelope) = result, envelope.signer == owner.card.publicKey,
                  let reply = try? envelope.verified(as: RoomComponentReply.self), reply.kind == "room-component-reply", reply.id == request.id, reply.accepted else {
                self.notice = "Your other device did not accept this change. Check both are signed in to the same Apple Account."
                return
            }
        }
    }
    func receiveRoomEdit(_ envelope: SignedEnvelope, respond: @escaping (SignedEnvelope) -> Void) -> Bool {
        guard let request = try? envelope.verified(as: RoomEditRequest.self), request.kind == "room-edit-request" else { return false }
        guard let identity, request.recipient == deviceID, UUID(uuidString: request.id) != nil,
              abs(request.created.timeIntervalSinceNow) < 30,
              friends.contains(where: { $0.id == request.sender && $0.card.publicKey == envelope.signer }),
              let current = rooms.first(where: { $0.id == request.roomID && $0.owner == deviceID }) else { return true }
        roomComponentSeen = roomComponentSeen.filter { $0.value.timeIntervalSinceNow > -30 }
        guard roomComponentSeen[request.id] == nil, roomComponentSeen.count < 1000 else { return true }
        roomComponentSeen[request.id] = Date()
        verifyRoomAccount(request.accountProof, peerID: request.sender, publicKey: envelope.signer) { [weak self] ownAccount in
            guard let self else { return }
            var accepted = false
            if ownAccount, abs(request.created.timeIntervalSinceNow) < 30,
               let current = self.rooms.first(where: { $0.id == current.id && $0.owner == self.deviceID }) {
                if var room = request.room {
                    let name = room.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if room.id == current.id, !name.isEmpty, name.count <= 60, room.region.count <= 60, (room.guests ?? []).count <= 64,
                       (room.guests ?? []).allSatisfy({ $0.name.count <= 60 && $0.id.count <= 128 }) {
                        // Ownership and membership never travel in an edit.
                        room.owner = self.deviceID; room.members = current.members
                        self.updateRoom(room); accepted = true
                    }
                } else {
                    self.deleteRoom(current.id); accepted = true
                }
            }
            if let reply = try? identity.sign(RoomComponentReply(id: request.id, accepted: accepted)) { respond(reply) }
        }
        return true
    }
}


/// A request to change one of another device's audio settings from the audio map.
struct DeviceTuningRequest: Codable {
    var kind = "device-tuning-request"
    var id = UUID().uuidString
    var sender: String
    var recipient: String
    /// "floor", "ceiling", "reset" or "capturePacket", exactly as the map's own controls are named, or "direction".
    var control: String
    var value: Double
    var created = Date()
    var accountProof: String? = nil
}

extension HubStore {
    /// Applies one of the map's controls to this device.
    func applyTuning(_ control: String, _ value: Double) -> Bool {
        guard value.isFinite else { return false }
        let floor = AudioBufferPolicy.initialPlaybackFrames / 24, ceiling = AudioBufferPolicy.maximumTargetFrames / 24
        switch control {
        case "capturePacket":
            let stops = AudioBufferPolicy.capturePacketStops
            AudioBufferPolicy.setCapturePacketFrames(stops[min(stops.count - 1, max(0, Int(value.rounded())))])
        case "floor": AudioBufferPolicy.setPlayoutLimits(floorMilliseconds: Int(value), ceilingMilliseconds: max(ceiling, Int(value)))
        case "ceiling": AudioBufferPolicy.setPlayoutLimits(floorMilliseconds: min(floor, Int(value)), ceilingMilliseconds: Int(value))
        case "reset": AudioBufferPolicy.setPlayoutLimits(floorMilliseconds: AudioBufferPolicy.defaultFloorMilliseconds,
                                                         ceilingMilliseconds: AudioBufferPolicy.defaultCeilingMilliseconds)
        case "direction":
            // 0 both, 1 send only, 2 receive only.
            let choices = AudioDirection.allCases
            guard let choice = choices.indices.contains(Int(value)) ? choices[Int(value)] : nil else { return false }
            audioDirection = choice
        default: return false
        }
        return true
    }
    /// Asks another device to send, receive or both. Shown straight away; corrected by what the device next reports.
    public func setDirection(_ direction: AudioDirection, on peerID: String) {
        guard let index = AudioDirection.allCases.firstIndex(of: direction) else { return }
        peerDirections[peerID] = direction
        sendTuning(to: peerID, control: "direction", value: Double(index))
    }
    /// Whether the map should offer another device's controls here. The other device makes the real decision.
    func mayTune(_ peerID: String) -> Bool {
        isOwnDevice(peerID) || rooms.contains { canAdminister($0) && (peerMemberships[peerID]?.contains($0.id) == true || $0.role(of: peerID) != nil) }
    }
    /// Who may change this device's audio settings: another device of the same person, or whoever holds the room
    /// this device has joined (that device, or another device verified as the same person's).
    private func tuningAllowedByRoom(from sender: String) -> Bool {
        guard let room = activeRoom, room.owner != deviceID else { return false }
        let owner = room.owner
        if owner == sender { return true }
        // Another device in the same room that is not a listen-only guest: the holder's other devices, which are
        // in the room without being guests, and guests the holder gave control to.
        let inRoom = peerMemberships[sender]?.contains(room.id) == true ||
            audioMemberships.contains { $0.key.hasPrefix("remote:" + sender + ":") && $0.value.contains(room.id) }
        if inRoom, room.role(of: sender) != .listen { return true }
        guard let theirs = linkedAccounts[sender]?.subject, let holders = linkedAccounts[owner]?.subject else { return false }
        return theirs == holders
    }
    func sendTuning(to peerID: String, control: String, value: Double) {
        guard let identity, let peer = nearby.first(where: { $0.id == peerID }),
              let friend = friends.first(where: { $0.id == peerID }) else {
            notice = "That device isn’t nearby, so its setting wasn’t changed."; return
        }
        let request = DeviceTuningRequest(sender: deviceID, recipient: peerID, control: control, value: value, accountProof: accountProof())
        guard let signed = try? identity.sign(request) else { return }
        network.request(signed, endpoint: peer.endpoint, timeout: request.accountProof == nil ? 5 : 20) { [weak self] result in
            guard let self else { return }
            self.lastInventoryRefresh = .distantPast
            guard case let .success(envelope) = result, envelope.signer == friend.card.publicKey,
                  let reply = try? envelope.verified(as: RoomComponentReply.self), reply.kind == "room-component-reply",
                  reply.id == request.id, reply.accepted else {
                self.notice = "\(friend.card.name) did not accept that change. It has to be one of your devices, or have joined a room you hold."
                return
            }
        }
    }
    func receiveTuning(_ envelope: SignedEnvelope, respond: @escaping (SignedEnvelope) -> Void) -> Bool {
        guard let request = try? envelope.verified(as: DeviceTuningRequest.self), request.kind == "device-tuning-request" else { return false }
        guard let identity, request.recipient == deviceID, UUID(uuidString: request.id) != nil,
              abs(request.created.timeIntervalSinceNow) < 30, request.control.count <= 32,
              friends.contains(where: { $0.id == request.sender && $0.card.publicKey == envelope.signer }) else { return true }
        roomComponentSeen = roomComponentSeen.filter { $0.value.timeIntervalSinceNow > -30 }
        guard roomComponentSeen[request.id] == nil, roomComponentSeen.count < 1000 else { return true }
        roomComponentSeen[request.id] = Date()
        let finish: (Bool) -> Void = { [weak self] allowed in
            let accepted = allowed && (self?.applyTuning(request.control, request.value) ?? false)
            if accepted { self?.objectWillChange.send() }
            if let reply = try? identity.sign(RoomComponentReply(id: request.id, accepted: accepted)) { respond(reply) }
        }
        if tuningAllowedByRoom(from: request.sender) { finish(true) }
        else { verifyRoomAccount(request.accountProof, peerID: request.sender, publicKey: envelope.signer, completion: finish) }
        return true
    }
}


extension HubStore {
    /// The person a paired device belongs to, as that device names them, so two devices both called "iPhone"
    /// can be told apart.
    public func ownerName(of peer: KnownPeer) -> String? {
        let name = peer.card.owner ?? nearby.first { $0.id == peer.id }?.invitation.peer.owner
        return name.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) }
    }
}


extension HubStore {
    private func possessive(_ owner: String?, _ device: String) -> String {
        guard let first = owner?.split(separator: " ").first.map(String.init), !first.isEmpty,
              !device.localizedCaseInsensitiveContains(first) else { return device }
        return first + "’s " + device
    }
    /// "Melina’s iPhone": a paired device named with its owner, so two devices with the same name can be told apart.
    public func deviceTitle(_ peer: KnownPeer) -> String { possessive(ownerName(of: peer), peer.card.name) }
    /// This device, named the same way.
    public var ownDeviceTitle: String { possessive(AppleAccount.shared.isSignedIn ? AppleAccount.shared.displayName : nil, name) }
    /// A speaker or microphone named with the device it is on: "Melina’s iPhone Speaker".
    public func componentTitle(_ component: String, on device: String, titled title: String) -> String {
        component.hasPrefix(device) ? title + component.dropFirst(device.count) : title + " · " + component
    }
}
