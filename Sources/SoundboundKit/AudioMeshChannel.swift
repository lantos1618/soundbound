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
    private var closed = false
    private var authenticated = false
    private var lastReceived = Date()
    private var timer: DispatchSourceTimer?
    var ready: (() -> Void)?
    var audio: ((Data) -> Void)?
    var ended: ((Error?) -> Void)?

    init(connection: NWConnection, sendKey: SymmetricKey, receiveKey: SymmetricKey, session: String, source: Bool) {
        self.connection = connection; self.source = source
        outbound = AudioSessionCipher(key: sendKey, context: Data(session.utf8))
        inbound = AudioSessionCipher(key: receiveKey, context: Data(session.utf8))
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive()
                if !self.source { self.send(kind: "hello") }
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                self.timer = timer
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    if Date().timeIntervalSince(self.lastReceived) > (self.authenticated ? 5 : 8) {
                        self.close(AudioMeshError.disconnected)
                    } else if self.authenticated { self.send(kind: "ping") }
                }
                timer.resume()
            case .failed(let error): self.close(error)
            case .cancelled: self.close(nil)
            case .waiting(let error): self.close(error)
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func sendAudio(_ pcm: Data) { queue.async { [weak self] in self?.send(kind: "audio", pcm: pcm) } }
    func stop() { queue.async { [weak self] in self?.send(kind: "stop"); self?.close(nil) } }
    private func send(kind: String, pcm: Data? = nil) {
        guard !closed, kind != "audio" || authenticated else { return }
        // Drop audio under congestion instead of building an ever-growing delay.
        if kind == "audio", queuedBytes > 32_000 { return }
        do {
            let sealed = try outbound.seal(kind: kind, pcm: pcm)
            var size = UInt32(sealed.count).bigEndian
            var framed = withUnsafeBytes(of: &size) { Data($0) }; framed.append(sealed)
            queuedBytes += framed.count
            let count = framed.count
            connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queuedBytes -= count
                if let error { self.close(error) }
            })
        } catch { close(error) }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
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
                    self.lastReceived = Date()
                    if !self.authenticated {
                        guard packet.kind == "hello" else { throw AudioMeshError.unauthorized }
                        self.authenticated = true
                        if self.source { self.send(kind: "hello") }
                        self.ready?()
                    } else {
                        switch packet.kind {
                        case "audio":
                            guard !self.source, let pcm = packet.pcm else { throw AudioMeshError.invalid }
                            self.audio?(pcm)
                        case "ping": break
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
        guard !closed else { return }; closed = true
        timer?.cancel(); timer = nil
        connection.cancel(); ended?(error)
    }
}
