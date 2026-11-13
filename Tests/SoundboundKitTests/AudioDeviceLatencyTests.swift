import XCTest
@testable import SoundboundKit

final class AudioDeviceLatencyTests: XCTestCase {
    func testRowSummaryShowsConnectionTypeThenDelay() {
        var speaker = LocalAudioDevice(id: "speaker", name: "Speaker", icon: "speaker", detail: "", status: "")
        speaker.hasOutput = true; speaker.connection = .builtIn
        XCTAssertEqual(speaker.connectionSummary(), "Built-in")
        speaker.latency = AudioDeviceLatency(outputMilliseconds: 6.2, ioBufferMilliseconds: 2.9, playbackBufferMilliseconds: 10)
        XCTAssertEqual(speaker.connectionSummary(), "Built-in · 19 ms")
        XCTAssertEqual(speaker.connectionSummary(remote: true, network: "Wi-Fi"), "Wi-Fi")
        XCTAssertEqual(speaker.connectionSummary(remote: true, network: "Wi-Fi", roundTrip: 8), "Wi-Fi · 23 ms")
        var headphones = LocalAudioDevice(id: "pods", name: "AirPods", icon: "headphones", detail: "", status: "")
        headphones.hasOutput = true; headphones.connection = .bluetooth
        XCTAssertEqual(headphones.connectionSummary(connected: false), "Bluetooth · Not connected")
        XCTAssertEqual(headphones.connectionSummary(remote: true, network: "Ethernet", roundTrip: 4), "Ethernet + Bluetooth · 2 ms")
        var microphone = LocalAudioDevice(id: "mic", name: "Mic", icon: "mic", detail: "", status: "")
        microphone.hasInput = true; microphone.connection = .wired
        microphone.latency = AudioDeviceLatency(inputMilliseconds: 3, outputMilliseconds: 50)
        XCTAssertEqual(microphone.connectionSummary(), "Wired · 3 ms")
    }
    func testHardwareFramesUseActualSampleRate() {
        XCTAssertEqual(AudioDeviceLatency.milliseconds(frames: 128, sampleRate: 48_000)!, 2.6666667, accuracy: 0.00001)
        XCTAssertNil(AudioDeviceLatency.milliseconds(frames: 128, sampleRate: 0))
        XCTAssertNil(AudioDeviceLatency.milliseconds(frames: nil, sampleRate: 48_000))
        XCTAssertNil(AudioDeviceLatency.valid(.infinity))
        XCTAssertNil(AudioDeviceLatency.valid(-1))
    }
    func testOldInventoriesDecodeWithoutTimingAndNewTimingRoundTrips() throws {
        var device = LocalAudioDevice(id: "speaker", name: "Speaker", icon: "speaker", detail: "", status: "")
        XCTAssertNil(try JSONDecoder().decode(LocalAudioDevice.self, from: JSONEncoder().encode(device)).latency)
        device.latency = AudioDeviceLatency(outputMilliseconds: 1.5, ioBufferMilliseconds: 2.7)
        XCTAssertEqual(try JSONDecoder().decode(LocalAudioDevice.self, from: JSONEncoder().encode(device)), device)
    }
    func testInputAndOutputTimingSurviveProfileMerging() {
        var input = LocalAudioDevice(id: "mic", name: "Headset", icon: "mic", detail: "", status: "")
        input.physicalID = "headset"; input.hasInput = true
        input.latency = AudioDeviceLatency(inputMilliseconds: 3)
        var output = LocalAudioDevice(id: "speaker", name: "Headset", icon: "speaker", detail: "", status: "")
        output.physicalID = "headset"; output.hasOutput = true
        output.latency = AudioDeviceLatency(outputMilliseconds: 4)
        let merged = AudioDeviceInventory.reconcile([input, output])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].latency?.inputMilliseconds, 3)
        XCTAssertEqual(merged[0].latency?.outputMilliseconds, 4)
    }
    func testPlaybackOccupancyIsMeasuredAndRemovedWhenStopped() {
        let token = UUID(), buffer = LiveAudioBuffer()
        buffer.append(Data(repeating: 0, count: 480))
        AudioPlaybackMetrics.register(token, id: "test-speaker", systemID: 999, buffer: buffer)
        XCTAssertEqual(AudioPlaybackMetrics.bufferedMilliseconds(id: "test-speaker"), 10)
        XCTAssertEqual(AudioPlaybackMetrics.bufferedMilliseconds(id: "different", systemID: 999), 10)
        XCTAssertNil(AudioPlaybackMetrics.bufferedMilliseconds(id: "different", systemID: 998))
        AudioPlaybackMetrics.remove(token)
        XCTAssertNil(AudioPlaybackMetrics.bufferedMilliseconds(id: "test-speaker"))
    }
}
