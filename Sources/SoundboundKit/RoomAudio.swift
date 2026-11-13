import Foundation
import Combine

struct RoomAudioDestination: Hashable {
    let peerID: String?
    let outputID: String
}

/// Resolves explicit component membership and whole-host membership without duplicates.
enum RoomAudioRoutes {
    static func outputs(roomID: String, hostID: String, devices: [LocalAudioDevice],
                        hostRooms: Set<String>, peerRooms: [String: Set<String>],
                        componentRooms: [String: Set<String>], peers: [KnownPeer],
                        online: Set<String>, peerDevices: [String: [LocalAudioDevice]]) -> Set<RoomAudioDestination> {
        var result = Set<RoomAudioDestination>()
        for device in devices where device.hasOutput && device.isAvailable && !device.busy {
            if hostRooms.contains(roomID) || componentRooms[device.id]?.contains(roomID) == true {
                result.insert(RoomAudioDestination(peerID: nil, outputID: device.id))
            }
        }
        for peer in peers where peer.id != hostID && online.contains(peer.id) {
            for device in peerDevices[peer.id] ?? [] where device.hasOutput && device.isAvailable && !device.busy {
                let key = HubStore.remoteComponentID(peer: peer.id, component: device.id)
                if peerRooms[peer.id]?.contains(roomID) == true || componentRooms[key]?.contains(roomID) == true {
                    result.insert(RoomAudioDestination(peerID: peer.id, outputID: device.id))
                }
            }
        }
        return result
    }
}

/// One locally enabled emitter fans out PCM to independent encrypted connections.
/// Received audio is played locally and is never fed back into an emitter.
public final class RoomAudio: ObservableObject {
    @Published public private(set) var active = false
    @Published public private(set) var status = ""
    @Published public private(set) var sourceID: String?
    @Published public private(set) var sharingApplications = false
    @Published public private(set) var receivingStatus = "Connecting to room audio…"
    private var connected = Set<RoomAudioDestination>()
    private var lastSourceAudio = Date.distantPast
    private var lastSentAudio = Date.distantPast
    private var lastSourceSignal = Date.distantPast
    private(set) var roomID: String?
    private weak var store: HubStore?
    private let capture = MeshAudioIO()
    private let delivery = PCMDelivery()
    private var senders: [RoomAudioDestination: AudioMesh] = [:]
    private var localOutputs: [RoomAudioDestination: MeshAudioIO] = [:]
    private var receivers: [String: (mesh: AudioMesh, offer: AudioOffer)] = [:]
    private var seen: [String: Date] = [:]
    private var generation = UUID()
    private var microphone = false
    private var awaitingMicrophonePermission = false
    private var beginMicrophone: (() -> Void)?
    private var retryAfter: [RoomAudioDestination: Date] = [:]
    private var retryWork: [RoomAudioDestination: DispatchWorkItem] = [:]

    deinit { retryWork.values.forEach { $0.cancel() } }

    private func scheduleRetry(_ destination: RoomAudioDestination) {
        retryWork.removeValue(forKey: destination)?.cancel()
        retryAfter[destination] = Date().addingTimeInterval(2)
        let attempt = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.generation == attempt else { return }
            self.retryWork.removeValue(forKey: destination)
            self.retryAfter.removeValue(forKey: destination)
            // Revalidate room membership, pairing, and discovery. Reconcile
            // creates a new AudioMesh and a fresh signed/keyed handshake.
            self.reconcile()
        }
        retryWork[destination] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func attach(_ store: HubStore) { self.store = store }
    /// Restart this device's streams to one peer on purpose (a different route was chosen). Not treated as a failure.
    func reconnect(peerID: String) {
        for (destination, mesh) in senders where destination.peerID == peerID {
            senders.removeValue(forKey: destination); connected.remove(destination); retryAfter.removeValue(forKey: destination)
            mesh.stop()
        }
        reconcile()
    }

