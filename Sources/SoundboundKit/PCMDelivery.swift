import Foundation

/// Coalesces telemetry only. A blocked UI must never hold up audio delivery.
final class AudioUIUpdates {
    private let lock = NSLock()
    private var generation = UUID()
    private var callback: ((Int, Data?) -> Void)?
    private var count = 0
    private var pcm: Data?
    private var scheduled = false

    func start(_ callback: @escaping (Int, Data?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); self.callback = callback; count = 0; pcm = nil; scheduled = false
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); callback = nil; count = 0; pcm = nil; scheduled = false
    }
    func record(count: Int = 1, pcm: Data? = nil) {
        lock.lock()
        guard callback != nil else { lock.unlock(); return }
        self.count += count
        if let pcm { self.pcm = pcm }
        guard !scheduled else { lock.unlock(); return }
        scheduled = true
        let token = generation
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.generation == token else { self.lock.unlock(); return }
            let callback = self.callback, count = self.count, pcm = self.pcm
            self.count = 0; self.pcm = nil; self.scheduled = false
            self.lock.unlock()
            callback?(count, pcm)
        }
    }
}

/// Non-realtime worker with immutable routing/gain snapshots. Configuration is
/// supplied by the UI; processing never reads HubStore or waits for its queue.
final class PCMDelivery {
    struct Route {
        var gain: Double = 1
        var send: (Data) -> Void
    }
    private let queue = DispatchQueue(label: "app.soundbound.pcm-delivery", qos: .userInteractive)
    private let lock = NSLock()
    private var generation = UUID()
    private var active = false
    private var routes: [Route] = []
    private var gain = 1.0
    private var queuedFrames = 0
    let updates = AudioUIUpdates()

    func configure(routes: [Route], gain: Double = 1) {
        lock.lock(); defer { lock.unlock() }
        active = true; self.routes = routes; self.gain = AudioGain.clamped(gain)
    }
    func setGain(_ gain: Double) {
        lock.lock(); self.gain = AudioGain.clamped(gain); lock.unlock()
    }
    func stop() {
        lock.lock()
        generation = UUID(); active = false; routes = []; queuedFrames = 0
        lock.unlock()
        updates.stop()
    }
    func submit(_ pcm: Data) {
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= 32_768 else { return }
        let frames = pcm.count / 2
        lock.lock()
        // Permit one large hardware callback, but never accumulate a backlog.
        guard active, queuedFrames + frames <= max(AudioBufferPolicy.maximumPlaybackFrames, frames) else {
            lock.unlock(); return
        }
        queuedFrames += frames
        let token = generation, routes = self.routes, gain = self.gain
        let packetBytes = AudioBufferPolicy.capturePacketBytes
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = self.active && self.generation == token
            self.lock.unlock()
            guard valid else { return }
            let adjusted = AudioGain.applying(gain, to: pcm)
            var packets = 0
            for offset in stride(from: 0, to: adjusted.count, by: packetBytes) {
                let packet = Data(adjusted[offset..<min(offset + packetBytes, adjusted.count)])
                for route in routes { route.send(AudioGain.applying(route.gain, to: packet)) }
                packets += 1
            }
            self.lock.lock()
            let stillValid = self.active && self.generation == token
            if stillValid { self.queuedFrames -= frames }
            self.lock.unlock()
            if stillValid { self.updates.record(count: packets, pcm: adjusted) }
        }
    }
}
