import Foundation
import Combine
import CryptoKit
import Network
import AVFAudio

/// One consented, one-way microphone stream. Local TCP is the first transport;
/// relay selection and multi-recipient mixing remain separate work.
public final class AudioMesh: ObservableObject {
    @Published public private(set) var status = "No audio shared"
    @Published public private(set) var active = false
    @Published public private(set) var incoming: IncomingAudioRequest?
    @Published public private(set) var packets = 0
    var onRecordingFrame: ((Data) -> Void)?
    var onLevel: ((String, Data, Bool) -> Void)?
    var onFinished: (() -> Void)?
    private var selectedInput: LocalAudioDevice?
    var onTestStarted: (() -> Void)?
    var onTestReceived: ((String?) -> Void)?
    var onReady: (() -> Void)?
    var onAudioSent: (() -> Void)?
    var onRouteDetails: ((String, String, ConnectionRouteDetails?) -> Void)?
    var onTransportChanged: ((String, String, LocalConnectionPath?) -> Void)?
    var onRoundTrip: ((String, String, Double) -> Void)?
    private var transportPeerID: String?
    private var transportSessionID: String?
    var inputGain: ((LocalAudioDevice?) -> Double)?
    var outputGain: ((String?) -> Double)?
    var transmissionGain: (() -> Double)?
    private var externalPCM = false
    var sign: ((AudioOffer) throws -> SignedEnvelope)?
    var request: ((SignedEnvelope, LocalEndpoint, @escaping (Result<SignedEnvelope, Error>) -> Void) -> Void)?
    private var listener: NWListener?
    private var channel: AudioMeshChannel?
    private var candidates: [AudioMeshChannel] = []
    private var pendingConnections: [NWConnection] = []
    private var key: Curve25519.KeyAgreement.PrivateKey?
    private var keys: (SymmetricKey, SymmetricKey)?
    private var offer: AudioOffer?
    private let io = MeshAudioIO()
    private let sendDelivery = PCMDelivery()
    private let receiveDelivery = PCMDelivery()
    private let sentUpdates = AudioUIUpdates()
    private var generation = UUID()
    private var incomingOutputSystemID: UInt32?
    private var activeOutputID: String?
    private var incomingOffer: AudioOffer?
    private var incomingHost: String?
    private var incomingRespond: ((SignedEnvelope) -> Void)?
    private var incomingIdentity: Identity?
    private var incomingCard: PeerCard?
    private var repeatTestTone = true
    private var seen: [String: Date] = [:]
    private var interruption: NSObjectProtocol?

