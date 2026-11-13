import Foundation

struct RoomComponentRequest: Codable {
    var kind = "room-component-request"
    var id = UUID().uuidString
    var sender: String
    var recipient: String
    var roomID: String
    var component: String
    var included: Bool
    var created = Date()
    /// The device the component is attached to. Nil means the sender's own output, as in earlier builds.
    var host: String?
    var accountProof: String? = nil
}
struct RoomComponentReply: Codable {
    var kind = "room-component-reply"
    var id: String
    var accepted: Bool
}
extension HubStore {
    func changeOwnRoomOutput(_ component: String, room: AudioRoom, included: Bool) {
        if room.owner == deviceID {
            if included { moveAudioDevice(component, to: room.id) } else { removeAudioDevice(component, from: room.id) }
            return
        }
        guard let identity, let peer = nearby.first(where: { $0.id == room.owner }),
              let owner = friends.first(where: { $0.id == room.owner }) else { notice = "Open Soundbound on the room owner’s device."; return }
        let request = RoomComponentRequest(sender: deviceID, recipient: room.owner, roomID: room.id, component: component, included: included, accountProof: accountProof())
        guard let signed = try? identity.sign(request) else { return }
        network.request(signed, endpoint: peer.endpoint, timeout: request.accountProof == nil ? 5 : 20) { [weak self] result in
            guard let self else { return }
            guard case let .success(envelope) = result else {
                self.notice = "The device holding this room did not respond. Keep Soundbound open on both devices and try again."; return
            }
            guard envelope.signer == owner.card.publicKey,
                  let reply = try? envelope.verified(as: RoomComponentReply.self), reply.kind == "room-component-reply", reply.id == request.id,
                  reply.accepted else { self.notice = "The room owner could not apply this change. Open its room settings."; return }
            self.notice = included ? "Added output to room." : "Removed output from room."
            self.lastInventoryRefresh = .distantPast
            self.refreshPeerInventories(now: Date())
        }
    }
    /// Add or remove any room member by its local key. The owner applies it directly;
    /// a guest who can control asks the owner, which checks the role before changing anything.
    public func changeRoomMember(_ key: String, room: AudioRoom, included: Bool) {
        if room.owner == deviceID {
            if included { moveAudioDevice(key, to: room.id) } else { removeAudioDevice(key, from: room.id) }
            return
        }
        var host = deviceID, component = key
        if key.hasPrefix("remote:") {
            let parts = key.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return }
            host = parts[1]; component = parts[2]
        }
        guard let identity, let peer = nearby.first(where: { $0.id == room.owner }),
              let owner = friends.first(where: { $0.id == room.owner }) else { notice = "Open Soundbound on the room owner’s device."; return }
        let request = RoomComponentRequest(sender: deviceID, recipient: room.owner, roomID: room.id, component: component, included: included, host: host, accountProof: accountProof())
        guard let signed = try? identity.sign(request) else { return }
        network.request(signed, endpoint: peer.endpoint, timeout: request.accountProof == nil ? 5 : 20) { [weak self] result in
            guard let self else { return }
            guard case let .success(envelope) = result else {
                self.notice = "The device holding this room did not respond. Keep Soundbound open on both devices and try again."; return
            }
            guard envelope.signer == owner.card.publicKey,
                  let reply = try? envelope.verified(as: RoomComponentReply.self), reply.kind == "room-component-reply", reply.id == request.id,
                  reply.accepted else { self.notice = "The room owner did not allow this change."; return }
            self.audioNotice = included ? "Added to \(room.name)." : "Removed from \(room.name)."
            self.lastInventoryRefresh = .distantPast
            self.refreshPeerInventories(now: Date())
        }
    }
    /// Owner only: invite a paired device, change its role, or (role nil) remove it.
    public func setGuest(_ peerID: String, role: GuestRole?, in roomID: String) {
        guard var room = rooms.first(where: { $0.id == roomID }), canAdminister(room) else { return }
        var guests = room.guests ?? []
        guests.removeAll { $0.id == peerID }
        if let role, let peer = friends.first(where: { $0.id == peerID }), guests.count < 64 {
            guests.append(RoomGuest(id: peerID, name: String(peer.card.name.prefix(60)), role: role))
        }
        room.guests = guests.isEmpty ? nil : guests
        updateRoom(room)
    }
    func receiveRoomComponent(_ envelope: SignedEnvelope, respond: @escaping (SignedEnvelope) -> Void) -> Bool {
        guard let request = try? envelope.verified(as: RoomComponentRequest.self), request.kind == "room-component-request" else { return false }
        guard let identity, request.recipient == deviceID, UUID(uuidString: request.id) != nil,
              abs(request.created.timeIntervalSinceNow) < 30, request.component.count <= 512,
              friends.contains(where: { $0.id == request.sender && $0.card.publicKey == envelope.signer }),
              let room = rooms.first(where: { $0.id == request.roomID && $0.owner == deviceID }) else { return true }
        roomComponentSeen = roomComponentSeen.filter { $0.value.timeIntervalSinceNow > -30 }
        guard roomComponentSeen[request.id] == nil, roomComponentSeen.count < 1000 else { return true }
        roomComponentSeen[request.id] = Date()
        verifyRoomAccount(request.accountProof, peerID: request.sender, publicKey: envelope.signer) { [weak self] ownAccount in
            guard let self else { return }
            guard abs(request.created.timeIntervalSinceNow) < 30,
                  self.friends.contains(where: { $0.id == request.sender && $0.card.publicKey == envelope.signer }),
                  let room = self.rooms.first(where: { $0.id == room.id && $0.owner == self.deviceID }) else { return }
            let prefix = "remote:" + request.sender + ":"
            let member = self.peerMemberships[request.sender]?.contains(room.id) == true || self.audioMemberships.contains { $0.key.hasPrefix(prefix) && $0.value.contains(room.id) }
            let knownOutput = self.peerAudioDevices[request.sender]?.contains { $0.id == request.component && $0.hasOutput } == true
            let host = request.host ?? request.sender
            // A guest's own output keeps the earlier rule. Anything else needs the control role,
            // and the component must be one this owner can actually see.
            // A paired device may always bring its own speakers into a room or take them out; that is what joining is.
            _ = member
            let ownOutput = host == request.sender && knownOutput
            // A verified owner is authoritative for its own local component IDs.
            // Its signed command can precede the inventory containing a new route.
            let knownComponent = (ownAccount && host == request.sender && !request.component.isEmpty) || (host == self.deviceID
                ? self.reportedAudioDevices.contains { $0.id == request.component }
                : self.friends.contains { $0.id == host } && (self.peerAudioDevices[host]?.contains { $0.id == request.component } == true || !request.included))
            let controller = host.count <= 128 && (room.role(of: request.sender) == .control || ownAccount) && knownComponent
            let allowed = ownOutput || controller
            if allowed {
                let key = host == self.deviceID ? request.component : Self.remoteComponentID(peer: host, component: request.component)
                if request.included { self.moveAudioDevice(key, to: room.id) } else { self.removeAudioDevice(key, from: room.id) }
            }
            if let reply = try? identity.sign(RoomComponentReply(id: request.id, accepted: allowed)) { respond(reply) }
        }
        return true
    }
}
