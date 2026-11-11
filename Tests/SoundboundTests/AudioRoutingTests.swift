import XCTest
@testable import Soundbound

private final class FakeAudioBackend: AudioRoutingBackend {
    var present = true
    var selected: UInt32 = 1
    var request: UInt32?
    var reads = 0
    var applyAfterReads: Int?
    var rejected = false
    var level: Double? = 0.4
    var volumeRequest: Double?
    func available(_ id: UInt32, direction: AudioDirection) -> Bool { present }
    func current(_ direction: AudioDirection) -> UInt32 {
        reads += 1
        if let threshold = applyAfterReads, reads >= threshold, let request { selected = request }
        return selected
    }
    func select(_ id: UInt32, direction: AudioDirection) throws {
        if rejected { throw RoutingError.rejected(-1) }
        request = id
    }
    func volume(_ id: UInt32) -> Double? { level }
    func setVolume(_ value: Double, id: UInt32) throws { volumeRequest = value; level = value }
}

final class AudioRoutingTests: XCTestCase {
    func testWaitsForHardwareAcknowledgment() async throws {
        let backend = FakeAudioBackend()
        backend.applyAfterReads = 3
        let router = VerifiedAudioRouting(backend: backend, attempts: 4, pause: {})
        try await router.select(9, direction: .output)
        XCTAssertEqual(backend.reads, 3)
        XCTAssertEqual(backend.selected, 9)
    }
    func testSuccessfulWriteWithoutHardwareChangeIsFailure() async {
        let backend = FakeAudioBackend()
        do {
            try await VerifiedAudioRouting(backend: backend, attempts: 2, pause: {}).select(9, direction: .input)
            XCTFail("A successful write must not imply a successful route")
        } catch RoutingError.unconfirmed { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(backend.selected, 1)
    }
    func testDeviceDisappearingDuringChangeFails() async {
        let backend = FakeAudioBackend()
        do {
            let router = VerifiedAudioRouting(backend: backend, attempts: 3, pause: { backend.present = false })
            try await router.select(9, direction: .output)
            XCTFail("Removed hardware cannot be selected")
        } catch RoutingError.unavailable { } catch { XCTFail("Unexpected error: \(error)") }
    }
    func testRejectedWriteDoesNotChangeSelection() async {
        let backend = FakeAudioBackend(); backend.rejected = true
        do {
            try await VerifiedAudioRouting(backend: backend, pause: {}).select(9, direction: .output)
            XCTFail("Rejected route should fail")
        } catch RoutingError.rejected { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertNil(backend.request)
        XCTAssertEqual(backend.selected, 1)
    }
    func testVolumeIsClampedAndReadBack() async throws {
        let backend = FakeAudioBackend()
        try await VerifiedAudioRouting(backend: backend, pause: {}).setVolume(1.4, id: 9)
        XCTAssertEqual(backend.volumeRequest, 1)
        XCTAssertEqual(backend.level, 1)
    }
    func testUnsupportedVolumeNeverWrites() async {
        let backend = FakeAudioBackend(); backend.level = nil
        do {
            try await VerifiedAudioRouting(backend: backend, pause: {}).setVolume(0.6, id: 9)
            XCTFail("Unsupported hardware must not display a working slider")
        } catch RoutingError.volumeUnsupported { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertNil(backend.volumeRequest)
    }
}
