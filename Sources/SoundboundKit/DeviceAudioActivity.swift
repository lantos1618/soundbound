import Foundation
import Combine

public final class DeviceAudioActivity: ObservableObject {
    public enum Mode: Equatable { case idle, waiting, chirping, recording }
    @Published public private(set) var modes: [String: Mode] = [:]
    @Published public private(set) var levels: [String: Double] = [:]
    @Published public private(set) var message: String?
    @Published public private(set) var messageID: String?
    @Published public private(set) var recordedID: String?
    @Published public private(set) var waveforms: [String: [Double]] = [:]
    private var clip = Data()
    private let io = MeshAudioIO()
    private var generation = UUID()
    private var remoteCaptureID: String?
    private var captureID: String?
    private var held = false
    private var playbackTimer: DispatchSourceTimer?
    var stopStream: (() -> Void)?
    public init() {}
    public func updateLevel(_ id: String, pcm: Data) {
        let value = Self.level(pcm)
        levels[id] = value
        var history = waveforms[id] ?? []
        history.append(value)
        waveforms[id] = Array(history.suffix(24))
    }
    public func showRecordingHint(_ id: String) {
        messageID = id
        message = "Hold the microphone icon to record. Release to stop, then choose Replay."
    }
    public func waiting(_ id: String) { modes[id] = .waiting }
    public func clearWaiting() {
        for id in Array(modes.keys) where modes[id] == .waiting { modes[id] = nil }
    }
    public func chirp(_ id: String) {
        modes[id] = .chirping; levels[id] = 0.8
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard self?.modes[id] == .chirping else { return }; self?.levels[id] = 0.25
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard self?.modes[id] == .chirping else { return }; self?.modes[id] = nil; self?.levels[id] = nil
        }
    }
    public func beginRecording(_ device: LocalAudioDevice) {
        guard device.hasInput, device.isAvailable, captureID == nil else { return }
        playbackTimer?.cancel(); playbackTimer = nil
        if let old = recordedID { modes[old] = nil; levels[old] = nil }
        let token = UUID(); generation = token; captureID = device.id; held = true
        clip = Data(); recordedID = nil; messageID = device.id; modes[device.id] = .waiting; message = "Waiting for microphone permission…"
        MeshAudioIO.microphonePermission { [weak self] allowed in
            guard let self, self.generation == token, self.held else { return }
            guard allowed else { self.message = "Allow microphone access in Settings to record."; self.endRecording(device.id); return }
            do {
                try self.io.startCapture(inputSystemID: device.systemInputID, inputUID: device.id.hasPrefix("input:") ? String(device.id.dropFirst(6)) : device.id) { [weak self] data in
                    DispatchQueue.main.async {
                        guard let self, self.generation == token, self.held else { return }
                        if self.clip.count + data.count <= 1_440_000 { self.clip.append(data) }
                        self.updateLevel(device.id, pcm: data)
                    }
                }
                self.modes[device.id] = .recording
                self.message = "Recording \(device.name) — tap to stop."
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard self?.generation == token else { return }; self?.endRecording(device.id)
                }
            } catch { self.message = error.localizedDescription; self.endRecording(device.id) }
        }
    }
    public func endRecording(_ id: String) {
        guard captureID == id else { if modes[id] == .recording || modes[id] == .waiting { stopStream?() }; return }
        held = false; generation = UUID(); captureID = nil; io.stop()
        modes[id] = nil; levels[id] = nil
        if !clip.isEmpty { recordedID = id; message = "Recording ready. It stays on this device in memory." }
        else if message == "Waiting for microphone permission…" { message = "Tap the microphone again to record." }
    }
    public func playRecording(_ id: String) {
        guard recordedID == id, !clip.isEmpty, captureID == nil else { return }
        playbackTimer?.cancel()
        do { try io.startPlayback() } catch { message = error.localizedDescription; return }
        let data = clip, token = UUID(); generation = token
        var offset = 0
        modes[id] = .chirping; message = "Playing your recording here."
        let timer = DispatchSource.makeTimerSource(queue: .main); playbackTimer = timer
        timer.schedule(deadline: .now(), repeating: 0.02)
        timer.setEventHandler { [weak self] in
            guard let self, self.generation == token else { return }
            if offset >= data.count {
                timer.cancel(); self.playbackTimer = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    guard self.generation == token else { return }
                    self.io.stop(); self.modes[id] = nil; self.levels[id] = nil
                }
                return
            }
            let frame = Data(data[offset..<min(offset + 960, data.count)])
            self.io.play(frame); self.updateLevel(id, pcm: frame); offset += frame.count
        }
        timer.resume()
    }
    public func clearStreams() {
        for id in Array(modes.keys) where id != captureID { clear(id) }
    }
    public func clear(_ id: String) { modes[id] = nil; levels[id] = nil; waveforms[id] = nil }
    public func beginRemoteRecording(_ id: String) {
        stopRecording(); stopPlayback(); remoteCaptureID = id
        clip = Data(); recordedID = nil; modes[id] = .waiting
    }
    public func receiveRemoteFrame(_ pcm: Data) {
        guard let id = remoteCaptureID else { return }
        if clip.count + pcm.count <= 1_440_000 { clip.append(pcm) }
        modes[id] = .recording; updateLevel(id, pcm: pcm)
    }
    public func finishRemoteRecording() {
        guard let id = remoteCaptureID else { return }
        remoteCaptureID = nil; clear(id)
        if !clip.isEmpty { recordedID = id }
    }
    public func showStreamLevel(_ id: String, pcm: Data, recording: Bool) {
        modes[id] = recording ? .recording : .chirping; updateLevel(id, pcm: pcm)
    }
    public func stopPlayback() {
        guard captureID == nil else { return }
        generation = UUID(); playbackTimer?.cancel(); playbackTimer = nil; io.stop()
        if let id = recordedID { modes[id] = nil; levels[id] = nil }
        message = "Playback stopped."
    }
    public func stopRecording() { if let captureID { endRecording(captureID) } }
    private static func level(_ data: Data) -> Double {
        guard data.count >= 2 else { return 0 }
        var sum = 0.0
        data.withUnsafeBytes { bytes in
            for i in stride(from: 0, to: data.count - 1, by: 2) {
                let sample = Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: i, as: Int16.self))) / 32768
                sum += sample * sample
            }
        }
        return min(1, sqrt(sum / Double(data.count / 2)) * 5)
    }
}
