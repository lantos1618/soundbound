import XCTest
import SoundboundKit

final class InternalAudioDeviceTests: XCTestCase {
    func testOnlyOwnedRoutingDevicesAreHidden() {
        XCTAssertTrue(AudioDeviceInventory.isInternalDevice(id: "app.soundbound.internal.mixer.123", name: "Mixer", processID: 42))
        XCTAssertTrue(AudioDeviceInventory.isInternalDevice(id: "opaque", name: "CADefaultDeviceAggregate-42-0", processID: 42))
        XCTAssertFalse(AudioDeviceInventory.isInternalDevice(id: "opaque", name: "CADefaultDeviceAggregate-420-0", processID: 42))
        XCTAssertFalse(AudioDeviceInventory.isInternalDevice(id: "blackhole", name: "BlackHole 2ch", processID: 42))
        XCTAssertFalse(AudioDeviceInventory.isInternalDevice(id: "user-aggregate", name: "My aggregate", processID: 42))
    }
}
