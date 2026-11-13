import Foundation

/// Signed, bounded metadata exchanged only between manually paired or account-verified devices.
struct InventoryRequest: Codable {
    var kind = "device-inventory-request"
    var id = UUID().uuidString
    var recipient: String
    var created = Date()
    /// Set while the asking device has its audio map open, so the reply carries this device's own pipeline.
    var wantsMap: Bool? = nil
}
struct InventoryReply: Codable {
    var kind = "device-inventory-reply"
    var requestID: String
    var recipient: String
    var devices: [LocalAudioDevice]
    var peer: PeerCard?
    var rooms: [RoomLayout]?
    var spatialLayouts: [RoomSpatialLayout]?
    var created = Date()
    /// Apple-signed proof of the account signed in on the replying device. See `AppleAccountProof`.
    var accountProof: String?
    var playback: [DevicePlaybackSnapshot]? = nil
    /// Sent only to this person's own devices, so a preference changed on one follows to the others.
    var sharedSettings: SharedSettings? = nil
    /// This device's own audio pipeline, as it would draw it. Only sent when asked for.
    var map: AudioMapSnapshot? = nil
    /// "both", "send" or "receive": how this device takes part.
    var direction: String? = nil
}

extension HubStore {
    public static func remoteComponentID(peer: String, component: String) -> String {
        "remote:" + peer + ":" + component
    }
    func answerInventory(_ envelope: SignedEnvelope, respond: (SignedEnvelope) -> Void) -> Bool {
        guard let request = try? envelope.verified(as: InventoryRequest.self),
              request.kind == "device-inventory-request" else { return false }
        guard let identity, request.recipient == deviceID,
              abs(request.created.timeIntervalSinceNow) < 30,
              friends.contains(where: { $0.card.publicKey == envelope.signer }) else { return true }
        let peerID = PeerCard(publicKey: envelope.signer, name: "", kind: "").id
        let playback = activity.playbackSnapshot(ids: Set(reportedAudioDevices.prefix(32).map(\.id)).union([deviceID])).map { snapshot in
            var snapshot = snapshot
            snapshot.roomID = roomAudio.playbackRoomID(for: snapshot.id)
            return snapshot
        }
        let reply = InventoryReply(requestID: request.id, recipient: peerID,
                                   devices: Array(reportedAudioDevices.prefix(32)), peer: card, rooms: ownedRoomLayouts(), spatialLayouts: spatialLayoutsForPeer(peerID), accountProof: accountProof(),
                                   playback: playback, sharedSettings: isOwnDevice(peerID) ? activity.sharedSettings : nil,
                                   map: request.wantsMap == true ? publishedAudioMap(for: peerID) : nil, direction: audioDirection.rawValue)
        if let signed = try? identity.sign(reply) { respond(signed) }
        // A first inventory request confirms that the initiator has completed
        // account linking. Fetch its devices in return without racing that link.
        if !inventoryReceived.contains(peerID), inventoryPending[peerID] == nil {
            lastInventoryRefresh = .distantPast
            DispatchQueue.main.async { [weak self] in self?.refreshPeerInventories(now: Date()) }
        }
        return true
    }
    func refreshPeerInventories(now: Date) {
        guard discovering, let identity else { return }
        let online = Set(nearby.map(\.id))
        inventoryReceived.formIntersection(online)
        // Never let a lost response (including a request sent during linking)
        // block fresh inventories for the network layer's generic two minutes.
        inventoryPending = inventoryPending.filter { online.contains($0.key) && $0.value.deadline > now }
        for id in Array(peerAudioDevices.keys) where !online.contains(id) {
            observePeerAudioDevices([], peerID: id, now: now)
        }
        for id in Array(peerPlayback.keys) where !online.contains(id) { observePeerPlayback([], peerID: id, now: now) }
        let refreshInterval: TimeInterval = roomAudio.active || roomAudio.receiving || !peerPlayback.isEmpty || audioMapOpen ? 1 : 5
        guard now.timeIntervalSince(lastInventoryRefresh) >= refreshInterval else { return }
        lastInventoryRefresh = now
        for peer in nearby where friends.contains(where: { $0.id == peer.id }) && inventoryPending[peer.id] == nil {
            let request = InventoryRequest(recipient: peer.id, wantsMap: audioMapOpen ? true : nil)
            guard let signed = try? identity.sign(request) else { continue }
            inventoryPending[peer.id] = (request.id, now.addingTimeInterval(5))
            let completion: (Result<SignedEnvelope, Error>) -> Void = { [weak self] result in
                guard let self, self.inventoryPending[peer.id]?.id == request.id else { return }
                self.inventoryPending[peer.id] = nil
                guard self.friends.contains(where: { $0.id == peer.id }),
                      case let .success(envelope) = result,
                      envelope.signer == peer.invitation.peer.publicKey,
                      let reply = try? envelope.verified(as: InventoryReply.self),
                      reply.kind == "device-inventory-reply", reply.requestID == request.id,
                      reply.recipient == self.deviceID, abs(reply.created.timeIntervalSinceNow) < 30,
                      reply.devices.count <= 32,
                      reply.devices.allSatisfy({ $0.id.count <= 512 && $0.name.count <= 256 && ($0.physicalID?.count ?? 0) <= 512 && ($0.legacyID?.count ?? 0) <= 512 }) else { return }
                if let card = reply.peer, card.id == peer.id, card.publicKey == envelope.signer, !card.name.isEmpty, card.name.count <= 60 {
                    self.updatePeerCard(card)
                }
                self.observeAccountProof(reply.accountProof, from: peer.id, publicKey: envelope.signer)
                guard self.friends.contains(where: { $0.id == peer.id }) else { return }
                self.inventoryReceived.insert(peer.id)
                if let rooms = reply.rooms { _ = self.mergeRoomLayouts(rooms, from: peer.id) }
                if let settings = reply.sharedSettings, self.isOwnDevice(peer.id) { self.activity.adopt(settings) }
                if let map = reply.map { self.peerMaps[peer.id] = (map, Date()) }
                if let direction = reply.direction.flatMap(AudioDirection.init(rawValue:)), self.peerDirections[peer.id] != direction { self.peerDirections[peer.id] = direction }
                if let layouts = reply.spatialLayouts { self.receiveSpatialLayouts(layouts, from: peer.id) }
                self.observePeerAudioDevices(reply.devices, peerID: peer.id)
                let allowedIDs = Set(reply.devices.map(\.id)).union([peer.id])
                let playback = reply.playback ?? []
                if playback.count <= 33, Set(playback.map(\.id)).count == playback.count,
                   playback.allSatisfy({ allowedIDs.contains($0.id) && $0.level.isFinite && (0...1).contains($0.level) && ($0.bands?.count ?? 0) <= 64 && ($0.roomID?.count ?? 0) <= 128 }) {
                    self.observePeerPlayback(playback, peerID: peer.id)
                } else { self.observePeerPlayback([], peerID: peer.id) }
                if ProcessInfo.processInfo.arguments.contains("--mesh-diagnostics") {
                    // Counts only: never print account proofs or identifiers.
                    print("Soundbound inventory received: \(reply.devices.count) audio devices")
                }
            }
            if let inventoryTransport { inventoryTransport(signed, peer.endpoint, 5, completion) }
            else { network.request(signed, endpoint: peer.endpoint, timeout: 5, completion: completion) }
        }
    }

