import Foundation
import AVFAudio
#if os(macOS)
import AVFoundation
#endif

final class MeshAudioIO {
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var playout: LiveAudioBuffer?
    private let metricsID = UUID()
    private var hasTap = false
    private var toneTimer: DispatchSourceTimer?
    private let toneQueue = DispatchQueue(label: "app.soundbound.test-tone", qos: .userInteractive)
    #if os(iOS)
    private var sessionUse: Bool?
    private static var playbackUsers = 0
    private static var captureUsers = 0
    static var audioSessionIsActive: Bool { playbackUsers + captureUsers > 0 }

    private func acquireSession(capture: Bool) throws {
        if capture { Self.captureUsers += 1 } else { Self.playbackUsers += 1 }
        sessionUse = capture
        do {
            let session = AVAudioSession.sharedInstance()
            try? session.setPreferredIOBufferDuration(0.001)
            if Self.captureUsers > 0 {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
            } else { try session.setCategory(.playback, mode: .default, options: [.mixWithOthers]) }
            try session.setActive(true)
        } catch { releaseSession(); throw error }
    }
    private func releaseSession() {
        guard let capture = sessionUse else { return }
        sessionUse = nil
        if capture { Self.captureUsers -= 1 } else { Self.playbackUsers -= 1 }
        if Self.captureUsers + Self.playbackUsers == 0 {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    #endif
    private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    deinit { AudioPlaybackMetrics.remove(metricsID) }

    static func microphonePermission(_ completion: @escaping (Bool) -> Void) {
        #if os(iOS)
        AVAudioSession.sharedInstance().requestRecordPermission { allowed in DispatchQueue.main.async { completion(allowed) } }
        #else
        AVCaptureDevice.requestAccess(for: .audio) { allowed in DispatchQueue.main.async { completion(allowed) } }
        #endif
    }
    func startTestTone(repeating: Bool = true, frame: @escaping (Data) -> Void) {
        stop()
        var offset = 0
        let timer = DispatchSource.makeTimerSource(queue: toneQueue)
        toneTimer = timer
        timer.schedule(deadline: .now(), repeating: 0.001)
        timer.setEventHandler {
            if offset >= 6_240 {
                guard repeating else { return }
                offset = 0
            }
            let sampleCount = AudioBufferPolicy.wireFrameBytes / 2
            let samples: [Int16] = (0..<sampleCount).map { index in
                let t = Double(offset + index) / 24_000
                let fade = min(1, min(t / 0.05, max(0, (0.26 - t) / 0.06)))
                return Int16(sin(2 * .pi * (660 * t - 440 * t * t)) * 1000 * fade)
            }
            offset += sampleCount
            frame(samples.withUnsafeBytes { Data($0) })
        }
        timer.resume()
    }
    func startCapture(inputSystemID: UInt32? = nil, inputUID: String? = nil, frame: @escaping (Data) -> Void) throws {
        stop()
        var started = false
        defer { if !started { stop() } }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try acquireSession(capture: true)
        if let inputUID {
            guard let input = session.availableInputs?.first(where: {
                $0.uid == inputUID || (inputUID == "builtin-microphone" && $0.portType == .builtInMic)
            }) else { throw AudioMeshError.microphone }
            try session.setPreferredInput(input)
        }
        #endif
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        #if os(macOS)
        if let inputSystemID { try input.auAudioUnit.setDeviceID(inputSystemID) }
        #endif
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: pcm) else { throw AudioMeshError.microphone }
        let requestedFrames = AVAudioFrameCount(max(64, ceil(format.sampleRate * 0.001)))
        input.installTap(onBus: 0, bufferSize: requestedFrames, format: format) { buffer, _ in
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
            // Delivery applies the current packet limit off the audio thread.
            // Bound unusually large hardware callbacks to the delivery input limit.
            for offset in stride(from: 0, to: data.count, by: 32_768) {
                frame(Data(data[offset..<min(offset + 32_768, data.count)]))
            }
        }
        hasTap = true
        engine.prepare(); try engine.start()
        started = true
    }
    func startPlayback(outputSystemID: UInt32? = nil, expectedOutputID: String? = nil) throws {
        stop()
        var started = false
        defer { if !started { stop() } }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try acquireSession(capture: false)
        if let expectedOutputID, !session.currentRoute.outputs.contains(where: {
            $0.uid == expectedOutputID || (expectedOutputID == AudioDeviceInventory.phoneSpeakerID &&
                ($0.portType == .builtInSpeaker || $0.portType == .builtInReceiver))
        }) {
            throw AudioMeshError.invalid
        }
        #endif
        let engine = AVAudioEngine()
        let playout = LiveAudioBuffer()
        let source = AVAudioSourceNode(format: wireFormat) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            playout.render(into: first, frames: Int(frameCount))
            for buffer in buffers.dropFirst() {
                if let destination = buffer.mData {
                    memcpy(destination, first, Int(frameCount) * MemoryLayout<Float>.size)
                }
            }
            return noErr
        }
        #if os(macOS)
        if let outputSystemID { try engine.outputNode.auAudioUnit.setDeviceID(outputSystemID) }
        #endif
        self.engine = engine
        self.sourceNode = source
        self.playout = playout
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: wireFormat)
        engine.prepare(); try engine.start()
        AudioPlaybackMetrics.register(metricsID, id: expectedOutputID, systemID: outputSystemID, buffer: playout)
        started = true
    }
    func play(_ pcm: Data) {
        playout?.append(pcm)
    }
    /// Snapshot the buffer on the control thread; worker callbacks never touch
    /// the mutable engine reference. A stopped engine cannot render this buffer.
    func playbackSink() -> ((Data) -> Void)? {
        guard let playout else { return nil }
        return { playout.append($0) }
    }
    func stop() {
        AudioPlaybackMetrics.remove(metricsID)
        toneTimer?.cancel(); toneTimer = nil
        if hasTap { engine?.inputNode.removeTap(onBus: 0); hasTap = false }
        engine?.stop(); engine = nil
        sourceNode = nil; playout = nil
        #if os(iOS)
        releaseSession()
        #endif
    }
}
