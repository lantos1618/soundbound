import Foundation

/// Bounded PCM playout with a small jitter reserve. One producer may append while
/// the audio thread renders. The audio thread never waits for the producer.
final class LiveAudioBuffer {
    struct Statistics {
        var underruns = 0
        var overruns = 0
        var queuedFrames = 0
        var targetFrames = AudioBufferPolicy.initialPlaybackFrames
        var playbackRate = 1.0
    }

    private let lock = NSLock()
    private let capacity = AudioBufferPolicy.maximumPlaybackFrames
    private let samples: UnsafeMutablePointer<Float>
    private var head = 0
    private var count = 0
    private var phase = 0.0
    private var running = false
    private var needsCrossfade = false
    private var target = AudioBufferPolicy.initialPlaybackFrames
    private var filteredFill = Double(AudioBufferPolicy.initialPlaybackFrames - AudioBufferPolicy.wireFrameBytes / 4)
    private var rate = 1.0
    private var underruns = 0
    private var overruns = 0
    private var lastArrival: UInt64?
    private var windowGapFrames = 0
    private var previousGapFrames = 0
    private var windowFrames = 0
    private var stableFrames = 0
    private var maximumRenderFrames = 0

    // Only the render thread touches the transition state.
    private var lastOutput: Float = 0
    private var transitionStart: Float = 0
    private var transitionRemaining = 0
    private var concealRemaining = 0
    private var wasConcealing = true
    private let fadeFrames = 120 // 5 ms at the wire sample rate.

    init() {
        samples = .allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity)
    }

    deinit { samples.deinitialize(count: capacity); samples.deallocate() }

    var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        return Statistics(underruns: underruns, overruns: overruns,
                          queuedFrames: count, targetFrames: target, playbackRate: rate)
    }

    func append(_ pcm: Data, at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= 9_600 else { return }
        lock.lock(); defer { lock.unlock() }
        if let previous = lastArrival, now >= previous, now - previous < 250_000_000 {
            let gap = Int(ceil(Double(now - previous) * Double(AudioBufferPolicy.sampleRate) / 1_000_000_000))
            windowGapFrames = max(windowGapFrames, gap)
        }
        lastArrival = now
        let incoming = min(pcm.count / 2, capacity)
        let byteOffset = pcm.count - incoming * 2
        // Recover at a bounded live position instead of replaying stale audio.
        // A crossfade masks the sample discontinuity caused by this rare skip.
        if count + incoming > capacity {
            let retained = max(0, min(count, target - incoming))
            head = (head + count - retained) % capacity
            count = retained
            phase = 0
            needsCrossfade = true
            overruns += 1
        }
        pcm.withUnsafeBytes { bytes in
            for index in 0..<incoming {
                let value = bytes.loadUnaligned(fromByteOffset: byteOffset + index * 2, as: Int16.self)
                samples[(head + count + index) % capacity] = Float(Int16(littleEndian: value)) / 32_768
            }
        }
        count += incoming
    }

    /// Called serially by AVAudioSourceNode. No allocations, dispatches or waits.
    func render(into output: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        guard lock.try() else {
            conceal(into: output, from: 0, to: frames)
            return
        }
        defer { lock.unlock() }
        maximumRenderFrames = max(maximumRenderFrames, frames)
        if !running, count >= target {
            running = true
            filteredFill = Double(target - AudioBufferPolicy.wireFrameBytes / 4)
            rate = 1
            needsCrossfade = true
        }
        guard running else {
            conceal(into: output, from: 0, to: frames)
            return
        }

        // Average over two seconds so individual packet bursts do not
        // modulate pitch. Bound correction to +/- 0.2%, with a smooth slew.
        let averageFill = Double(count) - Double(frames) / 2
        let alpha = min(1, Double(frames) / 48_000)
        filteredFill += alpha * (averageFill - filteredFill)
        let error = filteredFill - Double(target - AudioBufferPolicy.wireFrameBytes / 4)
        // Drain excess smoothly instead of cutting samples. Temporary catch-up
        // is bounded to 0.5%; normal clock correction remains within 0.2%.
        let catchingUp = error > 120
        let correction = catchingUp ? min(0.005, error / 48_000) : max(-0.002, min(0.002, error / 120_000))
        let desiredRate = 1 + correction
        rate += min(1, Double(frames) / (catchingUp ? 12_000 : 48_000)) * (desiredRate - rate)
        if needsCrossfade || wasConcealing {
            transitionStart = lastOutput
            transitionRemaining = fadeFrames
            needsCrossfade = false
            wasConcealing = false
        }
        for index in 0..<frames {
            guard count >= 2 else {
                running = false
                underruns += 1
                target = min(AudioBufferPolicy.maximumTargetFrames, target + AudioBufferPolicy.targetStepFrames)
                stableFrames = 0
                conceal(into: output, from: index, to: frames)
                return
            }
            let first = samples[head]
            let second = samples[(head + 1) % capacity]
            var value = first + (second - first) * Float(phase)
            if transitionRemaining > 0 {
                let mix = Float(fadeFrames - transitionRemaining + 1) / Float(fadeFrames)
                value = transitionStart * (1 - mix) + value * mix
                transitionRemaining -= 1
            }
            output[index] = value
            lastOutput = value
            phase += rate
            let consumed = min(count, Int(phase))
            head = (head + consumed) % capacity
            count -= consumed
            phase -= Double(consumed)
        }
        stableFrames += frames
        windowFrames += frames
        if windowFrames >= AudioBufferPolicy.sampleRate * 5 {
            // Require ten seconds without starvation and reserve enough for
            // observed delivery gaps plus the hardware render quantum. Unlike
            // a blind timer, sustained large capture batches keep their reserve.
            let required = max(AudioBufferPolicy.initialPlaybackFrames,
                maximumRenderFrames + max(windowGapFrames, previousGapFrames) + AudioBufferPolicy.wireFrameBytes)
            if stableFrames >= AudioBufferPolicy.sampleRate * 10, target > required {
                target = max(required, target - AudioBufferPolicy.targetStepFrames)
            }
            previousGapFrames = windowGapFrames; windowGapFrames = 0; windowFrames = 0
        }
    }

    private func conceal(into output: UnsafeMutablePointer<Float>, from start: Int, to end: Int) {
        if !wasConcealing {
            transitionStart = lastOutput
            concealRemaining = fadeFrames
            wasConcealing = true
        }
        for index in start..<end {
            let value = concealRemaining > 0
                ? transitionStart * Float(concealRemaining - 1) / Float(fadeFrames) : 0
            concealRemaining = max(0, concealRemaining - 1)
            output[index] = value
            lastOutput = value
        }
    }
}
