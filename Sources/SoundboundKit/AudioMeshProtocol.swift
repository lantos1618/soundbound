import Foundation
import CryptoKit

struct AudioOffer: Codable {
    var kind = "audio-offer"
    var version = 1
    var id: String
    var from: PeerCard
    var to: String
    var ephemeralKey: String
    var port: UInt16
    var created: Date
    var source = "microphone"
}
struct AudioReply: Codable {
    var kind = "audio-reply"
    var version = 1
    var id: String
    var from: PeerCard
    var to: String
    var accepted: Bool
    var ephemeralKey: String?
    var created: Date
}
public struct IncomingAudioRequest: Identifiable {
    public let id: String
    public let name: String
}
struct AudioWirePacket: Codable {
    var kind: String
    var sequence: UInt64
    var pcm: Data?
}
enum AudioMeshError: LocalizedError {
    case invalid, unauthorized, expired, disconnected, denied, microphone, busy
    var errorDescription: String? {
        switch self {
        case .invalid: return "The audio connection could not be verified."
        case .unauthorized: return "Pair these devices before sharing audio."
        case .expired: return "The audio request expired. Try again."
        case .disconnected: return "The audio connection ended."
        case .denied: return "The other device declined audio."
        case .microphone: return "Allow microphone access in Settings to share your microphone."
        case .busy: return "Stop the current audio session first."
        }
    }
}

/// Ephemeral X25519 keys are authenticated by signed offers/replies. Separate
/// send/receive keys and session-bound AAD prevent reflection and cross-session use.
struct AudioSessionCipher {
    let key: SymmetricKey
    let context: Data
    private(set) var sequence: UInt64 = 0
    private(set) var received: UInt64 = 0
    static func keys(privateKey: Curve25519.KeyAgreement.PrivateKey, remote: String,
                     session: String, source: String, sink: String) throws -> (SymmetricKey, SymmetricKey) {
        guard let raw = Data(url64: remote), raw.count == 32 else { throw AudioMeshError.invalid }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let salt = Data("Soundbound.audio.v1|\(session)|\(source)|\(sink)".utf8)
        let forward = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
            sharedInfo: Data("source-to-sink".utf8), outputByteCount: 32)
        let reverse = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
            sharedInfo: Data("sink-to-source".utf8), outputByteCount: 32)
        return (forward, reverse)
    }
    mutating func seal(kind: String, pcm: Data? = nil) throws -> Data {
        guard sequence < UInt64.max, pcm == nil || (pcm!.count <= 9_600 && pcm!.count % 2 == 0) else { throw AudioMeshError.invalid }
        sequence += 1
        let packet = AudioWirePacket(kind: kind, sequence: sequence, pcm: pcm)
        let bytes = try JSONEncoder().encode(packet)
        guard let combined = try AES.GCM.seal(bytes, using: key, authenticating: context).combined else { throw AudioMeshError.invalid }
        return combined
    }
    mutating func open(_ data: Data) throws -> AudioWirePacket {
        guard data.count <= 20_000 else { throw AudioMeshError.invalid }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: context)
        let packet = try JSONDecoder().decode(AudioWirePacket.self, from: plain)
        guard packet.sequence > received, ["hello", "audio", "ping", "stop"].contains(packet.kind),
              packet.pcm == nil || (packet.pcm!.count <= 9_600 && packet.pcm!.count % 2 == 0),
              packet.kind != "audio" || packet.pcm?.isEmpty == false else { throw AudioMeshError.invalid }
        received = packet.sequence
        return packet
    }
}
