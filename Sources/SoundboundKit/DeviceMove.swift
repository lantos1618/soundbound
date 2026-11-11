import Foundation

public struct DeviceMoveRequest: Codable, Identifiable {
    var kind = "device-move-request"
    public var id = UUID().uuidString
    var sender: PeerCard
    var recipient: String
    public var deviceName: String
    var sourceName: String? = nil
    var created = Date()
    public var senderName: String { sourceName ?? sender.name }
}
struct DeviceMoveReply: Codable {
    var kind = "device-move-reply"
    var requestID: String
    var recipient: String
    var accepted: Bool
    var created = Date()
}

extension HubStore {
    public func requestDeviceMove(_ device: LocalAudioDevice, to hostID: String, from sourceName: String? = nil) {
        guard device.canMoveBetweenHosts else {
            notice = "\(device.name) stays attached to its host. You can still add it to a room."
            return
        }
        guard let identity, deviceMoveRequest == nil else { return }
        if hostID == deviceID {
            deviceMoveRequest = DeviceMoveRequest(sender: card, recipient: deviceID, deviceName: device.name, sourceName: sourceName)
            return
        }
        guard friends.contains(where: { $0.id == hostID }), let peer = nearby.first(where: { $0.id == hostID }) else {
            notice = "That device must be paired and nearby."; return
        }
        let request = DeviceMoveRequest(sender: card, recipient: hostID, deviceName: device.name, sourceName: sourceName)
        guard let signed = try? identity.sign(request) else { return }
        audioNotice = "Asking \(peer.invitation.peer.name) to use \(device.name)…"
        network.request(signed, endpoint: peer.endpoint) { [weak self] result in
            guard let self, case let .success(envelope) = result,
                  envelope.signer == peer.invitation.peer.publicKey,
                  let reply = try? envelope.verified(as: DeviceMoveReply.self),
                  reply.kind == "device-move-reply", reply.requestID == request.id,
                  reply.recipient == self.deviceID, abs(reply.created.timeIntervalSinceNow) < 120 else { return }
            self.audioNotice = reply.accepted ? "Request accepted. Waiting for the headphone connection to change." : "Headphone move declined."
        }
    }
    func receiveDeviceMove(_ envelope: SignedEnvelope, respond: @escaping (SignedEnvelope) -> Void) -> Bool {
        guard let request = try? envelope.verified(as: DeviceMoveRequest.self), request.kind == "device-move-request" else { return false }
        seenMoveRequests = seenMoveRequests.filter { Date().timeIntervalSince($0.value) < 120 }
        guard request.recipient == deviceID, request.sender.publicKey == envelope.signer,
              friends.contains(where: { $0.id == request.sender.id }),
              abs(request.created.timeIntervalSinceNow) < 30, request.deviceName.count <= 256,
              deviceMoveRequest == nil, seenMoveRequests.count < 1000, seenMoveRequests[request.id] == nil else { return true }
        seenMoveRequests[request.id] = Date()
        deviceMoveRequest = request; moveReply = respond
        audioNotice = "\(request.deviceName) is requesting a move from \(request.senderName) to \(name)."
        return true
    }
    public func decideDeviceMove(approve: Bool) {
        guard let request = deviceMoveRequest, let identity else { return }
        let respond = moveReply
        deviceMoveRequest = nil; moveReply = nil
        let valid = abs(request.created.timeIntervalSinceNow) < 120
        if let reply = try? identity.sign(DeviceMoveReply(requestID: request.id, recipient: request.sender.id, accepted: approve && valid)) { respond?(reply) }
        if approve && valid { onApprovedDeviceMove?(request.deviceName) }
    }
}
