import Foundation

/// Software attenuation for Soundbound's signed 16-bit, little-endian audio.
public enum AudioGain {
    public static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 1
    }
    public static func applying(_ value: Double, to pcm: Data) -> Data {
        let gain = clamped(value)
        guard gain != 1, pcm.count % 2 == 0 else { return pcm }
        var result = pcm
        result.withUnsafeMutableBytes { bytes in
            for offset in stride(from: 0, to: bytes.count, by: 2) {
                let sample = Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))
                bytes.storeBytes(of: Int16(Double(sample) * gain).littleEndian, toByteOffset: offset, as: Int16.self)
            }
        }
        return result
    }
}

extension HubStore {
    public func audioGain(for id: String, input: Bool = false) -> Double {
        AudioGain.clamped(deviceLevels[(input ? "gain.input:" : "gain.output:") + id] ?? 1)
    }
    public func setAudioGain(_ value: Double, for id: String, input: Bool = false) {
        let gain = AudioGain.clamped(value)
        deviceLevels[(input ? "gain.input:" : "gain.output:") + id] = gain
        if !input { onPlaybackGainChanged?(id, gain) }
        mesh.refreshAudioGains(); roomAudio.refreshDelivery()
        persist()
    }
    public func toggleAudioMute(for id: String, input: Bool = false) {
        let savedKey = (input ? "unmute.input:" : "unmute.output:") + id
        let current = audioGain(for: id, input: input)
        if current > 0 {
            deviceLevels[savedKey] = current
            setAudioGain(0, for: id, input: input)
        } else {
            setAudioGain(deviceLevels[savedKey] ?? 1, for: id, input: input)
        }
    }
    func inputGain(for device: LocalAudioDevice?) -> Double {
        let id = device?.id ?? reportedAudioDevices.first(where: { $0.selectedInput })?.id
        return id.map { audioGain(for: $0, input: true) } ?? 1
    }
    func playbackGain(for outputID: String?) -> Double {
        let id = outputID ?? reportedAudioDevices.first(where: { $0.selectedOutput })?.id
        return id.map { audioGain(for: $0) } ?? 1
    }
}
