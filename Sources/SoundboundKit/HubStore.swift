import Foundation
import Combine
#if os(iOS)
import UIKit
#endif

public final class HubStore: ObservableObject {
    public static var appBuildLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Local"
        return version + " (" + build + ")"
    }
    @Published public private(set) var activeRoomID: String?
    public var activeRoom: AudioRoom? { rooms.first { $0.id == activeRoomID } }
    @Published public var name: String
    @Published public internal(set) var rooms: [AudioRoom]
    @Published public private(set) var friends: [KnownPeer]
    @Published public private(set) var nearby: [NearbyPeer] = []
    @Published public private(set) var requests: [AccessRequest] = []
    @Published public private(set) var outgoing: Set<String> = []
    @Published public private(set) var discovering = false
    public let automaticPairedPlayback = true
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
    @Published public private(set) var audioDeviceStates: [String: AudioDeviceState] = [:]
    private var audioObservationStarted = false
    private var unavailableSince: [String: Date] = [:]
    @Published public private(set) var audioRooms: [String: String]
    @Published public internal(set) var deviceLevels: [String: Double]
    public var onPlaybackGainChanged: ((String, Double) -> Void)?
    @Published public private(set) var identity: Identity?
    @Published public private(set) var identityLoading = false
    let defaults: UserDefaults
    private let persistenceKey: String
    public let mesh = AudioMesh()
    public let roomAudio = RoomAudio()
    public let ping = PeerPingMonitor()
    @Published public var developerMode = false { didSet { defaults.set(developerMode, forKey: "Soundbound.developerMode") } }
    /// Whether this device may send sound to rooms, play sound from other devices, or both. Each device keeps its own.
    @Published public var audioDirection = AudioDirection(rawValue: UserDefaults.standard.string(forKey: "Soundbound.audioDirection") ?? "") ?? .both {
        didSet {
            UserDefaults.standard.set(audioDirection.rawValue, forKey: "Soundbound.audioDirection")
            if !audioDirection.sends, roomAudio.active { roomAudio.stop(reason: "This device is set to receive only.") }
            if !audioDirection.receives { roomAudio.stopReceiving() }
            startSharingIfAllowed()
        }
    }
    var roomComponentSeen: [String: Date] = [:]
    var pendingRoomEdits: [String: DispatchWorkItem] = [:]
    /// Paired devices whose Apple Account has been verified, by device ID.
    @Published var linkedAccounts: [String: LinkedAccount] = [:]
    var proofsBeingChecked: Set<String> = []
    var appleKeyCache: (keys: [AppleAccountProof.Key], fetched: Date)?
    var appleKeyWaiters: [([AppleAccountProof.Key]) -> Void] = []
    var appleKeyLastFailure = Date.distantPast
    var latestAccountProof: [String: String] = [:]
    var accountLinkTransport: ((SignedEnvelope, LocalEndpoint, @escaping (Result<SignedEnvelope, Error>) -> Void) -> Void)?
    var automaticAccountPeers: [String: String] = [:]
    var ignoredAccountPeers: Set<String> = []
    var accountLinkAttempts: [String: UUID] = [:]
    var accountLinkLastAttempt: [String: Date] = [:]
    var accountLinkChallenges: [String: AccountLinkChallengeState] = [:]
    var accountLinkInbound: [String: Date] = [:]
    private var accountObservation: AnyCancellable?
    var accountLinkAccount: String?
    var accountLinkProof: String?
    var accountLinkGeneration = UUID()
    /// This device's verified Apple Account subject and its proof. Replaceable in tests.
    /// Names of applications making sound on this Mac right now, whether or not they are shared. Set by the Mac app.
    public var playingApplications: () -> [String] = { [] }
    /// Each paired device's own pipeline, as that device last described it. Filled only while the audio map is open.
    var peerMaps: [String: (map: AudioMapSnapshot, received: Date)] = [:]
    var audioMapOpen = false
    /// What each paired device last said about whether it sends, receives or both.
    @Published public internal(set) var peerDirections: [String: AudioDirection] = [:]
    /// A scanned code whose device has not been seen on the network yet.
    var pendingJoin: (link: String, deadline: Date)?
    func retryPendingJoin() {
        guard let pending = pendingJoin else { return }
        join(codeOrLink: pending.link)
    }
    /// Asks the Mac app to meter what the Mac is playing while the audio map is open, shared or not.
    public var onLevelMonitor: ((Bool) -> Void)?
    public static let monitorLevelID = "monitor:mac-output"
    var accountID: () -> String? = { AppleAccount.shared.accountID }
    var accountProof: () -> String? = { AppleAccount.shared.accountProof }
    var accountReady: () -> Bool = { !AppleAccount.shared.isCheckingCredential }
    public let spatial: RoomSpatialStore
    private var spatialObservation: AnyCancellable?
    public var onApplicationAudioStart: (() -> Void)?
    public var onApplicationAudioStop: (() -> Void)?
    public let activity = DeviceAudioActivity()
    private var activityObservation: AnyCancellable?
    @Published public internal(set) var deviceMoveRequest: DeviceMoveRequest?
    @Published public internal(set) var outgoingDeviceMove: HeadphoneMoveProgress?
    public var onApprovedDeviceMove: ((String) -> Void)?
    @Published public internal(set) var recordingRequest: RemoteRecordingRequest?
    var recordingReply: ((SignedEnvelope) -> Void)?
    var seenRecordingRequests: [String: Date] = [:]
    var pendingRemoteRecording: (request: String, peer: String, row: String)?
    var moveReply: ((SignedEnvelope) -> Void)?
    var seenMoveRequests: [String: Date] = [:]
    let network = LocalNetwork()
    @Published public internal(set) var peerAudioDevices: [String: [LocalAudioDevice]] = [:]
    /// The fixed speakers and microphones each paired device last reported, kept so an offline device
    /// still shows what it has. Display only: routing and room audio use `peerAudioDevices`.
    @Published public internal(set) var lastKnownPeerDevices: [String: [LocalAudioDevice]] = [:]
    private static let lastKnownKey = "Soundbound.lastKnownPeerDevices.v1"
    private func rememberPeerDevices(_ devices: [LocalAudioDevice], peerID: String) {
        // Headphones can move to another host while this one is away, so only built-in parts are remembered.
        let fixed: [LocalAudioDevice] = devices.filter { !$0.canMoveBetweenHosts }.map { device in
            var copy = device
            copy.isAvailable = false; copy.isChecking = false; copy.busy = false
            copy.selectedInput = false; copy.selectedOutput = false
            copy.canConnect = false; copy.canDisconnect = false; copy.canTest = false; copy.awaitingTestAnswer = false
            copy.volume = nil; copy.latency = nil
            return copy
        }
        guard !fixed.isEmpty else { return }
        // Partial route inventories must not erase a previously known speaker.
        let ids = Set(fixed.map(\.id))
        let hasPhoneSpeaker = ids.contains(AudioDeviceInventory.phoneSpeakerID)
        let remembered = fixed + (lastKnownPeerDevices[peerID] ?? []).filter {
            !ids.contains($0.id) && !(hasPhoneSpeaker && $0.connection == .builtIn && $0.hasOutput)
        }
        guard lastKnownPeerDevices[peerID] != remembered else { return }
        lastKnownPeerDevices[peerID] = remembered
        if let data = try? JSONEncoder().encode(lastKnownPeerDevices) { defaults.set(data, forKey: Self.lastKnownKey) }
    }
    var reportedAudioDevices: [LocalAudioDevice] = []
    var lastInventoryRefresh = Date.distantPast
    var inventoryPending: [String: (id: String, deadline: Date)] = [:]
    var inventoryReceived: Set<String> = []
    @Published var peerPlayback: [String: [DevicePlaybackSnapshot]] = [:]
    var peerPlaybackUpdated: [String: Date] = [:]
    var inventoryTransport: ((SignedEnvelope, LocalEndpoint, TimeInterval, @escaping (Result<SignedEnvelope, Error>) -> Void) -> Void)?
    private var pendingReplies: [String: (SignedEnvelope) -> Void] = [:]
    private var issuedNonces: [String: Date] = [:]
    private var receivedIDs: [String: Date] = [:]
    private var refreshTimer: Timer?

    public var deviceID: String { identity?.id ?? "unavailable" }
    public var card: PeerCard {
        PeerCard(publicKey: identity?.publicKey ?? "", name: String(name.prefix(60)), kind: Self.kind,
                 owner: AppleAccount.shared.isSignedIn ? AppleAccount.shared.displayName.map { String($0.prefix(60)) } : nil)
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
        self.developerMode = defaults.bool(forKey: "Soundbound.developerMode")
        self.spatial = RoomSpatialStore(defaults: defaults)
        self.activeRoomID = defaults.string(forKey: "Soundbound.activeRoom")
        self.persistenceKey = Identity.usesDevelopmentFile ? "SoundboundHub.development.v1" : "SoundboundHub.v1"
        self.identity = identity
        if let identity { AppleAccount.shared.deviceBinding = identity.publicKey }
        let savedData = defaults.data(forKey: persistenceKey) ?? defaults.data(forKey: "SoundboundHub.v1")
        let saved = savedData.flatMap { try? JSONDecoder().decode(SavedHub.self, from: $0) }
        let savedName = saved?.name
        name = (savedName == nil || savedName == "My Mac" || savedName == "My iPhone") ? Self.systemDeviceName : savedName!
        rooms = saved?.rooms ?? []
        friends = saved?.friends ?? []
        automaticAccountPeers = defaults.dictionary(forKey: "Soundbound.automaticAccountPeers.v1") as? [String: String] ?? [:]
        ignoredAccountPeers = Set(defaults.stringArray(forKey: "Soundbound.ignoredAccountPeers.v1") ?? [])
        if let data = defaults.data(forKey: "Soundbound.linkedAccounts.v1"),
           let known = try? JSONDecoder().decode([String: LinkedAccount].self, from: data) {
            let paired = Set((saved?.friends ?? []).map(\.id))
            linkedAccounts = known.filter { paired.contains($0.key) }
        }
        if let data = defaults.data(forKey: Self.lastKnownKey),
           let known = try? JSONDecoder().decode([String: [LocalAudioDevice]].self, from: data) {
            let paired = Set((saved?.friends ?? []).map(\.id))
            lastKnownPeerDevices = known.filter { paired.contains($0.key) }
        }
        deviceRoom = saved?.deviceRoom
        deviceLevels = saved?.deviceLevels ?? [:]
        audioRooms = saved?.audioRooms ?? [:]
        audioPolicies = saved?.audioPolicies ?? [:]
        peerRooms = saved?.peerRooms ?? [:]
        deviceRooms = saved?.deviceRooms ?? Set(saved?.deviceRoom.map { [$0] } ?? [])
        audioMemberships = saved?.audioMemberships ?? (saved?.audioRooms ?? [:]).mapValues { Set([$0]) }
        peerMemberships = saved?.peerMemberships ?? (saved?.peerRooms ?? [:]).mapValues { Set([$0]) }
        network.changed = { [weak self] in self?.observeNearby($0) }
        roomAudio.attach(self)
        ping.attach(self)
        mesh.onRouteDetails = { [weak self] peer, session, details in self?.ping.recordRouteDetails(peerID: peer, sessionID: session, details: details) }
        mesh.onTransportChanged = { [weak self] peer, session, path in self?.ping.recordMediaPath(peerID: peer, sessionID: session, path: path) }
        mesh.onRoundTrip = { [weak self] peer, session, ms in self?.ping.recordRoundTrip(peerID: peer, sessionID: session, milliseconds: ms) }
        activity.inputGain = { [weak self] in self?.audioGain(for: $0, input: true) ?? 1 }
        activity.playbackGain = { [weak self] in self?.playbackGain(for: nil) ?? 1 }
        mesh.inputGain = { [weak self] in self?.inputGain(for: $0) ?? 1 }
        mesh.outputGain = { [weak self] in self?.playbackGain(for: $0) ?? 1 }
        network.status = { [weak self] value in
            self?.discoveryStatus = value
            if ProcessInfo.processInfo.arguments.contains("--mesh-diagnostics") { print("Soundbound discovery: \(value)") }
        }
        network.incoming = { [weak self] envelope, respond in self?.receive(envelope, respond: respond) }
        mesh.onTestReceived = { [weak self] outputID in
            guard let self, let id = outputID ?? self.reportedAudioDevices.first(where: { $0.selectedOutput })?.id else { return }
            self.activity.chirp(id)
            self.activity.chirp(self.deviceID)
        }
        activity.stopStream = { [weak self] in self?.mesh.stop(); self?.roomAudio.stop() }
        mesh.onRecordingFrame = { [weak self] pcm in
            guard let self else { return }
            let gain = self.pendingRemoteRecording.map { self.audioGain(for: $0.row, input: true) } ?? 1
            self.activity.receiveRemoteFrame(AudioGain.applying(gain, to: pcm))
        }
        mesh.onLevel = { [weak self] id, pcm, recording in self?.activity.showStreamLevel(id, pcm: pcm, recording: recording) }
        mesh.onFinished = { [weak self] in
            guard let self else { return }
            self.activity.finishRemoteRecording(); self.pendingRemoteRecording = nil
            self.activity.clearStreams()
        }
        activityObservation = mesh.$active.sink { [weak self] active in if !active { self?.activity.clearWaiting() } }
        spatialObservation = spatial.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        mesh.request = { [weak self] envelope, endpoint, completion in
            self?.network.request(envelope, endpoint: endpoint, completion: completion)
        }
        // Observe after profile mutations finish: @Published emits before assignment.
        accountObservation = AppleAccount.shared.objectWillChange
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.refreshAccountDevices()
                if self?.discovering == false { self?.restoreDiscovery() }
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
                    if let loaded { AppleAccount.shared.deviceBinding = loaded.publicKey }
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
    func observeNearby(_ peers: [NearbyPeer]) {
        defer { retryPendingJoin() }
        // One device can be found on two networks at once (Wi-Fi and a cable); list it once.
        var seen = Set<String>()
        nearby = peers.filter { seen.insert($0.id).inserted }
        roomAudio.reconcile(); ping.refresh()
        refreshAccountDevices()
    }

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
        roomAudio.reconcile()
        ping.refresh()
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
        guard accountReady() else { return }
        refreshAccountDevices()
        if defaults.bool(forKey: "Soundbound.discoveryEnabled") || ProcessInfo.processInfo.arguments.contains("--discover") {
            setDiscovery(true)
        }
    }
    public func setDiscovery(_ enabled: Bool) {
        guard !enabled || accountReady() else { return }
        if accountID() != nil { defaults.set(!enabled, forKey: "Soundbound.accountDiscoveryDisabled") }
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
            decideDeviceMove(approve: false)
            decideRecordingRequest(allow: false)
            mesh.stop()
            roomAudio.stop()
            discovering = false; network.stop(); refreshTimer?.invalidate()
            accountLinkAttempts.removeAll(); accountLinkChallenges.removeAll()
            inventoryPending.removeAll()
            inventoryReceived.removeAll()
            accountLinkGeneration = UUID(); accountLinkInbound.removeAll()
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
        mesh.transmissionGain = nil
        mesh.shareMicrophone(to: peer, identity: identity, card: card)
    }
    func issuedAccountInviteIsValid(_ nonce: String, now: Date) -> Bool {
        issuedNonces[nonce].map { $0 > now } ?? false
    }

    public func sendAudioTest(to id: String, outputID: String? = nil, repeating: Bool = true) {
        guard let identity, friends.contains(where: { $0.id == id }),
              let peer = nearby.first(where: { $0.id == id }) else {
            notice = "Pair this device and turn on Discover on both devices first."; return
        }
        guard !mesh.active else { notice = "Finish the current audio request first."; return }
        let key = outputID.map { Self.remoteComponentID(peer: id, component: $0) } ?? "peer:" + id
        mesh.transmissionGain = { [weak self] in self?.audioGain(for: key) ?? 1 }
        activity.waiting(key)
        mesh.onTestStarted = { [weak self] in self?.activity.chirp(key); self?.activity.chirp("peer:" + id) }
        mesh.sendTestTone(to: peer, identity: identity, card: card, outputID: outputID, repeating: repeating)
        // A device that is not paired with this one, or has Soundbound closed, simply does not answer. Say so after
        // a few seconds instead of sitting there.
        let name = peer.invitation.peer.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.activity.modes[key] == .waiting else { return }
            self.mesh.stop(reason: "No reply")
            self.notice = "\(name) didn’t answer the test sound. Check Soundbound is open on it and that it is paired with this device."
        }
    }

    public func addRoom(name: String, region: String, policy: JoinPolicy) {
        guard identity != nil else { notice = "Unlock your device identity before creating a room."; return }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !place.isEmpty else { notice = "Give the room and region a name."; return }
        rooms.append(AudioRoom(name: String(title.prefix(60)), region: String(place.prefix(60)), owner: deviceID, policy: policy, members: [deviceID]))
        save()
    }
    public func setActiveRoom(_ id: String?) {
        guard id == nil || rooms.contains(where: { $0.id == id }) else { return }
        if activeRoomID != id { mesh.stop(); roomAudio.stop() }
        activeRoomID = id
        defaults.set(id, forKey: "Soundbound.activeRoom")
        startSharingIfAllowed()
    }
    public func deleteRoom(_ id: String) {
        if let room = rooms.first(where: { $0.id == id }), room.owner != deviceID, isOwnDevice(room.owner) {
            // The room lives on another of this person's devices: ask it to delete, and it mirrors back.
            if activeRoomID == id { setActiveRoom(nil) }
            sendRoomEdit(roomID: id, owner: room.owner, room: nil)
            return
        }
        guard rooms.contains(where: { $0.id == id && $0.owner == deviceID }) else {
            notice = "Delete this room on the device that created it."; return
        }
        if activeRoomID == id { setActiveRoom(nil) }
        rooms.removeAll { $0.id == id }
        deviceRooms.remove(id)
        if deviceRoom == id { deviceRoom = deviceRooms.sorted().first }
        for key in Array(audioMemberships.keys) {
            audioMemberships[key]?.remove(id)
            if audioRooms[key] == id { audioRooms[key] = audioMemberships[key]?.sorted().first }
        }
        for key in Array(peerMemberships.keys) {
            peerMemberships[key]?.remove(id)
            if peerRooms[key] == id { peerRooms[key] = peerMemberships[key]?.sorted().first }
        }
        persist()
    }

    public func updateRoom(_ room: AudioRoom) {
        if room.owner != deviceID, isOwnDevice(room.owner), let index = rooms.firstIndex(where: { $0.id == room.id }) {
            // Show the change at once, then send it after a short pause so typing a name is one request.
            rooms[index] = room
            pendingRoomEdits[room.id]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let latest = self.rooms.first(where: { $0.id == room.id }) else { return }
                self.sendRoomEdit(roomID: room.id, owner: room.owner, room: latest)
            }
            pendingRoomEdits[room.id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            return
        }
        guard room.owner == deviceID, let index = rooms.firstIndex(where: { $0.id == room.id }) else { return }
        var updated = room; updated.level = min(1, max(0, room.level))
        rooms[index] = updated; roomAudio.refreshDelivery(); persist()
    }
    public func setDeviceLevel(_ id: String, level: Double) {
        deviceLevels[id] = min(1, max(0, level))
        persist()
    }
    public func moveDevice(to roomID: String?) {
        guard identity != nil else { notice = "Unlock your device identity before moving devices."; return }
        if let roomID, let room = rooms.first(where: { $0.id == roomID }), room.owner != deviceID {
            // Someone else holds this room: ask its holder to add this device's speakers.
            for device in reportedAudioDevices where device.hasOutput { changeOwnRoomOutput(device.id, room: room, included: true) }
            return
        }
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
        expirePeerPlayback(now: now)
        #if os(iOS)
        for device in devices where device.id == AudioDeviceInventory.phoneSpeakerID {
            if let old = device.legacyID, old != device.id, let memberships = audioMemberships.removeValue(forKey: old) {
                audioMemberships[device.id, default: []].formUnion(memberships)
                audioRooms[device.id] = audioRooms.removeValue(forKey: old)
                persist()
            }
        }
        #endif
        let devices = AudioDeviceInventory.reconcile(devices)
        reportedAudioDevices = devices
        roomAudio.reconcile()
        let observed = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        for id in Set(audioDeviceStates.keys.filter { !$0.hasPrefix("remote:") }).union(observed.keys) {
            var state = audioDeviceStates[id] ?? AudioDeviceState()
            state.observe(observed[id], now: now)
            audioDeviceStates[id] = state
        }
        refreshPeerInventories(now: now)
        refreshAccountDevices(now: now)
        ping.refresh(now: now)
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

    public func recordAudioIntent(_ action: LocalAudioAction, id: String) {
        let intent: AudioDeviceState.Intent
        switch action {
        case .connect: intent = .connect
        case .disconnect: intent = .disconnect
        case .useInput: intent = .useInput
        case .useOutput: intent = .useOutput
        default: return
        }
        var state = audioDeviceStates[id] ?? AudioDeviceState()
        state.request(intent)
        audioDeviceStates[id] = state
    }

    func observePeerAudioDevices(_ devices: [LocalAudioDevice], peerID: String, now: Date = Date()) {
        let reconciled = AudioDeviceInventory.reconcile(devices)
        if var move = outgoingDeviceMove, move.targetID == peerID,
           move.phase == .requesting || move.phase == .waitingForConnection,
           reconciled.contains(where: { AudioDeviceInventory.identity(of: $0) == move.deviceIdentity && $0.isAvailable && $0.selectedOutput }) {
            move.phase = .connected
            outgoingDeviceMove = move
        }
        let oldIDs = (peerAudioDevices[peerID] ?? []).map { Self.remoteComponentID(peer: peerID, component: $0.id) }
        let observed = Dictionary(uniqueKeysWithValues: reconciled.map { (Self.remoteComponentID(peer: peerID, component: $0.id), $0) })
        for id in Set(oldIDs).union(observed.keys) {
            var state = audioDeviceStates[id] ?? AudioDeviceState()
            state.observe(observed[id], now: now)
            audioDeviceStates[id] = state
        }
        peerAudioDevices[peerID] = reconciled.isEmpty ? nil : reconciled
        rememberPeerDevices(reconciled, peerID: peerID)
        roomAudio.reconcile()
    }
    public func dismissDeviceMoveStatus() { outgoingDeviceMove = nil }

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
        if identity != nil, let roomID, let room = rooms.first(where: { $0.id == roomID }), room.owner != deviceID,
           reportedAudioDevices.contains(where: { $0.id == id }) {
            // One of this device's own speakers going into a room someone else holds: ask the holder.
            changeOwnRoomOutput(id, room: room, included: true); return
        }
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
        // A device added whole has no entry per speaker or microphone. Taking one part out
        // turns the whole-device membership into one entry for each of the other parts.
        var others: [String] = []
        if id.hasPrefix("remote:") {
            let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 3, peerMemberships[parts[1]]?.contains(roomID) == true {
                peerMemberships[parts[1]]?.remove(roomID)
                peerRooms[parts[1]] = peerMemberships[parts[1]]?.sorted().first
                others = displayedPeerDevices(parts[1]).filter { $0.id != parts[2] }.map { Self.remoteComponentID(peer: parts[1], component: $0.id) }
            }
        } else if deviceRooms.contains(roomID) {
            deviceRooms.remove(roomID)
            if deviceRoom == roomID { deviceRoom = deviceRooms.sorted().first }
            if let index = rooms.firstIndex(where: { $0.id == roomID }) { rooms[index].members.remove(deviceID) }
            others = reportedAudioDevices.filter { $0.id != id }.map(\.id)
        }
        for key in others {
            audioMemberships[key, default: []].insert(roomID)
            if audioRooms[key] == nil { audioRooms[key] = roomID }
        }
        audioMemberships[id]?.remove(roomID)
        audioRooms[id] = audioMemberships[id]?.sorted().first
        persist()
    }
    /// Take a whole device, and every speaker and microphone on it, out of a room.
    /// The room's holder does it directly; any other device asks the holder, part by part.
    public func removeHost(_ host: String, from room: AudioRoom) {
        let local = host == deviceID
        let parts = local ? reportedAudioDevices.map(\.id) : displayedPeerDevices(host).map { Self.remoteComponentID(peer: host, component: $0.id) }
        if room.owner == deviceID {
            if local { removeDevice(from: room.id) } else { removePeer(host, from: room.id) }
            for key in parts where audioMemberships[key]?.contains(room.id) == true { removeAudioDevice(key, from: room.id) }
            return
        }
        for key in parts {
            if local { changeOwnRoomOutput(key, room: room, included: false) } else { changeRoomMember(key, room: room, included: false) }
        }
    }
    /// Whether a device, or any part of it, is in a room.
    public func host(_ host: String, isIn roomID: String) -> Bool {
        if host == deviceID {
            return deviceRooms.contains(roomID) || audioMemberships.contains { !$0.key.hasPrefix("remote:") && $0.value.contains(roomID) }
        }
        return peerMemberships[host]?.contains(roomID) == true ||
            audioMemberships.contains { $0.key.hasPrefix("remote:" + host + ":") && $0.value.contains(roomID) }
    }
    public func removePeer(_ id: String, from roomID: String) {
        peerMemberships[id]?.remove(roomID)
        peerRooms[id] = peerMemberships[id]?.sorted().first
        persist()
    }

    public func removeFriend(_ id: String) {
        observePeerPlayback([], peerID: id)
        inventoryPending[id] = nil
        inventoryReceived.remove(id)
        if automaticAccountPeers[id] != nil {
            ignoredAccountPeers.insert(id)
            defaults.set(Array(ignoredAccountPeers), forKey: "Soundbound.ignoredAccountPeers.v1")
        }
        forgetAccountPeer(id)
        mesh.stop()
        roomAudio.stop()
        peerAudioDevices[id] = nil
        lastKnownPeerDevices[id] = nil
        if let data = try? JSONEncoder().encode(lastKnownPeerDevices) { defaults.set(data, forKey: Self.lastKnownKey) }
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
                    // Scanning a code is the request. Make this device findable and keep looking for the other one
                    // for a few seconds; it can take a moment for two devices to see each other.
                    if !discovering { setDiscovery(true) }
                    if pendingJoin?.link != value { pendingJoin = (value, Date().addingTimeInterval(12)); notice = "Looking for that device…" }
                    else if let pending = pendingJoin, pending.deadline < Date() {
                        pendingJoin = nil
                        notice = "Couldn’t find that device. Keep Soundbound open on it, on the same network, and scan again."
                    }
                    return
                }
                pendingJoin = nil
                guard id != deviceID else { throw InviteError.ownIdentity }
                peer = found
            } else if value.hasPrefix("soundbound:") {
                let (_, invitation) = try SignedEnvelope.from(link: value)
                guard invitation.peer.id != deviceID else { throw InviteError.ownIdentity }
                guard let found = nearby.first(where: { $0.id == invitation.peer.id && $0.invitation.nonce == invitation.nonce }) else {
                    if !discovering { setDiscovery(true) }
                    notice = "Invitation verified. Keep Soundbound open on both devices on the same network, then try again."; return
                }
                peer = found
            } else {
                let matches = nearby.filter { $0.invitation.code == value.uppercased() }
                guard matches.count == 1, let found = matches.first else {
                    if !discovering { setDiscovery(true) }
                    notice = "That code isn’t visible yet. Keep Soundbound open on both devices on the same network and try again."; return
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
                    self.notice = "\(reply.peer.name) accepted. You’re now paired for playback. Microphones stay under your control."
                } else { self.notice = "\(peer.invitation.peer.name) declined the request." }
            } catch { self.notice = "The request expired or the other device disconnected. Try again when both are nearby." }
        }
    }
    func receive(_ envelope: SignedEnvelope, now: Date = Date(), respond: @escaping (SignedEnvelope) -> Void) {
        if receiveAccountLink(envelope, now: now, respond: respond) { return }
        if ping.receive(envelope, respond: respond) { return }
        if receiveRoomComponent(envelope, respond: respond) { return }
        if receiveRoomEdit(envelope, respond: respond) { return }
        if receiveTuning(envelope, respond: respond) { return }
        if receiveDeviceMove(envelope, respond: respond) { return }
        if receiveRecordingRequest(envelope, respond: respond) { return }
        if answerInventory(envelope, respond: respond) { return }
        if roomAudio.receive(envelope, respond: respond) { return }
        if let identity, mesh.receive(envelope, nearby: nearby, friends: friends, identity: identity, card: card, devices: reportedAudioDevices, autoApprove: automaticPairedPlayback, expectedRecordingID: pendingRemoteRecording?.request, expectedRecordingPeer: pendingRemoteRecording?.peer, respond: respond) { return }
        receivedIDs = receivedIDs.filter { $0.value > now }
        guard let message = try? envelope.verified(as: JoinMessage.self), message.version == 1,
              message.peer.publicKey == envelope.signer, message.peer.id != deviceID,
              !message.peer.name.isEmpty, message.peer.name.count <= 60,
              abs(message.created.timeIntervalSince(now)) < 120,
              let expires = issuedNonces[message.inviteNonce], expires > now,
              receivedIDs[message.requestID] == nil, receivedIDs.count < 1000,
              requests.count < 20 else { return }
        receivedIDs[message.requestID] = message.created.addingTimeInterval(120)
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
    func recordFriend(_ card: PeerCard) {
        if ignoredAccountPeers.remove(card.id) != nil {
            defaults.set(Array(ignoredAccountPeers), forKey: "Soundbound.ignoredAccountPeers.v1")
        }
        friends.removeAll { $0.id == card.id }
        friends.append(KnownPeer(card: card, acceptedAt: Date())); save()
    }
}

/// Which way sound may travel for a device.
public enum AudioDirection: String, CaseIterable, Identifiable {
    case both, send, receive
    public var id: String { rawValue }
    public var title: String { self == .both ? "Both" : self == .send ? "Send" : "Receive" }
    public var longTitle: String { self == .both ? "Send & receive" : self == .send ? "Send only" : "Receive only" }
    public var sends: Bool { self != .receive }
    public var receives: Bool { self != .send }
}
