import Foundation

public enum JoinPolicy: String, Codable, CaseIterable {
    case request = "Ask to join", friends = "Friends can join", invite = "Invite only"
}
public struct AudioRoom: Codable, Identifiable, Equatable {
    public var id = UUID().uuidString
    public var name: String
    public var region: String
    public var owner: String
    public var policy: JoinPolicy = .request
    public var level: Double = 0.5
    public var omni = false
    public var members: Set<String> = []
}
public struct KnownPeer: Codable, Identifiable {
    public var card: PeerCard
    public var acceptedAt: Date
    public var id: String { card.id }
}
public struct AccessRequest: Codable, Identifiable {
    public var id: String
    public var peer: PeerCard
    public var roomID: String?
    public var created: Date
}
struct JoinMessage: Codable {
    var version = 1
    var requestID: String
    var inviteNonce: String
    var peer: PeerCard
    var roomID: String?
    var created: Date
}
struct JoinReply: Codable {
    var version = 1
    var requestID: String
    var recipient: String
    var approved: Bool
    var peer: PeerCard
    var rooms: [AudioRoom]
    var created: Date
}
public struct NearbyPeer: Identifiable {
    public var id: String { invitation.peer.id }
    public var invitation: Invitation
    public var link: String
    var endpoint: LocalEndpoint
}
struct SavedHub: Codable {
    var name: String
    var rooms: [AudioRoom]
    var friends: [KnownPeer]
    var deviceRoom: String?
    var deviceLevels: [String: Double]?
    var audioRooms: [String: String]?
    var audioPolicies: [String: AudioDevicePolicy]?
    var peerRooms: [String: String]?
    var deviceRooms: Set<String>?
    var audioMemberships: [String: Set<String>]?
    var peerMemberships: [String: Set<String>]?
}

public enum LocalAudioAction {
    case useOutput, useInput, connect, disconnect, testSound, testOutput, heardSound, didNotHearSound
}

/// A device reported by the host OS, separate from a paired Soundbound peer.
public struct LocalAudioDevice: Identifiable, Equatable, Codable {
    public let id: String
    public let name: String
    public let icon: String
    public let detail: String
    public let status: String
    public var isAvailable = true
    public var isChecking = false
    public var hasInput = false
    public var hasOutput = false
    public var selectedInput = false
    public var selectedOutput = false
    public var canConnect = false
    public var canDisconnect = false
    public var canTest = false
    public var awaitingTestAnswer = false
    public var systemOutputID: UInt32?
    public var systemInputID: UInt32?
    public var volume: Double?
    public var busy = false
    public var connection: AudioConnection?
    public var canMoveBetweenHosts: Bool { connection == .bluetooth }
    public var connectionLabel: String { connection?.rawValue ?? "Audio device" }
    public init(id: String, name: String, icon: String, detail: String, status: String) {
        self.id = id; self.name = name; self.icon = icon; self.detail = detail; self.status = status
    }
}

public struct AudioDevicePolicy: Codable, Equatable {
    public var askBeforeChanges = true
    public var notifyChanges = true
    public var removeWhenDisconnected = false
    public init() {}
}

public enum AudioConnection: String, Codable {
    case builtIn = "Built-in"
    case bluetooth = "Bluetooth"
    case continuity = "Apple Continuity"
    case wired = "Wired"
    case virtual = "Virtual"
}
