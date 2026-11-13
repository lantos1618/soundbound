import Foundation
import Network

enum AudioBufferPolicy {
    static let sampleRate = 24_000
    static let wireFrameBytes = 48 // 1 ms of mono PCM16.
    // Keep the render/tone quantum independent from the adjustable delivery packet limit.
    private static let packetLock = NSLock()
    /// The limit is held in sample frames so it can go below a millisecond: 6 frames is 0.25 ms.
    private static var packetFrames = stored("Soundbound.capturePacketFrames",
        fallback: stored("Soundbound.capturePacketMilliseconds", fallback: 1, range: 1...20) * 24, range: 6...480)
    /// The sizes the audio map's slider stops at, smallest to largest. 1 ms is the default.
    static let capturePacketStops = [6, 12, 24, 48, 120, 240, 480]
    static var capturePacketFrames: Int {
        packetLock.lock(); defer { packetLock.unlock() }
        return packetFrames
    }
    /// Whole milliseconds, never less than one; use `capturePacketFrames` for the exact size.
    static var capturePacketMilliseconds: Int { max(1, capturePacketFrames * 1_000 / sampleRate) }
    static var capturePacketBytes: Int { capturePacketFrames * 2 }
    static func packetLabel(frames: Int) -> String {
        let milliseconds = Double(frames) * 1_000 / Double(sampleRate)
        return (milliseconds < 1 ? String(format: "%.2g", milliseconds) : String(format: "%.0f", milliseconds)) + " ms"
    }
    static func setCapturePacketFrames(_ value: Int) {
        let clamped = min(480, max(6, value))
        packetLock.lock(); packetFrames = clamped; packetLock.unlock()
        UserDefaults.standard.set(clamped, forKey: "Soundbound.capturePacketFrames")
        UserDefaults.standard.set(max(1, clamped * 1_000 / sampleRate), forKey: "Soundbound.capturePacketMilliseconds")
    }
    static func setCapturePacketMilliseconds(_ value: Int) { setCapturePacketFrames(min(20, max(1, value)) * sampleRate / 1_000) }
    /// The playout buffer's lower and upper targets on this device. Defaults are 10 ms and 60 ms; the audio
    /// map's Tuning panel can change them, and the choice is remembered. Read by the render path as plain integers.
    static var initialPlaybackFrames = stored("Soundbound.playoutFloorFrames", fallback: 240, range: 120...960)
    static var maximumTargetFrames = stored("Soundbound.playoutCeilingFrames", fallback: 1_440, range: 240...1_680)
    static let defaultFloorMilliseconds = 10, defaultCeilingMilliseconds = 60
    private static func stored(_ key: String, fallback: Int, range: ClosedRange<Int>) -> Int {
        let value = UserDefaults.standard.integer(forKey: key)
        return range.contains(value) ? value : fallback
    }
    /// Floor 5–40 ms, ceiling up to 70 ms and never below the floor. The buffer itself holds 80 ms.
    static func setPlayoutLimits(floorMilliseconds: Int, ceilingMilliseconds: Int) {
        let floor = min(40, max(5, floorMilliseconds))
        let ceiling = min(70, max(floor, ceilingMilliseconds))
        initialPlaybackFrames = floor * sampleRate / 1_000
        maximumTargetFrames = ceiling * sampleRate / 1_000
        UserDefaults.standard.set(initialPlaybackFrames, forKey: "Soundbound.playoutFloorFrames")
        UserDefaults.standard.set(maximumTargetFrames, forKey: "Soundbound.playoutCeilingFrames")
    }
    static let targetStepFrames = 240 // Recover in 10 ms increments.
    static let maximumPlaybackFrames = 1_920 // 80 ms, down from 200 ms.
    static let maximumPendingSendBytes = 8_192

    static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.disableAckStretching = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    static func canQueue(frames: Int, queued: Int) -> Bool {
        frames > 0 && queued >= 0 && frames <= maximumPlaybackFrames && queued <= maximumPlaybackFrames - frames
    }
}
