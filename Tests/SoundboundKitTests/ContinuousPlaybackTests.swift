import XCTest
@testable import SoundboundKit

final class ContinuousPlaybackTests: XCTestCase {
    func testToneContinuesPastOneChirpAndStopsExplicitly() {
        let io = MeshAudioIO()
        let continued = expectation(description: "Tone still produces audio after one chirp")
        let stopped = expectation(description: "Stopping prevents further audio")
        var frames = 0
        io.startTestTone { _ in
            frames += 1
            if frames == 30 { continued.fulfill() }
        }
        wait(for: [continued], timeout: 3)
        io.stop()
        let framesAtStop = frames
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            XCTAssertEqual(frames, framesAtStop)
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 1)
    }
}
