import Foundation
import Combine
#if os(iOS)
import UIKit
#endif

public final class HubStore: ObservableObject {
    @Published public var name: String
    @Published public internal(set) var rooms: [AudioRoom]
    @Published public private(set) var friends: [KnownPeer]
    @Published public private(set) var nearby: [NearbyPeer] = []
    @Published public private(set) var requests: [AccessRequest] = []
    @Published public private(set) var outgoing: Set<String> = []
    @Published public private(set) var discovering = false
    @Published public var notice: String?
    @Published public private(set) var discoveryStatus = "Discovery is off"
    @Published public private(set) var inviteLink = ""
    @Published public private(set) var friendCode = "—"
    @Published public private(set) var deviceRoom: String?
    @Published public internal(set) var deviceRooms: Set<String>
    @Published public internal(set) var audioMemberships: [String: Set<String>]
    @Published public internal(set) var peerMemberships: [String: Set<String>]
    @Published public private(set) var peerRooms: [String: String]
    @Published public private(set) var audioPolicies: [String: AudioDevicePolicy]
    public var onAudioNotice: ((String) -> Void)?
    @Published public var audioNotice: String? {
        didSet { if let audioNotice { onAudioNotice?(audioNotice) } }
    }
    private var lastAudioDevices: [String: LocalAudioDevice] = [:]
    private var audioObservationStarted = false
    private var unavailableSince: [String: Date] = [:]
    @Published public private(set) var audioRooms: [String: String]
    @Published public private(set) var deviceLevels: [String: Double]
    @Published public private(set) var identity: Identity?
    @Published public private(set) var identityLoading = false
    private let defaults: UserDefaults
    private let persistenceKey: String
    public let mesh = AudioMesh()
    @Published public internal(set) var deviceMoveRequest: DeviceMoveRequest?
    public var onApprovedDeviceMove: ((String) -> Void)?
    var moveReply: ((SignedEnvelope) -> Void)?
    var seenMoveRequests: [String: Date] = [:]
    let network = LocalNetwork()
    @Published public internal(set) var peerAudioDevices: [String: [LocalAudioDevice]] = [:]
    var reportedAudioDevices: [LocalAudioDevice] = []
    var lastInventoryRefresh = Date.distantPast
    var inventoryPending: Set<String> = []
    private var pendingReplies: [String: (SignedEnvelope) -> Void] = [:]
    private var issuedNonces: [String: Date] = [:]
    private var receivedIDs: Set<String> = []
    private var refreshTimer: Timer?

