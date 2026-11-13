import XCTest
@testable import SoundboundKit

final class DeviceAudioActivityTests: XCTestCase {
    func testPCMHistoryFillsEveryAmplitudeBarAndScrolls() {
        let activity = DeviceAudioActivity()
        // One bar stands for 40 ms of sound, so feed 40 ms at a time.
        let pcm = [Int16](repeating: 1_000, count: DeviceAudioActivity.meterWindowSamples).withUnsafeBytes { Data($0) }
        for _ in 0..<DeviceAudioActivity.amplitudeBarCount { activity.updateLevel("speaker", pcm: pcm); activity.tickMeters() }
        XCTAssertEqual(activity.waveforms["speaker"]?.count, DeviceAudioActivity.amplitudeBarCount)
        XCTAssertTrue(activity.waveforms["speaker"]!.allSatisfy { $0 > 0 })
        activity.updateLevel("speaker", pcm: Data(repeating: 0, count: DeviceAudioActivity.meterWindowSamples * 2)); activity.tickMeters()
        XCTAssertEqual(activity.waveforms["speaker"]?.count, DeviceAudioActivity.amplitudeBarCount)
        XCTAssertEqual(activity.waveforms["speaker"]?.last, 0)
        XCTAssertGreaterThan(activity.waveforms["speaker"]!.first!, 0)
    }

    func testPeerHistoryFillsEveryAmplitudeBar() {
        let activity = DeviceAudioActivity()
        for _ in 0..<40 { activity.showPeerPlayback("remote", level: 0.4); activity.tickMeters() }
        XCTAssertEqual(activity.waveforms["remote"], Array(repeating: 0.4, count: DeviceAudioActivity.amplitudeBarCount))
    }

    func testHostMeterFollowsActiveComponentThenReturnsToIdle() {
        let activity = DeviceAudioActivity()
        activity.chirp("host")
        activity.showPeerPlayback("speaker", level: 0.5)
        XCTAssertEqual(activity.meterID(host: "host", components: ["idle-mic", "speaker"]), "speaker")
        activity.clear("speaker")
        activity.clear("host")
        XCTAssertEqual(activity.meterID(host: "host", components: ["idle-mic", "speaker"]), "host")
    }
    func testRecordingTakesPriorityInSummaryMeters() {
        let activity = DeviceAudioActivity()
        activity.showPeerPlayback("speaker", level: 1)
        activity.showStreamLevel("mic", pcm: Data(repeating: 0, count: 96), recording: true)
        let id = activity.meterID(host: "host", components: ["speaker", "mic"])
        XCTAssertEqual(id, "mic")
        XCTAssertEqual(activity.modes[id], .recording)
    }

}
