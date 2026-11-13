import XCTest
import CoreAudio
@testable import Soundbound

final class ApplicationAudioTests: XCTestCase {
    func testStereoCaptureBecomesMonoWireAudio() throws {
        let received = expectation(description: "Converted application audio")
        let bridge = ApplicationAudioBridge { pcm in
            XCTAssertFalse(pcm.isEmpty)
            XCTAssertEqual(pcm.count % 2, 0)
            XCTAssertLessThanOrEqual(pcm.count, 4_928)
            received.fulfill()
        }
        try bridge.configure(sampleRate: 48_000)
        var samples = [Float](repeating: 0.2, count: 4_800 * 2)
        samples.withUnsafeMutableBytes { bytes in
            var buffers = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            withUnsafeMutablePointer(to: &buffers) { bridge.submit(UnsafeMutableAudioBufferListPointer($0)) }
        }
        wait(for: [received], timeout: 2)
    }
    func testInvalidSampleRateIsRejected() {
        XCTAssertThrowsError(try ApplicationAudioBridge { _ in XCTFail() }.configure(sampleRate: 0))
    }
}