    public var deviceID: String { identity?.id ?? "unavailable" }
    public var card: PeerCard {
        PeerCard(publicKey: identity?.publicKey ?? "", name: String(name.prefix(60)), kind: Self.kind)
    }
    public static var kind: String {
        #if os(iOS)
        return "iphone"
        #else
        return "mac"
        #endif
    }
    public static var systemDeviceName: String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }
    public var fingerprint: String { String(deviceID.prefix(8)).uppercased() }
    public var regions: [String] { Array(Set(rooms.map(\.region))).sorted() }

    public init(identity: Identity? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.persistenceKey = Identity.usesDevelopmentFile ? "SoundboundHub.development.v1" : "SoundboundHub.v1"
        self.identity = identity
        let savedData = defaults.data(forKey: persistenceKey) ?? defaults.data(forKey: "SoundboundHub.v1")
        let saved = savedData.flatMap { try? JSONDecoder().decode(SavedHub.self, from: $0) }
        let savedName = saved?.name
        name = (savedName == nil || savedName == "My Mac" || savedName == "My iPhone") ? Self.systemDeviceName : savedName!
        rooms = saved?.rooms ?? []
        friends = saved?.friends ?? []
        deviceRoom = saved?.deviceRoom
        deviceLevels = saved?.deviceLevels ?? [:]
        audioRooms = saved?.audioRooms ?? [:]
        audioPolicies = saved?.audioPolicies ?? [:]
        peerRooms = saved?.peerRooms ?? [:]
        deviceRooms = saved?.deviceRooms ?? Set(saved?.deviceRoom.map { [$0] } ?? [])
        audioMemberships = saved?.audioMemberships ?? (saved?.audioRooms ?? [:]).mapValues { Set([$0]) }
        peerMemberships = saved?.peerMemberships ?? (saved?.peerRooms ?? [:]).mapValues { Set([$0]) }
        network.changed = { [weak self] in self?.nearby = $0 }
        network.status = { [weak self] value in
            self?.discoveryStatus = value
            if ProcessInfo.processInfo.arguments.contains("--mesh-diagnostics") { print("Soundbound discovery: \(value)") }
        }
        network.incoming = { [weak self] envelope, respond in self?.receive(envelope, respond: respond) }
        mesh.request = { [weak self] envelope, endpoint, completion in
            self?.network.request(envelope, endpoint: endpoint, completion: completion)
        }
        if identity != nil {
            renewInvite()
            restoreDiscovery()
        } else {
            // Keychain may ask for access after a development rebuild. Never block the UI.
            identityLoading = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let loaded = try? Identity()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.identity = loaded
                    if let loaded, Identity.usesDevelopmentFile { self.adoptDevelopmentIdentity(loaded) }
                    self.identityLoading = false
                    if loaded == nil { self.notice = InviteError.unavailable.localizedDescription }
                    self.renewInvite()
                    self.restoreDiscovery()
                }
            }
        }
    }
    deinit { refreshTimer?.invalidate() }

    private func adoptDevelopmentIdentity(_ identity: Identity) {
        let marker = "SoundboundHub.developmentIdentity"
        guard defaults.string(forKey: marker) != identity.id else { return }
        // This prototype stores only locally-created rooms. Remote pairing does
        // not import rooms, so this migration cannot claim someone else's room.
        let previousIdentity = defaults.string(forKey: marker)
        for index in rooms.indices where previousIdentity == nil || rooms[index].owner == previousIdentity {
            let previousOwner = rooms[index].owner
            rooms[index].owner = identity.id
            if rooms[index].members.remove(previousOwner) != nil {
                rooms[index].members.insert(identity.id)
            }
            if let level = deviceLevels.removeValue(forKey: previousOwner) {
                deviceLevels[identity.id] = level
            }
        }
        let needsPairing = !friends.isEmpty
        friends = []
        persist()
        defaults.set(identity.id, forKey: marker)
        if needsPairing { notice = "Development now uses a local identity file. Add your paired devices once more to approve this identity. Your rooms have been kept." }
    }

    public func save() {
        name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        if name.isEmpty { name = Self.systemDeviceName }
        persist()
        renewInvite()
    }
    func persist() {
        let saved = SavedHub(name: name, rooms: rooms, friends: friends, deviceRoom: deviceRoom, deviceLevels: deviceLevels, audioRooms: audioRooms, audioPolicies: audioPolicies, peerRooms: peerRooms, deviceRooms: deviceRooms, audioMemberships: audioMemberships, peerMemberships: peerMemberships)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: persistenceKey) }
    }
    public func renewInvite() {
        guard let identity else { return }
        issuedNonces = issuedNonces.filter { $0.value > Date() }
        let nonce = UUID().uuidString
        let expires = Date().addingTimeInterval(600)
        let invitation = Invitation(peer: card, nonce: nonce, expires: expires)
        guard let envelope = try? identity.sign(invitation) else { return }
        issuedNonces[nonce] = expires
        inviteLink = envelope.link; friendCode = invitation.code
        if discovering { network.update(invite: envelope) }
    }
    private func restoreDiscovery() {
        if defaults.bool(forKey: "Soundbound.discoveryEnabled") || ProcessInfo.processInfo.arguments.contains("--discover") {
            setDiscovery(true)
        }
    }
    public func setDiscovery(_ enabled: Bool) {
        if enabled {
            guard identity != nil, let (envelope, _) = try? SignedEnvelope.from(link: inviteLink) else { return }
            discovering = true
            defaults.set(true, forKey: "Soundbound.discoveryEnabled")
            discoveryStatus = "Looking for nearby Soundbound devices…"
            network.start(invite: envelope, ownID: deviceID)
            refreshTimer?.invalidate()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.renewInvite() }
        } else {
            defaults.set(false, forKey: "Soundbound.discoveryEnabled")
            mesh.stop()
            discovering = false; network.stop(); refreshTimer?.invalidate()
            discoveryStatus = "Discovery is off"
            // No pending approval can remain usable after the listener stops.
            requests = []; pendingReplies = [:]; outgoing = []
        }
    }
    public func shareMicrophone(to id: String) {
        guard let identity, friends.contains(where: { $0.id == id }),
              let peer = nearby.first(where: { $0.id == id }) else {
            notice = "Pair this device and turn on Discover on both devices first."; return
        }
        mesh.shareMicrophone(to: peer, identity: identity, card: card)
    }

    public func sendAudioTest(to id: String, outputID: String? = nil) {
        guard let identity, friends.contains(where: { $0.id == id }),
              let peer = nearby.first(where: { $0.id == id }) else {
            notice = "Pair this device and turn on Discover on both devices first."; return
        }
        mesh.sendTestTone(to: peer, identity: identity, card: card, outputID: outputID)
    }

    public func addRoom(name: String, region: String, policy: JoinPolicy) {
        guard identity != nil else { notice = "Unlock your device identity before creating a room."; return }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !place.isEmpty else { notice = "Give the room and region a name."; return }
        rooms.append(AudioRoom(name: String(title.prefix(60)), region: String(place.prefix(60)), owner: deviceID, policy: policy, members: [deviceID]))
        save()
    }
    public func updateRoom(_ room: AudioRoom) {
        guard room.owner == deviceID, let index = rooms.firstIndex(where: { $0.id == room.id }) else { return }
        var updated = room; updated.level = min(1, max(0, room.level))
        rooms[index] = updated; persist()
    }
    public func setDeviceLevel(_ id: String, level: Double) {
        deviceLevels[id] = min(1, max(0, level))
        persist()
    }
    public func moveDevice(to roomID: String?) {
        guard identity != nil else { notice = "Unlock your device identity before moving devices."; return }
        guard roomID == nil || rooms.contains(where: { $0.id == roomID && $0.owner == deviceID }) else {
            notice = "You need room access before moving this device."; return
        }
        if let roomID { deviceRooms.insert(roomID) } else { deviceRooms.removeAll() }
        deviceRoom = roomID
        for index in rooms.indices {
            if deviceRooms.contains(rooms[index].id) { rooms[index].members.insert(deviceID) }
            else { rooms[index].members.remove(deviceID) }
        }
        persist()
    }
    public func policy(for id: String) -> AudioDevicePolicy { audioPolicies[id] ?? AudioDevicePolicy() }
    public func setPolicy(_ policy: AudioDevicePolicy, for id: String) {
        audioPolicies[id] = policy
        persist()
    }
    public func observeAudioDevices(_ devices: [LocalAudioDevice], now: Date = Date()) {
        reportedAudioDevices = devices
        refreshPeerInventories(now: now)
        var current = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, old) in lastAudioDevices where current[id] == nil {
            var missing = old
            missing.isAvailable = false; missing.selectedInput = false; missing.selectedOutput = false
            current[id] = missing
        }
        for (id, device) in current {
            let policy = policy(for: id)
            if audioObservationStarted, let old = lastAudioDevices[id], policy.notifyChanges {
                if old.isAvailable && !device.isAvailable {
                    audioNotice = "\(device.name) disconnected."
                } else if old.selectedOutput != device.selectedOutput {
                    audioNotice = device.selectedOutput ? "Sound moved to \(device.name)." : "Sound moved away from \(device.name)."
                } else if old.selectedInput != device.selectedInput {
                    audioNotice = device.selectedInput ? "Microphone changed to \(device.name)." : "Microphone moved away from \(device.name)."
                }
            }
            if device.isAvailable || device.isChecking || device.busy { unavailableSince[id] = nil }
            else {
                let since = unavailableSince[id] ?? now
                unavailableSince[id] = since
                if policy.removeWhenDisconnected, now.timeIntervalSince(since) >= 3, audioRooms[id] != nil {
                    audioRooms[id] = nil; audioMemberships[id] = nil
                    persist()
                }
            }
        }
        lastAudioDevices = current
        audioObservationStarted = true
    }

    public func movePeer(_ id: String, to roomID: String?) {
        guard friends.contains(where: { $0.id == id }), identity != nil,
              roomID == nil || rooms.contains(where: { $0.id == roomID && $0.owner == deviceID }) else {
            notice = "Pair this device and choose one of your rooms first."; return
        }
        if let roomID { peerMemberships[id, default: []].insert(roomID) } else { peerMemberships[id] = nil }
        peerRooms[id] = roomID
        persist()
    }

    /// A whole-device room assignment includes its currently attached audio components.
    /// Explicit component memberships remain independent of the parent assignment.
    public func audioDevice(_ id: String, belongsTo roomID: String) -> Bool {
        deviceRooms.contains(roomID) || audioMemberships[id]?.contains(roomID) == true
    }

    public func moveAudioDevice(_ id: String, to roomID: String?) {
        guard identity != nil, roomID == nil || rooms.contains(where: { $0.id == roomID && $0.owner == deviceID }) else {
            notice = "You need room access before moving this device."; return
        }
        if let roomID { audioMemberships[id, default: []].insert(roomID) } else { audioMemberships[id] = nil }
        audioRooms[id] = roomID
        persist()
    }

    public func removeDevice(from roomID: String) {
        deviceRooms.remove(roomID)
        if deviceRoom == roomID { deviceRoom = deviceRooms.sorted().first }
        if let index = rooms.firstIndex(where: { $0.id == roomID }) { rooms[index].members.remove(deviceID) }
        persist()
    }
    public func removeAudioDevice(_ id: String, from roomID: String) {
        audioMemberships[id]?.remove(roomID)
        audioRooms[id] = audioMemberships[id]?.sorted().first
        persist()
    }
    public func removePeer(_ id: String, from roomID: String) {
        peerMemberships[id]?.remove(roomID)
        peerRooms[id] = peerMemberships[id]?.sorted().first
        persist()
    }

    public func removeFriend(_ id: String) {
        mesh.stop()
        peerAudioDevices[id] = nil
        friends.removeAll { $0.id == id }; peerRooms[id] = nil; peerMemberships[id] = nil; save()
        notice = "Removed locally. No live audio routes exist in this build."
    }
    public var nearbyInviteLink: String {
        "soundbound://pair?id=" + deviceID + "&code=" + friendCode
    }
    public func join(codeOrLink input: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identity != nil else { notice = InviteError.unavailable.localizedDescription; return }
        do {
            let peer: NearbyPeer
            if let link = URLComponents(string: value), link.scheme == "soundbound", link.host == "pair" {
                guard let id = link.queryItems?.first(where: { $0.name == "id" })?.value,
                      let code = link.queryItems?.first(where: { $0.name == "code" })?.value,
                      let found = nearby.first(where: { $0.id == id && $0.invitation.code == code && $0.invitation.expires > Date() }) else {
                    notice = "Open Discover on both devices, then scan again. This code only works nearby."; return
                }
                guard id != deviceID else { throw InviteError.ownIdentity }
                peer = found
            } else if value.hasPrefix("soundbound:") {
                let (_, invitation) = try SignedEnvelope.from(link: value)
                guard invitation.peer.id != deviceID else { throw InviteError.ownIdentity }
                guard let found = nearby.first(where: { $0.id == invitation.peer.id && $0.invitation.nonce == invitation.nonce }) else {
                    notice = "Invitation verified. For this first build, both devices must turn on Discover on the same local network."; return
                }
                peer = found
            } else {
                let matches = nearby.filter { $0.invitation.code == value.uppercased() }
                guard matches.count == 1, let found = matches.first else {
                    notice = "That code isn’t visible nearby. Turn on Discover on both devices, or paste the full invite link."; return
                }
                peer = found
            }
            sendRequest(to: peer)
        } catch { notice = error.localizedDescription }
    }
    public func sendRequest(to peer: NearbyPeer) {
        guard let identity, !outgoing.contains(peer.id), !friends.contains(where: { $0.id == peer.id }) else { return }
        guard peer.invitation.expires > Date() else { notice = "That code expired. Ask for a new one."; return }
        let requestID = UUID().uuidString
        let message = JoinMessage(requestID: requestID, inviteNonce: peer.invitation.nonce, peer: card, created: Date())
        guard let signed = try? identity.sign(message) else { return }
        outgoing.insert(peer.id); notice = "Request sent. Waiting for \(peer.invitation.peer.name) to approve."
        network.request(signed, endpoint: peer.endpoint) { [weak self] result in
            guard let self else { return }
            self.outgoing.remove(peer.id)
            do {
                let envelope = try result.get()
                let reply = try envelope.verified(as: JoinReply.self)
                guard reply.version == 1, reply.requestID == requestID, reply.recipient == self.deviceID,
                      envelope.signer == peer.invitation.peer.publicKey, reply.peer.publicKey == envelope.signer,
                      abs(reply.created.timeIntervalSinceNow) < 120 else { throw InviteError.invalidSignature }
                if reply.approved {
                    self.recordFriend(reply.peer)
                    self.notice = "\(reply.peer.name) accepted. You’re now paired. Audio sharing still needs its own permission."
                } else { self.notice = "\(peer.invitation.peer.name) declined the request." }
            } catch { self.notice = "The request expired or the other device disconnected. Try again when both are nearby." }
        }
    }
    func receive(_ envelope: SignedEnvelope, respond: @escaping (SignedEnvelope) -> Void) {
        if receiveDeviceMove(envelope, respond: respond) { return }
        if answerInventory(envelope, respond: respond) { return }
        if let identity, mesh.receive(envelope, nearby: nearby, friends: friends, identity: identity, card: card, devices: reportedAudioDevices, respond: respond) { return }
        guard let message = try? envelope.verified(as: JoinMessage.self), message.version == 1,
              message.peer.publicKey == envelope.signer, message.peer.id != deviceID,
              !message.peer.name.isEmpty, message.peer.name.count <= 60,
              abs(message.created.timeIntervalSinceNow) < 120,
              let expires = issuedNonces[message.inviteNonce], expires > Date(),
              !receivedIDs.contains(message.requestID), receivedIDs.count < 1000,
              requests.count < 20 else { return }
        receivedIDs.insert(message.requestID)
        requests.append(AccessRequest(id: message.requestID, peer: message.peer, roomID: message.roomID, created: message.created))
        pendingReplies[message.requestID] = respond
    }
    public func decide(_ request: AccessRequest, approve: Bool) {
        guard let identity, requests.contains(where: { $0.id == request.id }),
              let respond = pendingReplies.removeValue(forKey: request.id) else { return }
        requests.removeAll { $0.id == request.id }
        guard abs(request.created.timeIntervalSinceNow) < 120 else { notice = "This request expired. Ask them to try again."; return }
        let reply = JoinReply(requestID: request.id, recipient: request.peer.id, approved: approve, peer: card, rooms: [], created: Date())
        guard let envelope = try? identity.sign(reply) else { return }
        respond(envelope)
        if approve { recordFriend(request.peer) }
    }
    func updatePeerCard(_ card: PeerCard) {
        guard let index = friends.firstIndex(where: { $0.id == card.id }), friends[index].card.name != card.name else { return }
        friends[index].card = card
        persist()
    }
    private func recordFriend(_ card: PeerCard) {
        friends.removeAll { $0.id == card.id }
        friends.append(KnownPeer(card: card, acceptedAt: Date())); save()
    }
}
