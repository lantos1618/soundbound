import XCTest
@testable import SoundboundKit

final class PCMDeliveryTests: XCTestCase {
    private var previousPacketMilliseconds = 1

    override func setUp() {
        super.setUp()
        previousPacketMilliseconds = AudioBufferPolicy.capturePacketMilliseconds
        AudioBufferPolicy.setCapturePacketMilliseconds(1)
    }

    override func tearDown() {
        AudioBufferPolicy.setCapturePacketMilliseconds(previousPacketMilliseconds)
        super.tearDown()
    }

    func testPacketLimitChangesDuringDeliveryWithoutLosingSamples() {
        let delivery = PCMDelivery()
        defer { delivery.stop() }
        let arrived = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var packets: [Data] = []
        delivery.configure(routes: [.init(send: { pcm in
            lock.lock(); packets.append(pcm); lock.unlock()
            arrived.signal()
        })])
        let initial = Data(repeating: 1, count: 96)
        delivery.submit(initial)
        for _ in 0..<2 { XCTAssertEqual(arrived.wait(timeout: .now() + 2), .success) }
        lock.lock()
        XCTAssertEqual(packets.map(\.count), [48, 48])
        packets.removeAll()
        lock.unlock()

        AudioBufferPolicy.setCapturePacketMilliseconds(20)
        let next = Data((0..<2_016).map { UInt8($0 % 256) })
        delivery.submit(next)
        for _ in 0..<3 { XCTAssertEqual(arrived.wait(timeout: .now() + 2), .success) }
        lock.lock()
        XCTAssertEqual(packets.map(\.count), [960, 960, 96])
        XCTAssertEqual(packets.reduce(into: Data()) { $0.append($1) }, next)
        lock.unlock()
    }

    func testPacketLimitIsClampedAndRemembered() {
        AudioBufferPolicy.setCapturePacketMilliseconds(-1)
        XCTAssertEqual(AudioBufferPolicy.capturePacketBytes, 48)
        AudioBufferPolicy.setCapturePacketMilliseconds(100)
        XCTAssertEqual(AudioBufferPolicy.capturePacketMilliseconds, 20)
        XCTAssertEqual(AudioBufferPolicy.capturePacketBytes, 960)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "Soundbound.capturePacketMilliseconds"), 20)
    }

    func testAudioArrivesWhileMainThreadIsBlockedAndUIIsCoalesced() {
        let delivery = PCMDelivery()
        let arrived = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var audioPackets = 0
        var uiUpdates = 0
        let ui = expectation(description: "One coalesced UI update")
        delivery.updates.start { count, _ in
            uiUpdates += 1
            XCTAssertEqual(count, 100)
            ui.fulfill()
        }
        delivery.configure(routes: [.init(send: { pcm in
            XCTAssertEqual(pcm.count, AudioBufferPolicy.wireFrameBytes)
            lock.lock(); audioPackets += 1; let done = audioPackets == 100; lock.unlock()
            if done { arrived.signal() }
        })])
        delivery.submit(Data(repeating: 0, count: AudioBufferPolicy.wireFrameBytes * 100))
        // Waiting on the main thread is deliberate: audio delivery must not need it.
        XCTAssertEqual(arrived.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(uiUpdates, 0)
        wait(for: [ui], timeout: 2)
        XCTAssertEqual(uiUpdates, 1)
        delivery.stop()
    }

    func testGainsAreSnapshottedAndStopDisablesDelivery() {
        let delivery = PCMDelivery(), arrived = DispatchSemaphore(value: 0)
        let sample: Int16 = 16_000
        let pcm = [Int16](repeating: sample, count: 24).withUnsafeBytes { Data($0) }
        delivery.configure(routes: [.init(gain: 0.5, send: { pcm in
            XCTAssertEqual(pcm.withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }, 4_000)
            arrived.signal()
        })], gain: 0.5)
        delivery.submit(pcm)
        XCTAssertEqual(arrived.wait(timeout: .now() + 2), .success)
        delivery.stop()
        delivery.submit(pcm)
        XCTAssertEqual(arrived.wait(timeout: .now() + 0.05), .timedOut)
    }

    func testStopCancelsQueuedUIEvents() {
        let updates = AudioUIUpdates()
        updates.start { _, _ in XCTFail("Stopped stream updated the UI") }
        for _ in 0..<100 { updates.record() }
        updates.stop()
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }
}
