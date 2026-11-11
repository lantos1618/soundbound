import Foundation
import AVFAudio
#if os(macOS)
import AVFoundation
#endif

final class MeshAudioIO {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var hasTap = false
    private var toneTimer: DispatchSourceTimer?
    private let playbackQueue = DispatchQueue(label: "app.soundbound.audio-playback")
    private var queuedFrames = 0
    private var playing = false
    private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    static func microphonePermission(_ completion: @escaping (Bool) -> Void) {
        #if os(iOS)
        AVAudioSession.sharedInstance().requestRecordPermission { allowed in DispatchQueue.main.async { completion(allowed) } }
        #else
        AVCaptureDevice.requestAccess(for: .audio) { allowed in DispatchQueue.main.async { completion(allowed) } }
        #endif
    }
    func startTestTone(frame: @escaping (Data) -> Void) {
        stop()
        var offset = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        toneTimer = timer
        timer.schedule(deadline: .now(), repeating: 0.02)
        timer.setEventHandler {
            guard offset < 6_240 else { return }
            let samples: [Int16] = (0..<480).map { index in
                let t = Double(offset + index) / 24_000
                let fade = min(1, min(t / 0.05, max(0, (0.26 - t) / 0.06)))
                return Int16(sin(2 * .pi * (660 * t - 440 * t * t)) * 1000 * fade)
            }
            offset += 480
            frame(samples.withUnsafeBytes { Data($0) })
        }
        timer.resume()
    }
    func startCapture(frame: @escaping (Data) -> Void) throws {
        stop()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)
        #endif
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: pcm) else { throw AudioMeshError.microphone }
        input.installTap(onBus: 0, bufferSize: 960, format: format) { buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 24_000 / format.sampleRate) + 64)
            guard let output = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            let result = converter.convert(to: output, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return buffer
            }
            guard result != .error, error == nil, output.frameLength > 0,
                  let samples = output.int16ChannelData?[0] else { return }
            let data = Data(bytes: samples, count: Int(output.frameLength) * 2)
            // Wire packets are bounded even if a device supplies unusually large buffers.
            for offset in stride(from: 0, to: data.count, by: 1920) {
                frame(Data(data[offset..<min(offset + 1920, data.count)]))
            }
        }
        hasTap = true
        engine.prepare(); try engine.start()
    }
    func startPlayback(outputSystemID: UInt32? = nil, expectedOutputID: String? = nil) throws {
        stop()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        if let expectedOutputID, !session.currentRoute.outputs.contains(where: { $0.uid == expectedOutputID }) {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioMeshError.invalid
        }
        #endif
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        #if os(macOS)
        if let outputSystemID { try engine.outputNode.auAudioUnit.setDeviceID(outputSystemID) }
        #endif
        self.engine = engine; self.player = player
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: wireFormat)
        engine.prepare(); try engine.start(); player.play()
        playbackQueue.sync { playing = true; queuedFrames = 0 }
    }
    func play(_ pcm: Data) {
        playbackQueue.async { [weak self] in
            guard let self, self.playing, let player = self.player,
                  pcm.count > 0, pcm.count % 2 == 0, pcm.count <= 9600 else { return }
            let count = pcm.count / 2
            // At most 200 ms of audio is queued; drop instead of accumulating delay.
            guard self.queuedFrames + count <= 4800,
                  let buffer = AVAudioPCMBuffer(pcmFormat: self.wireFormat, frameCapacity: AVAudioFrameCount(count)),
                  let output = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(count)
            pcm.withUnsafeBytes { bytes in
                for i in 0..<count {
                    let sample = bytes.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                    output[i] = Float(Int16(littleEndian: sample)) / 32768
                }
            }
            self.queuedFrames += count
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.playbackQueue.async { [weak self] in
                    guard let self else { return }
                    self.queuedFrames = max(0, self.queuedFrames - count)
                }
            }
        }
    }
    func stop() {
        let hadEngine = engine != nil
        toneTimer?.cancel(); toneTimer = nil
        if hasTap { engine?.inputNode.removeTap(onBus: 0); hasTap = false }
        playbackQueue.sync { playing = false; queuedFrames = 0; player?.stop(); player = nil }
        engine?.stop(); engine = nil
        #if os(iOS)
        if hadEngine { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
    }
}
