import Foundation

public enum JoinPolicy: String, Codable, CaseIterable {
    case request = "Ask to join", friends = "Friends can join", invite = "Invite only"
}
/// What a guest may do in a room. The owner always has full control.
public enum GuestRole: String, Codable, CaseIterable {
    case control = "Can control", listen = "Can listen"
}
/// A paired device the owner has invited to a room.
public struct RoomGuest: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var role: GuestRole
    public init(id: String, name: String, role: GuestRole) { self.id = id; self.name = name; self.role = role }
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
    /// Optional so rooms saved or mirrored by earlier builds still decode.
    public var guests: [RoomGuest]?
    public func role(of deviceID: String) -> GuestRole? { guests?.first { $0.id == deviceID }?.role }
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
    case useOutput, useInput, connect, disconnect, testSound, testOutput, testOutputOnce, stopTest, heardSound, didNotHearSound
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
    public var physicalID: String?
    public var legacyID: String?
    public var latency: AudioDeviceLatency?
    public var canMoveBetweenHosts: Bool { connection == .bluetooth }
    public var connectionLabel: String { connection?.rawValue ?? "Audio device" }
    public init(id: String, name: String, icon: String, detail: String, status: String) {
        self.id = id; self.name = name; self.icon = icon; self.detail = detail; self.status = status
    }
    /// The delay this device reports for its own side of the path: OS latency, hardware buffer and queued audio.
    /// Nil when the OS reports none of them. A lower bound, not an acoustic measurement.
    public var reportedDelayMilliseconds: Double? {
        guard let latency else { return nil }
        let parts = hasOutput
            ? [latency.outputMilliseconds, latency.ioBufferMilliseconds, latency.playbackBufferMilliseconds]
            : [latency.inputMilliseconds, latency.ioBufferMilliseconds]
        let reported = parts.compactMap { $0 }
        return reported.isEmpty ? nil : reported.reduce(0, +)
    }
    /// The row's one-line summary: how the device is connected, then the delay along that path.
    /// `network` and `roundTrip` describe the link to the host that owns a remote device; a remote
    /// device shows no figure until that link has been measured.
    public func connectionSummary(connected: Bool = true, remote: Bool = false,
                                  network: String? = nil, roundTrip: Double? = nil) -> String {
        guard connected else { return connectionLabel + " · Not connected" }
        var type = connectionLabel
        if let network { type = connection == nil || connection == .builtIn ? network : network + " + " + type }
        let delay: Double?
        if remote { delay = AudioDeviceLatency.valid(roundTrip).map { $0 / 2 + (reportedDelayMilliseconds ?? 0) } }
        else { delay = reportedDelayMilliseconds }
        guard let delay else { return type }
        return type + " · " + String(format: "%.0f ms", delay)
    }
}

/// OS-reported components, never a sum or a capture-to-speaker measurement.
public struct AudioDeviceLatency: Codable, Equatable {
    public var inputMilliseconds: Double?
    public var outputMilliseconds: Double?
    public var ioBufferMilliseconds: Double?
    public var playbackBufferMilliseconds: Double?
    public var playbackTargetMilliseconds: Double?
    public var playbackRecoveries: Int?
    public init(inputMilliseconds: Double? = nil, outputMilliseconds: Double? = nil,
                ioBufferMilliseconds: Double? = nil, playbackBufferMilliseconds: Double? = nil,
                playbackTargetMilliseconds: Double? = nil, playbackRecoveries: Int? = nil) {
        self.inputMilliseconds = Self.valid(inputMilliseconds)
        self.outputMilliseconds = Self.valid(outputMilliseconds)
        self.ioBufferMilliseconds = Self.valid(ioBufferMilliseconds)
        self.playbackBufferMilliseconds = Self.valid(playbackBufferMilliseconds)
        self.playbackTargetMilliseconds = Self.valid(playbackTargetMilliseconds)
        self.playbackRecoveries = playbackRecoveries
    }
    public static func valid(_ milliseconds: Double?) -> Double? {
        guard let milliseconds, milliseconds.isFinite, milliseconds >= 0, milliseconds <= 10_000 else { return nil }
        return milliseconds
    }
    public static func milliseconds(frames: UInt32?, sampleRate: Double) -> Double? {
        guard let frames, sampleRate.isFinite, sampleRate > 0 else { return nil }
        return valid(Double(frames) * 1_000 / sampleRate)
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
