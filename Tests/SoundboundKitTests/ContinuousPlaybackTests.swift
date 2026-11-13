import XCTest
@testable import SoundboundKit

final class ContinuousPlaybackTests: XCTestCase {
    func testToneContinuesPastOneChirpAndStopsExplicitly() {
        let io = MeshAudioIO()
        let continued = expectation(description: "Tone still produces audio after one chirp")
        let stopped = expectation(description: "Stopping prevents further audio")
        var frames = 0
        let lock = NSLock()
        io.startTestTone { _ in
            lock.lock(); defer { lock.unlock() }
            frames += 1
            if frames == 600 { continued.fulfill() }
        }
        wait(for: [continued], timeout: 3)
        io.stop()
        lock.lock()
        let framesAtStop = frames
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            lock.lock(); let framesAfterStop = frames; lock.unlock()
            XCTAssertLessThanOrEqual(framesAfterStop, framesAtStop + 1) // An in-flight callback may finish.
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 1)
    }
}
