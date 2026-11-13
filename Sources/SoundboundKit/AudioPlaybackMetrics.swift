import Foundation

/// Read-only snapshots of actual software playout occupancy. Not an E2E clock.
public enum AudioPlaybackMetrics {
    public struct Snapshot {
        public let queuedMilliseconds: Double
        public let targetMilliseconds: Double
        public let recoveries: Int
    }
    private struct Output {
        let id: String?
        let systemID: UInt32?
        let buffer: LiveAudioBuffer
    }
    private static let lock = NSLock()
    private static var outputs: [UUID: Output] = [:]
    static func register(_ token: UUID, id: String?, systemID: UInt32?, buffer: LiveAudioBuffer) {
        lock.lock(); defer { lock.unlock() }
        outputs[token] = Output(id: id, systemID: systemID, buffer: buffer)
    }
    static func remove(_ token: UUID) {
        lock.lock(); outputs[token] = nil; lock.unlock()
    }
    public static func bufferedMilliseconds(id: String, systemID: UInt32? = nil) -> Double? {
        snapshot(id: id, systemID: systemID)?.queuedMilliseconds
    }
    public static func snapshot(id: String, systemID: UInt32? = nil) -> Snapshot? {
        lock.lock(); let matching = outputs.values.filter {
            $0.id == id || (systemID != nil && $0.systemID == systemID)
        }; lock.unlock()
        guard let stats = matching.map({ $0.buffer.statistics }).max(by: { $0.queuedFrames < $1.queuedFrames }) else { return nil }
        return Snapshot(queuedMilliseconds: Double(stats.queuedFrames) * 1_000 / Double(AudioBufferPolicy.sampleRate),
                        targetMilliseconds: Double(stats.targetFrames) * 1_000 / Double(AudioBufferPolicy.sampleRate),
                        recoveries: stats.underruns)
    }
}
