import Foundation

public struct RemoteRecordingRequest: Codable, Identifiable {
    var kind = "remote-recording"
    public var id = UUID().uuidString
    var sender: PeerCard
    var recipient: String
    var inputID: String
    var created = Date()
    public var senderName: String { sender.name }
}
struct RemoteRecordingReply: Codable {
    var kind = "remote-recording-reply"
    var id: String
    var accepted: Bool
}
extension HubStore {
    public func toggleRemoteRecording(peerID: String, inputID: String) {
        if pendingRemoteRecording?.peer == peerID {
            pendingRemoteRecording = nil
            mesh.stop(); activity.finishRemoteRecording()
            return
        }
        guard !mesh.active, let identity,
              friends.contains(where: { $0.id == peerID }),
              let peer = nearby.first(where: { $0.id == peerID }) else {
            notice = "Open Soundbound on the paired device before recording."; return
        }
        let request = RemoteRecordingRequest(sender: card, recipient: peerID, inputID: inputID)
        let rowID = Self.remoteComponentID(peer: peerID, component: inputID)
        pendingRemoteRecording = (request.id, peerID, rowID)
        activity.beginRemoteRecording(rowID)
        guard let envelope = try? identity.sign(request) else { return }
        network.request(envelope, endpoint: peer.endpoint) { [weak self] result in
            guard let self, self.pendingRemoteRecording?.request == request.id else { return }
            guard case let .success(envelope) = result,
                  envelope.signer == peer.invitation.peer.publicKey,
                  let reply = try? envelope.verified(as: RemoteRecordingReply.self),
                  reply.kind == "remote-recording-reply", reply.id == request.id, reply.accepted else {
                self.pendingRemoteRecording = nil; self.activity.finishRemoteRecording()
                self.notice = "The microphone request wasn’t accepted."; return
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in
            guard let self, self.pendingRemoteRecording?.request == request.id, !self.mesh.active else { return }
            self.pendingRemoteRecording = nil; self.activity.finishRemoteRecording()
        }
    }
    func receiveRecordingRequest(_ envelope: SignedEnvelope, respond: @escaping (SignedEnvelope) -> Void) -> Bool {
        guard let request = try? envelope.verified(as: RemoteRecordingRequest.self), request.kind == "remote-recording" else { return false }
        seenRecordingRequests = seenRecordingRequests.filter { Date().timeIntervalSince($0.value) < 120 }
        guard request.recipient == deviceID, request.sender.publicKey == envelope.signer,
              friends.contains(where: { $0.id == request.sender.id && $0.card.publicKey == envelope.signer }),
              abs(request.created.timeIntervalSinceNow) < 30, UUID(uuidString: request.id) != nil,
              request.inputID.count <= 512, seenRecordingRequests.count < 1000,
              seenRecordingRequests[request.id] == nil else { return true }
        seenRecordingRequests[request.id] = Date()
        guard !mesh.active, recordingRequest == nil,
              reportedAudioDevices.contains(where: { $0.id == request.inputID && $0.hasInput && $0.isAvailable }) else {
            if let reply = try? identity?.sign(RemoteRecordingReply(id: request.id, accepted: false)) { respond(reply) }
            return true
        }
        recordingRequest = request; recordingReply = respond
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            if self?.recordingRequest?.id == request.id { self?.decideRecordingRequest(allow: false) }
        }
        return true
    }
    public func decideRecordingRequest(allow: Bool) {
        guard let request = recordingRequest, let identity else { return }
        let respond = recordingReply
        recordingRequest = nil; recordingReply = nil
        let input = reportedAudioDevices.first { $0.id == request.inputID && $0.hasInput && $0.isAvailable }
        let peer = nearby.first { $0.id == request.sender.id }
        let accepted = allow && input != nil && peer != nil && !mesh.active && abs(request.created.timeIntervalSinceNow) < 40
        if let reply = try? identity.sign(RemoteRecordingReply(id: request.id, accepted: accepted)) { respond?(reply) }
        if accepted, let input, let peer {
            mesh.shareMicrophone(to: peer, identity: identity, card: card, input: input, recordingID: request.id)
        }
    }
}
