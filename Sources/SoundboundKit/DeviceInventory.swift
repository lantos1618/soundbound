import Foundation

/// Signed, bounded metadata exchanged only between explicitly paired devices.
struct InventoryRequest: Codable {
    var kind = "device-inventory-request"
    var id = UUID().uuidString
    var recipient: String
    var created = Date()
}
struct InventoryReply: Codable {
    var kind = "device-inventory-reply"
    var requestID: String
    var recipient: String
    var devices: [LocalAudioDevice]
    var created = Date()
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
        let reply = InventoryReply(requestID: request.id, recipient: PeerCard(publicKey: envelope.signer, name: "", kind: "").id,
                                   devices: Array(reportedAudioDevices.prefix(32)))
        if let signed = try? identity.sign(reply) { respond(signed) }
        return true
    }
    func refreshPeerInventories(now: Date) {
        guard discovering, let identity, now.timeIntervalSince(lastInventoryRefresh) >= 5 else { return }
        lastInventoryRefresh = now
        let online = Set(nearby.map(\.id))
        peerAudioDevices = peerAudioDevices.filter { online.contains($0.key) }
        for peer in nearby where friends.contains(where: { $0.id == peer.id }) && !inventoryPending.contains(peer.id) {
            let request = InventoryRequest(recipient: peer.id)
            guard let signed = try? identity.sign(request) else { continue }
            inventoryPending.insert(peer.id)
            network.request(signed, endpoint: peer.endpoint) { [weak self] result in
                guard let self else { return }
                self.inventoryPending.remove(peer.id)
                guard self.friends.contains(where: { $0.id == peer.id }),
                      case let .success(envelope) = result,
                      envelope.signer == peer.invitation.peer.publicKey,
                      let reply = try? envelope.verified(as: InventoryReply.self),
                      reply.kind == "device-inventory-reply", reply.requestID == request.id,
                      reply.recipient == self.deviceID, abs(reply.created.timeIntervalSinceNow) < 30,
                      reply.devices.count <= 32,
                      reply.devices.allSatisfy({ $0.id.count <= 512 && $0.name.count <= 256 }) else { return }
                self.peerAudioDevices[peer.id] = reply.devices
            }
        }
    }
}