    /// Ends every stream this device is playing from other devices.
    func stopReceiving() {
        for receiver in receivers.values { receiver.mesh.stop() }
        receivers.removeAll(); objectWillChange.send()
    }
    func startApplications(room: AudioRoom, sourceID: String) {
        stop()
        guard let store else { return }
        guard store.audioDirection.sends else { store.notice = "This device is set to receive only. Change it in Settings to send sound."; return }
        roomID = room.id; self.sourceID = sourceID; sharingApplications = true; active = true
        status = "Waiting for room outputs…"
        prepareDelivery()
        reconcile()
        if active && sharingApplications { store.onApplicationAudioStart?() }
    }

    public func appendApplicationPCM(_ pcm: Data) { delivery.submit(pcm) }

    private func prepareDelivery() {
        delivery.updates.start { [weak self] _, pcm in
            guard let self, self.active, let pcm else { return }
            self.lastSourceAudio = Date()
            if pcm.withUnsafeBytes({ bytes in
                stride(from: 0, to: bytes.count - 1, by: 2).contains {
                    abs(Int(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: Int16.self)))) > 16
                }
            }) { self.lastSourceSignal = self.lastSourceAudio }
            if let sourceID = self.sourceID {
                self.store?.activity.showStreamLevel(sourceID, pcm: pcm, recording: self.microphone)
            }
            // Every output this stream is feeding shows the level, not only the source row.
            for destination in self.localOutputs.keys where destination.outputID != self.sourceID {
                self.store?.activity.showStreamLevel(destination.outputID, pcm: pcm, recording: false)
            }
            for destination in self.connected {
                guard let peerID = destination.peerID else { continue }
                self.store?.activity.showStreamLevel(HubStore.remoteComponentID(peer: peerID, component: destination.outputID), pcm: pcm, recording: false)
            }
        }
    }
    func refreshDelivery() {
        for receiver in receivers.values { receiver.mesh.refreshAudioGains() }
        guard active, let store, let roomID,
              let room = store.rooms.first(where: { $0.id == roomID }) else { return }
        var routes: [PCMDelivery.Route] = []
        for (destination, sender) in senders {
            guard let sink = sender.pcmSink() else { continue }
            let id = destination.peerID.map { HubStore.remoteComponentID(peer: $0, component: destination.outputID) } ?? destination.outputID
            routes.append(.init(gain: store.audioGain(for: id), send: sink))
        }
        for (destination, output) in localOutputs {
            if let sink = output.playbackSink() { routes.append(.init(gain: store.audioGain(for: destination.outputID), send: sink)) }
        }
        let sourceGain = microphone ? store.audioGain(for: sourceID ?? "", input: true) : 1
        delivery.configure(routes: routes, gain: room.level * sourceGain)
    }

    func start(room: AudioRoom, sourceID: String, input: LocalAudioDevice? = nil) {
        stop()
        guard let store, store.identity != nil else { return }
        guard store.audioDirection.sends else { store.notice = "This device is set to receive only. Change it in Settings to send sound."; return }
        roomID = room.id; self.sourceID = sourceID; microphone = input != nil
        awaitingMicrophonePermission = input != nil
        active = true; status = input == nil ? "Broadcasting test sound to \(room.name)…" : "Requesting microphone access…"
        prepareDelivery()
        let token = generation
        if let input {
            MeshAudioIO.microphonePermission { [weak self] allowed in
                guard let self, self.generation == token, self.active else { return }
                guard allowed else { self.stop(reason: "Allow microphone access to share with this room."); return }
                self.awaitingMicrophonePermission = false
                self.beginMicrophone = { [weak self] in
                    guard let self, self.generation == token else { return }
                    do {
                        try self.capture.startCapture(inputSystemID: input.systemInputID,
                            inputUID: input.id.hasPrefix("input:") ? String(input.id.dropFirst(6)) : input.id) { [weak self] pcm in
                            self?.delivery.submit(pcm)
                        }
                        self.status = "Sharing \(input.name) with \(room.name)"
                    } catch { self.stop(reason: error.localizedDescription) }
                }
                self.reconcile()
                guard !self.senders.isEmpty else { self.stop(reason: "No paired outputs are online in this room."); return }
                self.status = "Waiting for a room receiver…"
            }
        } else {
            reconcile()
            guard !senders.isEmpty || !localOutputs.isEmpty else { stop(reason: "No available outputs in this room."); return }
            capture.startTestTone { [weak self] pcm in
                self?.delivery.submit(pcm)
            }
        }
    }

    func updateEmissionStatus(now: Date = Date()) {
        guard active, !awaitingMicrophonePermission else { return }
        let outputCount = connected.count + localOutputs.count
        let message: String
        if outputCount == 0 {
            message = senders.isEmpty ? "Waiting for an online output in this room. Open Soundbound on the receiving device."
                : "Connecting to \(senders.count) room output(s)…"
        } else if now.timeIntervalSince(lastSourceAudio) > 2 {
            message = "Connected to \(outputCount) output(s) · waiting for source audio"
        } else if now.timeIntervalSince(lastSourceSignal) > 2 {
            message = "Connected to \(outputCount) output(s) · source audio is silent"
        } else if !connected.isEmpty && now.timeIntervalSince(lastSentAudio) > 2 {
            message = "Source audio captured · waiting for network transmission"
        } else {
            message = "Sending audio to \(outputCount) room output(s)"
        }
        if status != message { status = message }
    }

    func reconcile() {
        guard let store else { return }
        for (id, receiver) in Array(receivers) where !store.acceptsRoomAudio(receiver.offer) {
            receivers.removeValue(forKey: id); receiver.mesh.stop()
        }
        guard active, let roomID, let sourceID, let identity = store.identity else { return }
        guard store.activeRoomID == roomID, store.rooms.contains(where: { $0.id == roomID }),
              store.deviceRooms.contains(roomID) || store.audioMemberships[sourceID]?.contains(roomID) == true else {
            stop(reason: "Room emission stopped."); return
        }
        guard !awaitingMicrophonePermission else { return }
        var desired = store.roomAudioDestinations(roomID)
        // A microphone is not monitored through this host's speakers (feedback).
        if microphone { desired = desired.filter { $0.peerID != nil } }
        // Application audio already plays on the Mac's selected output.
        if sharingApplications {
            desired = desired.filter { destination in
                destination.peerID != nil || !store.reportedAudioDevices.contains(where: { $0.id == destination.outputID && $0.selectedOutput })
            }
        }
        #if os(iOS)
        desired = desired.filter { destination in
            destination.peerID != nil || store.reportedAudioDevices.contains(where: { $0.id == destination.outputID && $0.selectedOutput })
        }
        #endif
        for destination in Set(senders.keys).subtracting(desired) {
            connected.remove(destination)
            let sender = senders.removeValue(forKey: destination); sender?.stop()
        }
        for destination in Set(localOutputs.keys).subtracting(desired) {
            localOutputs.removeValue(forKey: destination)?.stop()
            store.activity.clear(destination.outputID)
        }
        for destination in desired {
            if let peerID = destination.peerID {
                guard senders[destination] == nil, (retryAfter[destination] ?? .distantPast) <= Date(),
                      let peer = store.nearby.first(where: { $0.id == peerID }) else { continue }
                let mesh = AudioMesh(); senders[destination] = mesh
                mesh.onRouteDetails = { [weak store] peer, session, details in store?.ping.recordRouteDetails(peerID: peer, sessionID: session, details: details) }
        mesh.onTransportChanged = { [weak store] peer, session, path in store?.ping.recordMediaPath(peerID: peer, sessionID: session, path: path) }
                mesh.onRoundTrip = { [weak store] peer, session, ms in store?.ping.recordRoundTrip(peerID: peer, sessionID: session, milliseconds: ms) }
                mesh.request = { [weak store] envelope, endpoint, completion in store?.network.request(envelope, endpoint: endpoint, completion: completion) }
                mesh.onReady = { [weak self, weak store] in
                    self?.connected.insert(destination)
                    self?.refreshDelivery()
                    self?.updateEmissionStatus()
                    store?.activity.chirp(HubStore.remoteComponentID(peer: peerID, component: destination.outputID))
                    let begin = self?.beginMicrophone; self?.beginMicrophone = nil; begin?()
                }
                mesh.onAudioSent = { [weak self] in self?.lastSentAudio = Date(); self?.updateEmissionStatus() }
                mesh.onFinished = { [weak self, weak mesh] in
                    guard let self, let mesh, self.senders[destination] === mesh else { return }
                    self.senders.removeValue(forKey: destination)
                    self.connected.remove(destination)
                    self.refreshDelivery()
                    // The route this stream used may be the thing that died; stop insisting on it before retrying.
                    self.store?.ping.routeLost(for: peerID)
                    self.store?.network.clearPreference(for: peerID)
                    self.scheduleRetry(destination)
                    self.store?.activity.clear(HubStore.remoteComponentID(peer: peerID, component: destination.outputID))
                    self.status = "An output disconnected: \(mesh.status)"
                    if self.microphone && self.senders.isEmpty { self.stop(reason: "Microphone stopped: no room receivers remain.") }
                }
                mesh.sendPCM(to: peer, identity: identity, card: store.card, outputID: destination.outputID, roomID: roomID, sourceID: sourceID)
            } else if localOutputs[destination] == nil,
                      let device = store.reportedAudioDevices.first(where: { $0.id == destination.outputID }) {
                do {
                    let io = MeshAudioIO()
                    try io.startPlayback(outputSystemID: device.systemOutputID, expectedOutputID: device.id)
                    localOutputs[destination] = io; store.activity.chirp(device.id)
                } catch { status = "Could not play on \(device.name): \(error.localizedDescription)" }
            }
        }
        if microphone && senders.isEmpty { stop(reason: "Microphone stopped: no room receivers remain.") }
        refreshDelivery()
        updateEmissionStatus()
    }

    func receive(_ envelope: SignedEnvelope, respond: @escaping (SignedEnvelope) -> Void) -> Bool {
        guard let offer = try? envelope.verified(as: AudioOffer.self), offer.kind == "audio-offer", offer.roomID != nil else { return false }
        guard let store, let identity = store.identity else { return true }
        seen = seen.filter { $0.value > Date().addingTimeInterval(-120) }
        guard offer.version == 4, store.audioDirection.receives, store.acceptsRoomAudio(offer), offer.from.publicKey == envelope.signer,
              abs(offer.created.timeIntervalSinceNow) < 30, UUID(uuidString: offer.id) != nil,
              seen[offer.id] == nil, seen.count < 1000, receivers.count < 16 else {
            if let reply = try? identity.sign(AudioReply(id: offer.id, from: store.card, to: offer.from.id, accepted: false, reason: .declined, created: Date())) { respond(reply) }
            return true
        }
        seen[offer.id] = Date()
        let mesh = AudioMesh()
        mesh.onRouteDetails = { [weak store] peer, session, details in store?.ping.recordRouteDetails(peerID: peer, sessionID: session, details: details) }
        mesh.onTransportChanged = { [weak store] peer, session, path in store?.ping.recordMediaPath(peerID: peer, sessionID: session, path: path) }
        mesh.onRoundTrip = { [weak store] peer, session, ms in store?.ping.recordRoundTrip(peerID: peer, sessionID: session, milliseconds: ms) }
        mesh.outputGain = { [weak store] in store?.playbackGain(for: $0) ?? 1 }
        receivers[offer.id] = (mesh, offer)
        mesh.onTestReceived = { [weak store] id in if let id { store?.activity.chirp(id) } }
        mesh.onLevel = { [weak self, weak store] id, pcm, _ in
            store?.activity.showStreamLevel(id, pcm: pcm, recording: false)
            if let self { self.receivingStatus = "Receiving room audio from \(offer.from.name)" }
        }
        mesh.onFinished = { [weak self] in
            guard let self else { return }
            self.receivers.removeValue(forKey: offer.id)
            self.store?.network.clearPreference(for: offer.from.id)
            if let id = offer.outputID, !self.receivers.values.contains(where: { $0.offer.outputID == id }) { self.store?.activity.clear(id) }
            self.objectWillChange.send()
        }
        // Connect back along the link the offer arrived on. That is the route the sender chose (or the one that
        // still works after another dropped), which is not always the one this device would have picked.
        var peers = store.nearby
        if let host = store.network.arrivalHost(signer: envelope.signer), let index = peers.firstIndex(where: { $0.id == offer.from.id }) {
            peers[index].endpoint.host = host
        }
        _ = mesh.receive(envelope, nearby: peers, friends: store.friends, identity: identity,
            card: store.card, devices: store.reportedAudioDevices, autoApprove: true, allowRoomAudio: true, respond: respond)
        if !mesh.active { receivers.removeValue(forKey: offer.id) }
        if !receivers.isEmpty && receivers.values.allSatisfy({ $0.mesh.packets == 0 }) { receivingStatus = "Connecting to room audio…" }
        objectWillChange.send()
        return true
    }

    public var receiving: Bool { !receivers.isEmpty }
    func pipelineIncomingSource(outputID: String? = nil) -> PeerCard? {
        receivers.values.first(where: { outputID == nil || $0.offer.outputID == outputID })?.offer.from
    }
    func pipelineState(peerID: String?, outputID: String) -> (label: String, connected: Bool) {
        let destination = RoomAudioDestination(peerID: peerID, outputID: outputID)
        if connected.contains(destination) { return (senders[destination]?.status ?? "Connected", true) }
        if let sender = senders[destination] { return (sender.status, false) }
        if localOutputs[destination] != nil { return ("Local renderer active", true) }
        if peerID == nil, let receiver = receivers.values.first(where: { $0.offer.outputID == outputID }) {
            return (receiver.mesh.status, receiver.mesh.packets > 0)
        }
        if peerID == nil, sharingApplications,
           store?.reportedAudioDevices.contains(where: { $0.id == outputID && $0.selectedOutput }) == true {
            return ("macOS system output", true)
        }
        return ("No connected stream", false)
    }
    func playbackRoomID(for component: String) -> String? {
        if active, component == sourceID || localOutputs.keys.contains(where: { $0.outputID == component }) { return roomID }
        return receivers.values.first(where: { $0.offer.outputID == component })?.offer.roomID
    }
    public func stop(reason: String = "Room audio stopped") {
        delivery.stop()
        generation = UUID(); beginMicrophone = nil; capture.stop()
        let outgoingDestinations = senders.keys.compactMap { destination in
            destination.peerID.map { HubStore.remoteComponentID(peer: $0, component: destination.outputID) }
        }
        let outgoing = Array(senders.values), incoming = receivers.values.map(\.mesh), outputs = Array(localOutputs.values)
        let outputIDs = Array(localOutputs.keys).map(\.outputID)
        senders.removeAll(); receivers.removeAll(); localOutputs.removeAll()
        connected.removeAll(); lastSourceAudio = .distantPast; lastSourceSignal = .distantPast; lastSentAudio = .distantPast
        outgoing.forEach { $0.stop() }; incoming.forEach { $0.stop() }; outputs.forEach { $0.stop() }
        if let sourceID { store?.activity.clear(sourceID) }
        outputIDs.forEach { store?.activity.clear($0) }
        for destination in outgoingDestinations { store?.activity.clear(destination) }
        self.sourceID = nil; roomID = nil; active = false; status = reason; microphone = false; awaitingMicrophonePermission = false
        retryAfter.removeAll()
        retryWork.values.forEach { $0.cancel() }; retryWork.removeAll()
        if sharingApplications { sharingApplications = false; store?.onApplicationAudioStop?() }
    }
}

