import Foundation
import Network
import CryptoKit

/// Bounded, encrypted framed TCP stream for the first local-network audio path.
/// All state and callbacks live on one serial queue. No plaintext audio is sent.
final class AudioMeshChannel {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "app.soundbound.audio-channel")
    private var outbound: AudioSessionCipher
    private var inbound: AudioSessionCipher
    private let source: Bool
    private var buffer = Data()
    private var queuedBytes = 0
    private enum State { case connecting, authenticating, streaming, closed }
    private var state = State.connecting
    private var lastReceived = DispatchTime.now().uptimeNanoseconds
    private let handshakeTimeout: TimeInterval
    private var timer: DispatchSourceTimer?
    var ready: (() -> Void)?
    var audio: ((Data) -> Void)?
    var ended: ((Error?) -> Void)?
    var sentAudio: (() -> Void)?
    var pathChanged: ((LocalConnectionPath) -> Void)?
    var roundTrip: ((Double) -> Void)?
    private var pendingPings: [String: UInt64] = [:]
    var localPath: LocalConnectionPath { LocalConnectionPath(connection.currentPath) }

    init(connection: NWConnection, sendKey: SymmetricKey, receiveKey: SymmetricKey, session: String, source: Bool,
         handshakeTimeout: TimeInterval = 8) {
        self.connection = connection; self.source = source
        self.handshakeTimeout = handshakeTimeout
        outbound = AudioSessionCipher(key: sendKey, context: Data(session.utf8))
        inbound = AudioSessionCipher(key: receiveKey, context: Data(session.utf8))
    }
    func start() {
        // Bound TCP setup as well as the encrypted hello. A receiver must not
        // remain active forever when the advertised address stops responding.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now() + min(1, handshakeTimeout), repeating: min(1, handshakeTimeout))
        timer.setEventHandler { [weak self] in
            guard let self, self.state != .closed else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = Double(now - self.lastReceived) / 1_000_000_000
            if elapsed > (self.state == .streaming ? 5 : self.handshakeTimeout) {
                self.close(AudioMeshError.disconnected)
            } else if self.state == .streaming {
                self.pendingPings = self.pendingPings.filter { now >= $0.value && now - $0.value < 5_000_000_000 }
                let id = UUID().uuidString
                self.pendingPings[id] = now
                self.send(kind: "ping", pingID: id, echo: false)
            }
        }
        timer.resume()
        connection.pathUpdateHandler = { [weak self] path in self?.pathChanged?(LocalConnectionPath(path)) }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.state != .closed else { return }
            switch state {
            case .ready:
                guard self.state == .connecting else { return }
                self.state = .authenticating
                self.lastReceived = DispatchTime.now().uptimeNanoseconds
                self.pathChanged?(self.localPath)
                self.receive()
                if !self.source { self.send(kind: "hello") }
            case .failed(let error): self.close(error)
            case .cancelled: self.close(nil)
            case .waiting(let error):
                // Network.framework retries setup on path changes. Allow that
                // bounded wait; an established stream instead needs a new session.
                if self.state == .streaming { self.close(error) }
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func sendAudio(_ pcm: Data) { queue.async { [weak self] in self?.send(kind: "audio", pcm: pcm) } }
    // Keep the channel alive until cancellation runs, even when its owner removes it immediately.
    func stop() { queue.async { self.send(kind: "stop"); self.close(nil) } }
    private func send(kind: String, pcm: Data? = nil, pingID: String? = nil, echo: Bool? = nil) {
        guard state != .closed, kind != "audio" || state == .streaming else { return }
        // Drop audio under congestion instead of building an ever-growing delay.
        if kind == "audio", queuedBytes >= AudioBufferPolicy.maximumPendingSendBytes { return }
        do {
            let sealed = try outbound.seal(kind: kind, pcm: pcm, pingID: pingID, echo: echo)
            var size = UInt32(sealed.count).bigEndian
            var framed = withUnsafeBytes(of: &size) { Data($0) }; framed.append(sealed)
            queuedBytes += framed.count
            let count = framed.count
            connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queuedBytes -= count
                if let error { self.close(error) }
                else if kind == "audio" { self.sentAudio?() }
            })
        } catch { close(error) }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, complete, error in
            guard let self, self.state != .closed else { return }
            do {
                if let data { self.buffer.append(data) }
                guard self.buffer.count <= 65_536 else { throw AudioMeshError.invalid }
                while self.buffer.count >= 4 {
                    let size = self.buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    guard size > 0, size <= 20_000 else { throw AudioMeshError.invalid }
                    guard self.buffer.count >= 4 + Int(size) else { break }
                    let ciphertext = Data(self.buffer.dropFirst(4).prefix(Int(size)))
                    self.buffer.removeFirst(4 + Int(size))
                    let packet = try self.inbound.open(ciphertext)
                    self.lastReceived = DispatchTime.now().uptimeNanoseconds
                    if self.state == .authenticating {
                        guard packet.kind == "hello" else { throw AudioMeshError.unauthorized }
                        self.state = .streaming
                        if self.source { self.send(kind: "hello") }
                        self.ready?()
                    } else {
                        switch packet.kind {
                        case "audio":
                            guard !self.source, let pcm = packet.pcm else { throw AudioMeshError.invalid }
                            self.audio?(pcm)
                        case "ping":
                            if let id = packet.pingID, let echo = packet.echo {
                                if echo, let started = self.pendingPings.removeValue(forKey: id) {
                                    let now = DispatchTime.now().uptimeNanoseconds
                                    if now >= started { self.roundTrip?(Double(now - started) / 1_000_000) }
                                } else if !echo { self.send(kind: "ping", pingID: id, echo: true) }
                            }
                        case "stop": self.close(nil); return
                        default: throw AudioMeshError.invalid
                        }
                    }
                }
                if let error { self.close(error) }
                else if complete { self.close(nil) }
                else { self.receive() }
            } catch { self.close(error) }
        }
    }
    private func close(_ error: Error?) {
        guard state != .closed else { return }; state = .closed
        timer?.cancel(); timer = nil
        connection.cancel(); ended?(error)
    }
}
