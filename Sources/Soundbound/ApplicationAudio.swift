import Foundation
import CoreAudio
import AVFAudio
import SoundboundKit

/// Copies at most one hardware buffer at a time off the realtime audio callback.
/// The tap already mixes the selected processes; conversion produces the wire format.
final class ApplicationAudioBridge {
    private let queue = DispatchQueue(label: "app.soundbound.application-audio")
    private let capacity = DispatchSemaphore(value: 1)
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let frame: (Data) -> Void
    private let deliveryLock = NSLock()
    private var active = true
    init(frame: @escaping (Data) -> Void) { self.frame = frame }

    func configure(sampleRate: Double) throws {
        guard sampleRate > 0,
              let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { throw ApplicationAudioError.format }
        inputFormat = input; outputFormat = output; self.converter = converter
    }

    func submit(_ buffers: UnsafeMutableAudioBufferListPointer) {
        guard capacity.wait(timeout: .now()) == .success else { return }
        let usable = buffers.filter { $0.mData != nil && $0.mNumberChannels > 0 }
        guard let first = usable.first else { capacity.signal(); return }
        let count = min(16_384, Int(first.mDataByteSize) / MemoryLayout<Float>.size / Int(first.mNumberChannels))
        guard count > 0 else { capacity.signal(); return }
        var samples = [Float](repeating: 0, count: count)
        let channels = usable.reduce(0) { $0 + Int($1.mNumberChannels) }
        for buffer in usable {
            let channelCount = Int(buffer.mNumberChannels)
            let source = buffer.mData!.assumingMemoryBound(to: Float.self)
            let available = min(count, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channelCount)
            for index in 0..<available {
                for channel in 0..<channelCount { samples[index] += source[index * channelCount + channel] / Float(channels) }
            }
        }
        queue.async { [self] in
            defer { capacity.signal() }
            guard let inputFormat, let outputFormat, let converter,
                  let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)),
                  let destination = input.floatChannelData?[0],
                  let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                    frameCapacity: AVAudioFrameCount(ceil(Double(count) * 24_000 / inputFormat.sampleRate) + 64)) else { return }
            input.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: count) }
            var consumed = false
            var error: NSError?
            let result = converter.convert(to: output, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return input
            }
            guard result != .error, error == nil, output.frameLength > 0, let data = output.int16ChannelData?[0] else { return }
            deliveryLock.lock(); defer { deliveryLock.unlock() }
            if active { frame(Data(bytes: data, count: Int(output.frameLength) * 2)) }
        }
    }
    func stop() { deliveryLock.lock(); active = false; deliveryLock.unlock() }
}

@available(macOS 14.2, *)
final class MacApplicationAudio {
    private var session: AppTapSession?
    private var timer: Timer?
    private var generation = UUID()
    var onPCM: ((Data) -> Void)?
    var onError: ((String) -> Void)?

    func start() {
        stop()
        let token = generation
        refresh()
        guard generation == token else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    private func refresh() {
        guard let ownProcess = MixerHAL.processObject(ProcessInfo.processInfo.processIdentifier) else {
            stop(); onError?("Could not identify Soundbound's audio process safely."); return
        }
        let exclusions = [ownProcess]
        let output = MixerHAL.number(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        guard output != 0 else { return } // Ignore a transient route query failure.
        guard session == nil || session!.excludedProcesses != exclusions || session!.outputID != output else { return }
        session?.stop(); session = nil
        // A global tap follows app starts/stops without destroying the aggregate.
        // Exclude this process so received audio can never feed back into sharing.
        let send = onPCM
        let bridge = ApplicationAudioBridge { pcm in send?(pcm) }
        do { session = try AppTapSession(processes: [], gain: 1, capture: bridge, excluding: exclusions) }
        catch { stop(); onError?("Could not share Mac audio: \(error.localizedDescription)") }
    }
    func stop() {
        generation = UUID(); timer?.invalidate(); timer = nil
        session?.stop(); session = nil
    }
    deinit { timer?.invalidate(); session?.stop() }
}

private enum ApplicationAudioError: LocalizedError {
    case format
    var errorDescription: String? { "The application audio format could not be converted." }
}