extension HubStore {
    public var canShareApplicationAudio: Bool { onApplicationAudioStart != nil }
    /// There is no separate Share switch: a Mac that has joined a room and is set to send (or to both) sends its
    /// sound to that room. Called on joining, on changing the setting, and at launch.
    public func startSharingIfAllowed() {
        guard canShareApplicationAudio, audioDirection.sends, let room = activeRoom,
              !roomAudio.active, !roomAudio.receiving, applicationSourceID(in: room.id) != nil else { return }
        shareApplicationAudioWithRoom()
    }
    public func shareApplicationAudioWithRoom() {
        if roomAudio.sharingApplications { roomAudio.stop(); return }
        guard canShareApplicationAudio, let room = activeRoom,
              let sourceID = applicationSourceID(in: room.id) else {
            notice = "Add this Mac or one of its outputs to a room and activate it before sharing application audio."; return
        }
        mesh.stop(); activity.stopRecording(); activity.stopPlayback()
        roomAudio.startApplications(room: room, sourceID: sourceID)
    }
    func applicationSourceID(in roomID: String) -> String? {
        if deviceRooms.contains(roomID) { return deviceID }
        return reportedAudioDevices.first(where: {
            $0.hasOutput && $0.isAvailable && audioMemberships[$0.id]?.contains(roomID) == true
        })?.id
    }
    public func applicationAudioFailed(_ message: String) { roomAudio.stop(reason: message); notice = message }
    func roomAudioDestinations(_ roomID: String) -> Set<RoomAudioDestination> {
        RoomAudioRoutes.outputs(roomID: roomID, hostID: deviceID, devices: reportedAudioDevices,
            hostRooms: deviceRooms, peerRooms: peerMemberships, componentRooms: audioMemberships,
            peers: friends, online: Set(nearby.map(\.id)), peerDevices: peerAudioDevices)
    }
    func acceptsRoomAudio(_ offer: AudioOffer) -> Bool {
        guard offer.to == deviceID, let roomID = offer.roomID, let sourceID = offer.sourceID, let outputID = offer.outputID,
              activeRoomID == roomID, rooms.contains(where: { $0.id == roomID }),
              friends.contains(where: { $0.id == offer.from.id && $0.card.publicKey == offer.from.publicKey }),
              reportedAudioDevices.contains(where: { $0.id == outputID && $0.hasOutput && $0.isAvailable }),
              deviceRooms.contains(roomID) || audioMemberships[outputID]?.contains(roomID) == true,
              peerMemberships[offer.from.id]?.contains(roomID) == true ||
                audioMemberships[Self.remoteComponentID(peer: offer.from.id, component: sourceID)]?.contains(roomID) == true else { return false }
        return true
    }
    public func emitRoomTest(_ room: AudioRoom) {
        if roomAudio.active && roomAudio.roomID == room.id { roomAudio.stop(); return }
        guard deviceRooms.contains(room.id) || reportedAudioDevices.contains(where: { audioMemberships[$0.id]?.contains(room.id) == true }) else {
            notice = "Add this device or an audio component to the room first."; return
        }
        setActiveRoom(room.id); mesh.stop(); activity.stopRecording(); activity.stopPlayback()
        let source = deviceRooms.contains(room.id) ? deviceID : reportedAudioDevices.first(where: { audioMemberships[$0.id]?.contains(room.id) == true })!.id
        roomAudio.start(room: room, sourceID: source)
    }
    public func shareMicrophoneWithRoom(_ input: LocalAudioDevice) {
        guard let room = activeRoom, input.hasInput, input.isAvailable, audioDevice(input.id, belongsTo: room.id) else {
            notice = "Activate a room containing this microphone first."; return
        }
        mesh.stop(); activity.stopRecording(); activity.stopPlayback()
        roomAudio.start(room: room, sourceID: input.id, input: input)
    }
    func handleRoomAudioAction(_ action: LocalAudioAction, id: String) -> Bool {
        if case .stopTest = action, roomAudio.active { roomAudio.stop(); return true }
        guard case .testOutput = action, let room = activeRoom, audioDevice(id, belongsTo: room.id) else { return false }
        emitRoomTest(room); return true
    }
}
