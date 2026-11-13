import Foundation

/// Only the room owner publishes its definition and layout. Other hosts mirror it.
struct RoomLayout: Codable {
    var room: AudioRoom
    var hosts: [String]
    var components: [RoomComponent]
}
struct RoomComponent: Codable {
    var host: String
    var component: String
}

extension HubStore {
    func ownedRoomLayouts() -> [RoomLayout] {
        rooms.filter { $0.owner == deviceID }.map { room in
            var hosts = peerMemberships.filter { $0.value.contains(room.id) }.map(\.key)
            if deviceRooms.contains(room.id) { hosts.append(deviceID) }
            let components = audioMemberships.filter { $0.value.contains(room.id) }.map { entry -> RoomComponent in
                if entry.key.hasPrefix("remote:") {
                    let parts = entry.key.split(separator: ":", maxSplits: 2).map(String.init)
                    if parts.count == 3 { return RoomComponent(host: parts[1], component: parts[2]) }
                }
                return RoomComponent(host: deviceID, component: entry.key)
            }
            return RoomLayout(room: room, hosts: hosts, components: components)
        }
    }

    @discardableResult
    func mergeRoomLayouts(_ layouts: [RoomLayout], from owner: String) -> Bool {
        guard friends.contains(where: { $0.id == owner }), layouts.count <= 64,
              Set(layouts.map { $0.room.id }).count == layouts.count,
              layouts.allSatisfy({ $0.room.owner == owner && $0.room.name.count <= 60 && $0.room.region.count <= 60 && $0.hosts.count <= 64 && $0.components.count <= 128 &&
                  ($0.room.guests ?? []).count <= 64 && ($0.room.guests ?? []).allSatisfy { $0.name.count <= 60 && $0.id.count <= 128 } }),
              !layouts.contains(where: { layout in rooms.contains { $0.id == layout.room.id && $0.owner != owner } }) else { return false }
        let old = Set(rooms.filter { $0.owner == owner }.map(\.id))
        let incoming = Set(layouts.map { $0.room.id })
        let affected = old.union(incoming)
        let oldState = rooms
        let oldHosts = deviceRooms, oldPeers = peerMemberships, oldAudio = audioMemberships
        rooms.removeAll { $0.owner == owner }
        rooms.append(contentsOf: layouts.map(\.room))
        rooms.sort { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
        deviceRooms.subtract(affected)
        for key in Array(peerMemberships.keys) { peerMemberships[key]?.subtract(affected) }
        for key in Array(audioMemberships.keys) { audioMemberships[key]?.subtract(affected) }
        for layout in layouts {
            for host in layout.hosts {
                if host == deviceID { deviceRooms.insert(layout.room.id) }
                else { peerMemberships[host, default: []].insert(layout.room.id) }
            }
            for item in layout.components {
                let key = item.host == deviceID ? item.component : Self.remoteComponentID(peer: item.host, component: item.component)
                audioMemberships[key, default: []].insert(layout.room.id)
            }
        }
        if oldState != rooms || oldHosts != deviceRooms || oldPeers != peerMemberships || oldAudio != audioMemberships { persist() }
        return true
    }
}