    func observePeerPlayback(_ snapshots: [DevicePlaybackSnapshot], peerID: String, now: Date = Date()) {
        let incoming = Set(snapshots.map(\.id))
        for previous in peerPlayback[peerID] ?? [] where !incoming.contains(previous.id) {
            activity.clear(playbackKey(previous.id, peerID: peerID))
        }
        for snapshot in snapshots { activity.showPeerPlayback(playbackKey(snapshot.id, peerID: peerID), level: snapshot.level, bands: snapshot.bands) }
        peerPlayback[peerID] = snapshots.isEmpty ? nil : snapshots
        peerPlaybackUpdated[peerID] = snapshots.isEmpty ? nil : now
    }
    private func playbackKey(_ id: String, peerID: String) -> String {
        id == peerID ? "peer:" + peerID : Self.remoteComponentID(peer: peerID, component: id)
    }
    func expirePeerPlayback(now: Date) {
        for (peerID, updated) in peerPlaybackUpdated where now.timeIntervalSince(updated) >= 7 {
            observePeerPlayback([], peerID: peerID, now: now)
        }
    }
    func roomHasPeerPlayback(_ roomID: String) -> Bool {
        peerPlayback.contains { peerID, snapshots in
            snapshots.contains { snapshot in
                snapshot.roomID == roomID && (peerMemberships[peerID]?.contains(roomID) == true ||
                audioMemberships[Self.remoteComponentID(peer: peerID, component: snapshot.id)]?.contains(roomID) == true)
            }
        }
    }
    /// A missing live inventory is not a membership removal.
    func displayedPeerDevices(_ peerID: String) -> [LocalAudioDevice] {
        let current = peerAudioDevices[peerID] ?? []
        return current.isEmpty ? (lastKnownPeerDevices[peerID] ?? []) : current
    }
}
