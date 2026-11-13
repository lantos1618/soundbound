import XCTest
@testable import SoundboundKit

final class AudioGainTests: XCTestCase {
    func testMuteRestoresPreviousLevelAndKeepsInputSeparate() throws {
        let store = HubStore(identity: try Identity(ephemeral: true), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.setAudioGain(0.43, for: "speaker")
        store.toggleAudioMute(for: "speaker")
        XCTAssertEqual(store.audioGain(for: "speaker"), 0)
        XCTAssertEqual(store.audioGain(for: "speaker", input: true), 1)
        store.toggleAudioMute(for: "speaker")
        XCTAssertEqual(store.audioGain(for: "speaker"), 0.43)
    }
    private func pcm(_ samples: [Int16]) -> Data {
        samples.map(\.littleEndian).withUnsafeBytes { Data($0) }
    }
    func testAttenuationPreservesSignedSamplesAndUnityIsUnchanged() {
        let samples = pcm([Int16.min, -1000, 0, 1000, Int16.max])
        XCTAssertEqual(AudioGain.applying(1, to: samples), samples)
        XCTAssertEqual(AudioGain.applying(0.5, to: samples), pcm([-16384, -500, 0, 500, 16383]))
    }
    func testMuteAndOutOfRangeValues() {
        let samples = pcm([-32768, 12345, 32767])
        XCTAssertEqual(AudioGain.applying(0, to: samples), pcm([0, 0, 0]))
        XCTAssertEqual(AudioGain.applying(-1, to: samples), pcm([0, 0, 0]))
        XCTAssertEqual(AudioGain.applying(2, to: samples), samples)
        XCTAssertEqual(AudioGain.applying(.nan, to: samples), samples)
        XCTAssertEqual(AudioGain.applying(.infinity, to: samples), samples)
    }
    func testDisconnectedDevicePreferencesPersistAndDirectionsStayIndependent() throws {
        let identity = try Identity(ephemeral: true)
        let defaults = UserDefaults(suiteName: "audio-gain-test." + UUID().uuidString)!
        let store = HubStore(identity: identity, defaults: defaults)
        XCTAssertEqual(store.audioGain(for: "headset"), 1)
        XCTAssertEqual(store.audioGain(for: "headset", input: true), 1)
        store.setAudioGain(0.25, for: "headset")
        store.setAudioGain(0.75, for: "headset", input: true)
        let restored = HubStore(identity: identity, defaults: defaults)
        XCTAssertEqual(restored.audioGain(for: "headset"), 0.25)
        XCTAssertEqual(restored.audioGain(for: "headset", input: true), 0.75)
        XCTAssertEqual(restored.audioGain(for: "another-device"), 1)
    }
    func testOnlyOutputChangesNotifyLivePlayback() throws {
        let store = HubStore(identity: try Identity(ephemeral: true), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        var changes: [(String, Double)] = []
        store.onPlaybackGainChanged = { changes.append(($0, $1)) }
        store.setAudioGain(0.5, for: "mic", input: true)
        XCTAssertTrue(changes.isEmpty)
        store.setAudioGain(0.2, for: "speaker")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.0, "speaker")
        XCTAssertEqual(changes.first?.1, 0.2)
    }
}
