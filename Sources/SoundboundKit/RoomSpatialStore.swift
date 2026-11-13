import Foundation
import Combine

struct RoomSpatialSurface: Codable, Equatable {
    var transform: [Float]
    var width: Float
    var length: Float
    var valid: Bool {
        transform.count == 16 && transform.allSatisfy { $0.isFinite && abs($0) < 100 } &&
        width.isFinite && length.isFinite && width > 0 && length > 0 && width <= 20 && length <= 20
    }
}

struct RoomSpatialLayout: Codable, Equatable {
    var id = UUID().uuidString
    var roomID: String
    var sourceDeviceID: String
    var capturedAt = Date()
    var usesLiDAR: Bool
    var floorOrigin: [Float]
    var positions: [String: RoomSpatialPoint]
    var labels: [String: String]
    var surfaces: [RoomSpatialSurface]
    var valid: Bool {
        UUID(uuidString: id) != nil && roomID.count <= 128 && sourceDeviceID.count <= 128 &&
        floorOrigin.count == 3 && floorOrigin.allSatisfy { $0.isFinite && abs($0) < 100 } &&
        positions.count <= 32 && positions.allSatisfy { $0.key.count <= 512 && $0.value.valid } &&
        labels.count <= 32 && labels.allSatisfy { $0.key.count <= 512 && $0.value.count <= 128 } &&
        surfaces.count <= 16 && surfaces.allSatisfy(\.valid) && capturedAt.timeIntervalSinceNow <= 60
    }
}

public final class RoomSpatialStore: ObservableObject {
    @Published private(set) var layouts: [String: RoomSpatialLayout] = [:]
    private let defaults: UserDefaults
    private let key = "Soundbound.spatial-layouts.v1"
    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([String: RoomSpatialLayout].self, from: data) {
            layouts = saved.filter { $0.key == $0.value.roomID && $0.value.valid }
        }
    }
    func save(_ layout: RoomSpatialLayout) {
        guard layout.valid else { return }
        if let old = layouts[layout.roomID], old.capturedAt > layout.capturedAt { return }
        layouts[layout.roomID] = layout
        if let data = try? JSONEncoder().encode(layouts) { defaults.set(data, forKey: key) }
    }
    static func deviceKey(host: String, device: String) -> String { "device:" + host + ":" + device }
}

extension HubStore {
    private func spatialMember(_ host: String, roomID: String) -> Bool {
        if host == deviceID {
            return deviceRooms.contains(roomID) || audioMemberships.contains { !$0.key.hasPrefix("remote:") && $0.value.contains(roomID) }
        }
        return peerMemberships[host]?.contains(roomID) == true || audioMemberships.contains {
            $0.key.hasPrefix("remote:" + host + ":") && $0.value.contains(roomID)
        }
    }
    func spatialLayoutsForPeer(_ peerID: String) -> [RoomSpatialLayout] {
        Array(spatial.layouts.values.filter {
            $0.sourceDeviceID == deviceID && spatialMember(deviceID, roomID: $0.roomID) && spatialMember(peerID, roomID: $0.roomID)
        }.sorted { $0.capturedAt > $1.capturedAt }.prefix(1))
    }
    func receiveSpatialLayouts(_ layouts: [RoomSpatialLayout], from peerID: String) {
        guard layouts.count <= 1, friends.contains(where: { $0.id == peerID }) else { return }
        for layout in layouts where layout.valid && layout.sourceDeviceID == peerID &&
            rooms.contains(where: { $0.id == layout.roomID }) && spatialMember(deviceID, roomID: layout.roomID) && spatialMember(peerID, roomID: layout.roomID) {
            spatial.save(layout)
        }
    }
}