    public init() {
        #if os(iOS)
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] _ in self?.stop(reason: "Audio interrupted") }
        #endif
    }
    deinit { if let interruption { NotificationCenter.default.removeObserver(interruption) } }

    func shareMicrophone(to peer: NearbyPeer, identity: Identity, card: PeerCard, input: LocalAudioDevice? = nil, recordingID: String? = nil) {
        guard !active else { return }
        active = true; selectedInput = input; status = "Requesting microphone access…"; packets = 0
        let attempt = UUID(); generation = attempt
        MeshAudioIO.microphonePermission { [weak self] allowed in
            guard let self, self.generation == attempt else { return }
            guard allowed else { self.stop(reason: AudioMeshError.microphone.localizedDescription); return }
            self.beginOffer(peer: peer, identity: identity, card: card, attempt: attempt, recordingID: recordingID)
        }
    }
    func sendTestTone(to peer: NearbyPeer, identity: Identity, card: PeerCard, outputID: String? = nil, repeating: Bool = true) {
        guard !active else { return }
        repeatTestTone = repeating
        active = true; packets = 0
        let attempt = UUID(); generation = attempt
        beginOffer(peer: peer, identity: identity, card: card, attempt: attempt, testTone: true, outputID: outputID)
    }
    func sendPCM(to peer: NearbyPeer, identity: Identity, card: PeerCard, outputID: String?, roomID: String, sourceID: String) {
        guard !active else { return }
        externalPCM = true; active = true; packets = 0
        let attempt = UUID(); generation = attempt
        beginOffer(peer: peer, identity: identity, card: card, attempt: attempt, outputID: outputID, roomID: roomID, sourceID: sourceID)
    }
    func appendPCM(_ pcm: Data) { channel?.sendAudio(pcm) }
    func pcmSink() -> ((Data) -> Void)? {
        guard let channel else { return nil }
        return { [weak channel] pcm in channel?.sendAudio(pcm) }
    }
    func refreshAudioGains() {
        let gain = offer?.source == "test-tone" ? 1 : (inputGain?(selectedInput) ?? 1)
        sendDelivery.setGain(gain * (transmissionGain?() ?? 1))
        receiveDelivery.setGain(outputGain?(activeOutputID) ?? 1)
    }
    private func beginOffer(peer: NearbyPeer, identity: Identity, card: PeerCard, attempt: UUID, testTone: Bool = false, outputID: String? = nil, recordingID: String? = nil, roomID: String? = nil, sourceID: String? = nil) {
        do {
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            key = ephemeral
            let parameters = AudioBufferPolicy.tcpParameters()
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.generation == attempt, self.active, self.channel == nil, self.pendingConnections.count + self.candidates.count < 4 else { connection.cancel(); return }
                if self.keys != nil { self.makeCandidate(connection) }
                else {
                    self.pendingConnections.append(connection)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak connection] in
                        guard let self, let connection, self.generation == attempt,
                              self.pendingConnections.contains(where: { $0 === connection }) else { return }
                        self.pendingConnections.removeAll { $0 === connection }; connection.cancel()
                    }
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, self.generation == attempt else { return }
                if case .ready = state, let port = listener?.port, self.offer == nil {
                    var offer = AudioOffer(id: UUID().uuidString, from: card, to: peer.id,
                        ephemeralKey: ephemeral.publicKey.rawRepresentation.url64, port: port.rawValue, created: Date(), source: testTone ? "test-tone" : (recordingID == nil ? "microphone" : "microphone-recording"), outputID: outputID, recordingID: recordingID)
                    // Version 2 prevents older receivers from ignoring a specific output target.
                    if outputID != nil { offer.version = 2 }; if recordingID != nil { offer.version = 3 }
                    if let roomID { offer.version = 4; offer.source = "room-audio"; offer.roomID = roomID; offer.sourceID = sourceID }
                    self.offer = offer; self.status = "Waiting for \(peer.invitation.peer.name) to allow audio…"
                    self.transportPeerID = peer.id; self.transportSessionID = offer.id
                    do {
                        let signed = try identity.sign(offer)
                        self.request?(signed, peer.endpoint) { [weak self] result in
                            guard let self, self.generation == attempt else { return }
                            do {
                                let envelope = try result.get()
                                let reply = try envelope.verified(as: AudioReply.self)
                                guard reply.kind == "audio-reply", reply.version == 1, reply.id == offer.id,
                                      reply.to == card.id, reply.from.id == peer.id,
                                      envelope.signer == peer.invitation.peer.publicKey,
                                      reply.from.publicKey == envelope.signer,
                                      abs(reply.created.timeIntervalSinceNow) < 60 else { throw AudioMeshError.invalid }
                                guard reply.accepted, let remoteKey = reply.ephemeralKey else { throw reply.reason ?? AudioRejection.declined }
                                self.keys = try AudioSessionCipher.keys(privateKey: ephemeral, remote: remoteKey,
                                    session: offer.id, source: card.id, sink: peer.id)
                                self.status = "Securing audio connection…"
                                let waiting = self.pendingConnections; self.pendingConnections = []
                                waiting.forEach { self.makeCandidate($0) }
                            } catch { self.stop(reason: error.localizedDescription) }
                        }
                    } catch { self.stop(reason: error.localizedDescription) }
                } else if case .failed(let error) = state { self.stop(reason: error.localizedDescription) }
            }
            listener.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in
                guard let self, self.generation == attempt, self.channel == nil else { return }
                self.stop(reason: AudioMeshError.expired.localizedDescription)
            }
        } catch { stop(reason: error.localizedDescription) }
    }
    private func makeCandidate(_ connection: NWConnection) {
        guard let keys, let offer else { connection.cancel(); return }
        let candidate = AudioMeshChannel(connection: connection, sendKey: keys.0, receiveKey: keys.1, session: offer.id, source: true)
        candidates.append(candidate)
        let attempt = generation
        candidate.pathChanged = { [weak self, weak candidate] path in DispatchQueue.main.async {
            guard let self, let candidate, self.generation == attempt, self.channel === candidate else { return }
            self.onTransportChanged?(offer.to, offer.id, path)
            self.onRouteDetails?(offer.to, offer.id, ConnectionRouteDetails(candidate.connection))
        } }
        candidate.roundTrip = { [weak self, weak candidate] milliseconds in DispatchQueue.main.async {
            guard let self, let candidate, self.generation == attempt, self.channel === candidate else { return }
            self.onRoundTrip?(offer.to, offer.id, milliseconds)
        } }
        sentUpdates.start { [weak self] count, _ in
            guard let self, self.generation == attempt else { return }
            self.packets += count; self.onAudioSent?()
        }
        candidate.sentAudio = { [updates = sentUpdates] in updates.record() }
        candidate.ready = { [weak self, weak candidate] in
            DispatchQueue.main.async {
                guard let self, let candidate, self.generation == attempt, self.channel == nil else { return }
                self.channel = candidate
                self.onTransportChanged?(offer.to, offer.id, candidate.localPath)
                self.onRouteDetails?(offer.to, offer.id, ConnectionRouteDetails(candidate.connection))
                self.listener?.cancel(); self.listener = nil
                self.candidates.filter { $0 !== candidate }.forEach { $0.stop() }; self.candidates = []
                if self.externalPCM {
                    self.status = "Sharing room audio · encrypted · local network"
                    self.onReady?()
                    return
                }
                do {
                    self.sendDelivery.configure(routes: [.init(send: { [weak candidate] in candidate?.sendAudio($0) })])
                    self.refreshAudioGains()
                    self.sendDelivery.updates.start { [weak self] _, pcm in
                        guard let self, self.generation == attempt, let pcm, let input = self.selectedInput else { return }
                        self.onLevel?(input.id, pcm, true)
                    }
                    let send: (Data) -> Void = { [delivery = self.sendDelivery] in delivery.submit($0) }
                    if offer.source == "test-tone" {
                        self.io.startTestTone(repeating: self.repeatTestTone, frame: send)
                        self.onTestStarted?()
                        self.status = "Sending quiet test tone…"
                        if !self.repeatTestTone { DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                            guard let self, self.generation == attempt else { return }
                            self.stop(reason: "Test tone finished")
                        } }
                    } else {
                        try self.io.startCapture(inputSystemID: self.selectedInput?.systemInputID, inputUID: self.selectedInput.map { $0.id.hasPrefix("input:") ? String($0.id.dropFirst(6)) : $0.id }, frame: send)
                        if offer.recordingID != nil {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                                if self?.generation == attempt { self?.stop(reason: "Recording finished") }
                            }
                        }
                        self.status = "Sharing microphone · encrypted · local network"
                    }
                } catch { self.stop(reason: error.localizedDescription) }
            }
        }
        candidate.ended = { [weak self, weak candidate] error in
            DispatchQueue.main.async {
                guard let self, self.generation == attempt else { return }
                if let candidate { self.candidates.removeAll { $0 === candidate } }
                if let candidate, self.channel === candidate { self.stop(reason: error?.localizedDescription ?? "Audio stopped") }
            }
        }
        candidate.start()
    }

    func receive(_ signed: SignedEnvelope, nearby: [NearbyPeer], friends: [KnownPeer], identity: Identity, card: PeerCard,
                 devices: [LocalAudioDevice] = [], autoApprove: Bool = false, expectedRecordingID: String? = nil, expectedRecordingPeer: String? = nil, allowRoomAudio: Bool = false, respond: @escaping (SignedEnvelope) -> Void) -> Bool {
        guard let offer = try? signed.verified(as: AudioOffer.self), offer.kind == "audio-offer" else { return false }
        guard offer.roomID == nil || allowRoomAudio else { return true }
        seen = seen.filter { $0.value > Date().addingTimeInterval(-120) }
        guard [1, 2, 3, 4].contains(offer.version), (offer.outputID == nil || [2, 4].contains(offer.version)), offer.from.publicKey == signed.signer, offer.to == card.id,
              offer.port > 0, ["microphone", "test-tone", "microphone-recording", "room-audio"].contains(offer.source), UUID(uuidString: offer.id) != nil,
              abs(offer.created.timeIntervalSinceNow) < 30, seen[offer.id] == nil, seen.count < 1000,
              Data(url64: offer.ephemeralKey)?.count == 32,
              friends.contains(where: { $0.id == offer.from.id && $0.card.publicKey == signed.signer }),
              let peer = nearby.first(where: { $0.id == offer.from.id }) else { return true }
        guard (offer.version == 4 && offer.source == "room-audio" && offer.roomID != nil && offer.sourceID != nil && offer.recordingID == nil)
            || (offer.version != 4 && offer.source != "room-audio" && offer.roomID == nil && offer.sourceID == nil) else { return true }
        if offer.source == "microphone-recording" {
            guard offer.version == 3, let id = offer.recordingID, id == expectedRecordingID, offer.from.id == expectedRecordingPeer else { return true }
        } else if offer.recordingID != nil { return true }
        seen[offer.id] = Date()
        guard !active, incoming == nil else {
            let reply = AudioReply(id: offer.id, from: card, to: offer.from.id, accepted: false, reason: .busy, created: Date())
            if let signed = try? identity.sign(reply) { respond(signed) }; return true
        }
        if let outputID = offer.outputID {
            guard let device = devices.first(where: { $0.id == outputID && $0.hasOutput && $0.isAvailable }) else {
                if let reply = try? identity.sign(AudioReply(id: offer.id, from: card, to: offer.from.id, accepted: false, reason: .outputUnavailable, created: Date())) { respond(reply) }
                return true
            }
            #if os(iOS)
            guard device.selectedOutput else {
                if let reply = try? identity.sign(AudioReply(id: offer.id, from: card, to: offer.from.id, accepted: false, reason: .outputUnavailable, created: Date())) { respond(reply) }
                return true
            }
            #endif
            incomingOutputSystemID = device.systemOutputID
        } else { incomingOutputSystemID = nil }
        incomingOffer = offer; incomingHost = peer.endpoint.host
        incomingRespond = respond; incomingIdentity = identity; incomingCard = card
        if autoApprove || offer.recordingID != nil {
            decide(allow: true)
            return true
        }
        incoming = IncomingAudioRequest(id: offer.id, name: offer.from.name, outputName: devices.first(where: { $0.id == offer.outputID })?.name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard self?.incoming?.id == offer.id else { return }; self?.decide(allow: false)
        }
        return true
    }
    public func decide(allow: Bool) {
        guard let offer = incomingOffer, let host = incomingHost, let respond = incomingRespond,
              let identity = incomingIdentity, let card = incomingCard else { return }
        incoming = nil; incomingOffer = nil; incomingRespond = nil
        incomingIdentity = nil; incomingCard = nil; incomingHost = nil
        do {
            guard allow, !active, abs(offer.created.timeIntervalSinceNow) < 60 else {
                respond(try identity.sign(AudioReply(id: offer.id, from: card, to: offer.from.id, accepted: false, reason: allow ? .expired : .declined, created: Date())))
                return
            }
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let keys = try AudioSessionCipher.keys(privateKey: ephemeral, remote: offer.ephemeralKey,
                session: offer.id, source: offer.from.id, sink: card.id)
            if offer.recordingID == nil { try io.startPlayback(outputSystemID: incomingOutputSystemID, expectedOutputID: offer.outputID) }
            active = true; packets = 0; status = "Securing audio connection…"
            activeOutputID = offer.outputID
            let attempt = UUID(); generation = attempt
            let reply = AudioReply(id: offer.id, from: card, to: offer.from.id, accepted: true,
                ephemeralKey: ephemeral.publicKey.rawRepresentation.url64, created: Date())
            respond(try identity.sign(reply))
            let parameters = AudioBufferPolicy.tcpParameters()
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: offer.port)!, using: parameters)
            let channel = AudioMeshChannel(connection: connection, sendKey: keys.1, receiveKey: keys.0, session: offer.id, source: false)
            self.channel = channel
            self.transportPeerID = offer.from.id; self.transportSessionID = offer.id
            channel.pathChanged = { [weak self] path in DispatchQueue.main.async {
                guard let self, self.generation == attempt else { return }
                self.onTransportChanged?(offer.from.id, offer.id, path)
                if let connection = self.channel?.connection { self.onRouteDetails?(offer.from.id, offer.id, ConnectionRouteDetails(connection)) }
            } }
            channel.roundTrip = { [weak self] milliseconds in DispatchQueue.main.async {
                guard let self, self.generation == attempt else { return }
                self.onRoundTrip?(offer.from.id, offer.id, milliseconds)
            } }
            channel.ready = { [weak self] in DispatchQueue.main.async {
                guard let self, self.generation == attempt else { return }
                self.status = "Listening to \(offer.from.name) · encrypted · local network"
            } }
            if offer.recordingID == nil, let sink = io.playbackSink() {
                receiveDelivery.configure(routes: [.init(send: sink)], gain: outputGain?(offer.outputID) ?? 1)
                receiveDelivery.updates.start { [weak self] count, pcm in
                    guard let self, self.generation == attempt, let pcm else { return }
                    if self.packets == 0 && offer.source == "test-tone" { self.onTestReceived?(offer.outputID) }
                    if let id = offer.outputID { self.onLevel?(id, pcm, false) }
                    self.packets += count
                }
                channel.audio = { [delivery = receiveDelivery] in delivery.submit($0) }
            } else {
                channel.audio = { [weak self] pcm in DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == attempt else { return }
                    self.onRecordingFrame?(pcm); self.packets += 1
                } }
            }
            channel.ended = { [weak self] error in DispatchQueue.main.async {
                guard let self, self.generation == attempt else { return }
                self.stop(reason: error?.localizedDescription ?? "Audio stopped")
            } }
            channel.start()
        } catch {
            if let rejection = try? identity.sign(AudioReply(id: offer.id, from: card, to: offer.from.id,
                accepted: false, reason: .playbackFailed, created: Date())) { respond(rejection) }
            stop(reason: error.localizedDescription)
        }
    }
    public func stop(reason: String = "Audio stopped") {
        sendDelivery.stop(); receiveDelivery.stop(); sentUpdates.stop()
        generation = UUID(); active = false; status = reason
        if let peer = transportPeerID, let session = transportSessionID { onTransportChanged?(peer, session, nil); onRouteDetails?(peer, session, nil) }
        transportPeerID = nil; transportSessionID = nil
        io.stop(); channel?.stop(); channel = nil
        listener?.cancel(); listener = nil
        candidates.forEach { $0.stop() }; candidates = []
        pendingConnections.forEach { $0.cancel() }; pendingConnections = []
        offer = nil; keys = nil; key = nil; selectedInput = nil; externalPCM = false; transmissionGain = nil
        activeOutputID = nil
        onFinished?()
        if incoming != nil { decide(allow: false) }
    }
}
