import XCTest
@testable import SoundboundKit

final class LiveAudioBufferTests: XCTestCase {
    private func pcm(_ frames: Int, value: Int16 = 16_384) -> Data {
        [Int16](repeating: value.littleEndian, count: frames).withUnsafeBytes { Data($0) }
    }

    private func render(_ buffer: LiveAudioBuffer, frames: Int) -> [Float] {
        var output = [Float](repeating: .nan, count: frames)
        output.withUnsafeMutableBufferPointer { buffer.render(into: $0.baseAddress!, frames: frames) }
        return output
    }

    func testPrefillAndStarvationFadeWithoutStepToSilence() {
        let buffer = LiveAudioBuffer()
        buffer.append(pcm(AudioBufferPolicy.initialPlaybackFrames - 120))
        XCTAssertEqual(render(buffer, frames: 120), [Float](repeating: 0, count: 120))
        buffer.append(pcm(120))
        let output = render(buffer, frames: 600)
        XCTAssertEqual(output[0], 0.5 / 120, accuracy: 0.00001)
        XCTAssertEqual(output[180], 0.5)
        XCTAssertEqual(output.last, 0)
        XCTAssertLessThan(zip(output, output.dropFirst()).map { abs($0 - $1) }.max()!, 0.005)
        XCTAssertEqual(buffer.statistics.underruns, 1)
        XCTAssertEqual(buffer.statistics.targetFrames, AudioBufferPolicy.initialPlaybackFrames + AudioBufferPolicy.targetStepFrames)
        buffer.append(pcm(600, value: -16_384))
        let resumed = render(buffer, frames: 240)
        XCTAssertLessThan(abs(resumed[0]), 0.005) // Smooth even with a fractional old sample retained.
        XCTAssertEqual(resumed.last, -0.5)
    }

    func testBurstOverflowIsBoundedAndCrossfades() {
        let buffer = LiveAudioBuffer()
        buffer.append(pcm(960))
        _ = render(buffer, frames: 240)
        for _ in 0..<20 { buffer.append(pcm(480, value: -16_384)) }
        XCTAssertLessThanOrEqual(buffer.statistics.queuedFrames, 1_920)
        XCTAssertGreaterThan(buffer.statistics.overruns, 0)
        let output = render(buffer, frames: 240)
        XCTAssertGreaterThan(output[0], 0.48)
        XCTAssertEqual(output.last, -0.5)
        XCTAssertLessThan(zip(output, output.dropFirst()).map { abs($0 - $1) }.max()!, 0.01)
    }

    func testOneMillisecondPacketsWithTenMillisecondCallbackBatches() {
        let buffer = LiveAudioBuffer()
        let packet = pcm(24)
        buffer.append(pcm(AudioBufferPolicy.initialPlaybackFrames), at: 0)
        for tick in 0..<12_000 {
            if tick % 2 == 1 { for _ in 0..<10 { buffer.append(packet, at: UInt64(tick) * 5_000_000) } }
            _ = render(buffer, frames: 120)
        }
        XCTAssertEqual(buffer.statistics.underruns, 0)
        XCTAssertEqual(buffer.statistics.overruns, 0)
    }

    func testLongerCaptureBatchesAdaptRatherThanRepeatedlyStarve() {
        let buffer = LiveAudioBuffer()
        let packet = pcm(24)
        var output = [Float](repeating: 0, count: 120)
        var settledUnderruns = 0
        for tick in 0..<12_000 {
            // Devices may ignore the requested capture cadence: deliver twenty
            // 1 ms packets together every 20 ms, with 5 ms arrival jitter.
            if tick % 8 == 0 || tick % 8 == 5 {
                for _ in 0..<20 { buffer.append(packet, at: UInt64(tick) * 5_000_000) }
            }
            output.withUnsafeMutableBufferPointer { buffer.render(into: $0.baseAddress!, frames: 120) }
            if tick == 2_000 { settledUnderruns = buffer.statistics.underruns }
        }
        XCTAssertEqual(buffer.statistics.underruns, settledUnderruns)
        XCTAssertGreaterThan(settledUnderruns, 0)
        XCTAssertLessThanOrEqual(buffer.statistics.targetFrames, AudioBufferPolicy.maximumTargetFrames)
        XCTAssertEqual(buffer.statistics.overruns, 0)
    }

    func testClockMismatchIsAbsorbedWithoutPacketDrops() {
        for speed in [0.999, 1.001] {
            let buffer = LiveAudioBuffer()
            let packet = pcm(24)
            buffer.append(pcm(AudioBufferPolicy.initialPlaybackFrames), at: 0)
            var produced = 0.0
            var output = [Float](repeating: 0, count: 120)
            for tick in 0..<60_000 { // Five minutes of independent sender/receiver clocks.
                produced += 120 * speed
                while produced >= 24 { buffer.append(packet, at: UInt64(tick) * 5_000_000); produced -= 24 }
                output.withUnsafeMutableBufferPointer { buffer.render(into: $0.baseAddress!, frames: 120) }
            }
            XCTAssertEqual(buffer.statistics.underruns, 0, "speed \(speed)")
            XCTAssertEqual(buffer.statistics.overruns, 0, "speed \(speed)")
            XCTAssertEqual(buffer.statistics.playbackRate, speed, accuracy: 0.0006)
        }
    }

    func testRecoveredTargetShrinksAfterStableDeliveryWithoutAnotherUnderrun() {
        let buffer = LiveAudioBuffer()
        buffer.append(pcm(240), at: 0)
        for _ in 0..<3 { _ = render(buffer, frames: 120) }
        XCTAssertEqual(buffer.statistics.targetFrames, 480)
        buffer.append(pcm(600), at: 1_000_000)
        for tick in 1...8_000 {
            buffer.append(pcm(120), at: UInt64(tick) * 5_000_000)
            _ = render(buffer, frames: 120)
        }
        XCTAssertEqual(buffer.statistics.targetFrames, 288) // 5 ms gap + render quantum + margin.
        XCTAssertEqual(buffer.statistics.underruns, 1)
        XCTAssertEqual(buffer.statistics.overruns, 0)
        XCTAssertLessThan(buffer.statistics.queuedFrames, 400)
    }

    func testOversizeInputAndMalformedPacketsCannotGrowQueue() {
        let buffer = LiveAudioBuffer()
        buffer.append(Data([0]))
        XCTAssertEqual(buffer.statistics.queuedFrames, 0)
        buffer.append(pcm(4_800))
        XCTAssertEqual(buffer.statistics.queuedFrames, 1_920)
        XCTAssertTrue(render(buffer, frames: 240).allSatisfy { $0.isFinite })
    }
}
