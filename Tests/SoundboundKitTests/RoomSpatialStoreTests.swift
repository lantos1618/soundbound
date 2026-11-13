import XCTest
@testable import SoundboundKit

final class RoomSpatialStoreTests: XCTestCase {
    func testPersistsValidatedLayoutAndRejectsOlderOrInvalidPositions() throws {
        let defaults = UserDefaults(suiteName: "spatial-test." + UUID().uuidString)!
        let store = RoomSpatialStore(defaults: defaults)
        let key = RoomSpatialStore.deviceKey(host: "phone", device: "speaker")
        let layout = RoomSpatialLayout(roomID: "room", sourceDeviceID: "phone", usesLiDAR: true,
            floorOrigin: [0, 0, 0], positions: [key: RoomSpatialPoint(x: 1, y: 1, z: 2)],
            labels: [key: "Phone speaker"], surfaces: [])
        store.save(layout)
        XCTAssertEqual(RoomSpatialStore(defaults: defaults).layouts["room"], layout)
        var bad = layout; bad.positions[key]?.x = .infinity
        store.save(bad)
        XCTAssertEqual(store.layouts["room"], layout)
        var old = layout; old.capturedAt = layout.capturedAt.addingTimeInterval(-10)
        store.save(old)
        XCTAssertEqual(store.layouts["room"], layout)
    }
    func testUnpairedScanCannotEnterStore() throws {
        let hub = HubStore(identity: try Identity(ephemeral: true), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        hub.addRoom(name: "Room", region: "Home", policy: .request)
        let layout = RoomSpatialLayout(roomID: hub.rooms[0].id, sourceDeviceID: "stranger", usesLiDAR: false,
            floorOrigin: [0,0,0], positions: [:], labels: [:], surfaces: [])
        hub.receiveSpatialLayouts([layout], from: "stranger")
        XCTAssertTrue(hub.spatial.layouts.isEmpty)
    }
}
