import Foundation
import CryptoKit
import Security
import Darwin

public enum InviteError: LocalizedError {
    case malformed, expired, invalidSignature, ownIdentity, unavailable
    public var errorDescription: String? {
        switch self {
        case .malformed: return "This isn’t a Soundbound invitation. Paste the complete invite link, or discover the device nearby."
        case .expired: return "This invitation expired. Ask for a fresh code."
        case .invalidSignature: return "This invitation could not be verified. Ask for a new one."
        case .ownIdentity: return "That’s your own code. Scan or enter your friend’s code instead."
        case .unavailable: return "Your device identity could not be loaded or saved. Check storage access and try again."
        }
    }
}

extension Data {
    var url64: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(url64: String) {
        var value = url64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }
}

public struct PeerCard: Codable, Equatable, Identifiable {
    public var publicKey: String
    public var name: String
    public var kind: String
    /// The name of the person signed in on the device, so people can be listed by name. Absent when signed out
    /// and from older builds.
    public var owner: String? = nil
    public var id: String { Identity.fingerprint(publicKey) }
}

public struct Invitation: Codable, Equatable {
    public var version: Int = 1
    public var peer: PeerCard
    public var nonce: String
    public var expires: Date
    public var code: String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String(SHA256.hash(data: Data(nonce.utf8)).prefix(6).map { alphabet[Int($0) % alphabet.count] })
    }
}

public struct SignedEnvelope: Codable {
    public var payload: String
    public var signature: String
    public var signer: String
    public func verified<T: Decodable>(as: T.Type) throws -> T {
        guard let bytes = Data(url64: payload), bytes.count < 48_000,
              let keyData = Data(url64: signer), let signatureData = Data(url64: signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(signatureData, for: bytes) else { throw InviteError.invalidSignature }
        return try JSONDecoder().decode(T.self, from: bytes)
    }
    public var link: String {
        "soundbound://invite?token=" + ((try? JSONEncoder().encode(self))?.url64 ?? "")
    }
    public static func from(link: String, now: Date = Date()) throws -> (SignedEnvelope, Invitation) {
        guard link.utf8.count <= 12_000,
              let url = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "soundbound", url.host == "invite",
              let token = url.queryItems?.first(where: {$0.name == "token"})?.value,
              let data = Data(url64: token),
              let envelope = try? JSONDecoder().decode(Self.self, from: data) else { throw InviteError.malformed }
        let invite = try envelope.verified(as: Invitation.self)
        guard invite.version == 1, invite.peer.publicKey == envelope.signer,
              invite.nonce.count >= 24, !invite.peer.name.isEmpty, invite.peer.name.count <= 60 else { throw InviteError.malformed }
        guard invite.expires > now, invite.expires < now.addingTimeInterval(901) else { throw InviteError.expired }
        return (envelope, invite)
    }
}

public final class Identity {
    private let key: Curve25519.Signing.PrivateKey
    public let createdDevelopmentIdentity: Bool
    public static var usesDevelopmentFile: Bool {
        #if DEBUG || SOUNDBOUND_DEVELOPMENT
        true
        #else
        false
        #endif
    }
    public static var developmentFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soundbound/Development/identity.json")
    }
    public var publicKey: String { key.publicKey.rawRepresentation.url64 }
    public var id: String { Self.fingerprint(publicKey) }
    public static func fingerprint(_ publicKey: String) -> String {
        SHA256.hash(data: Data(publicKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public init(ephemeral: Bool = false) throws {
        if ephemeral { key = Curve25519.Signing.PrivateKey(); createdDevelopmentIdentity = false; return }
        #if DEBUG || SOUNDBOUND_DEVELOPMENT
        let stored = try DevelopmentIdentityStore.loadOrCreate(at: Self.developmentFile)
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: stored.data)
        createdDevelopmentIdentity = stored.created
        #else
        createdDevelopmentIdentity = false
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.soundbound.device-identity", kSecAttrAccount as String: "signing-key",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        } else if status == errSecItemNotFound {
            let generated = Curve25519.Signing.PrivateKey()
            let save: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "app.soundbound.device-identity", kSecAttrAccount as String: "signing-key",
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData as String: generated.rawRepresentation]
            guard SecItemAdd(save as CFDictionary, nil) == errSecSuccess else { throw InviteError.unavailable }
            key = generated
        } else { throw InviteError.unavailable }
        #endif
    }
    init(developmentFile: URL) throws {
        let stored = try DevelopmentIdentityStore.loadOrCreate(at: developmentFile)
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: stored.data)
        createdDevelopmentIdentity = stored.created
    }
    public func sign<T: Encodable>(_ value: T) throws -> SignedEnvelope {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return SignedEnvelope(payload: data.url64, signature: try key.signature(for: data).url64, signer: publicKey)
    }
}

/// Development only storage. Never fall back to a replacement identity if a
/// file is corrupt: signatures and paired peers must keep a stable identity.
enum DevelopmentIdentityStore {
    private struct Record: Codable { var version: Int; var privateKey: Data }
    static func loadOrCreate(at url: URL) throws -> (data: Data, created: Bool) {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else { throw InviteError.unavailable }
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        var backupURL = directory; try? backupURL.setResourceValues(resource)
        let lock = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw InviteError.unavailable }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw InviteError.unavailable }
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 4096 else { throw InviteError.unavailable }
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
            guard record.version == 1 else { throw InviteError.unavailable }
            _ = try Curve25519.Signing.PrivateKey(rawRepresentation: record.privateKey)
            guard chmod(url.path, 0o600) == 0 else { throw InviteError.unavailable }
            return (record.privateKey, false)
        }
        guard errno == ENOENT else { throw InviteError.unavailable }
        let key = Curve25519.Signing.PrivateKey().rawRepresentation
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Record(version: 1, privateKey: key))
        let temporary = directory.appendingPathComponent(".identity-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw InviteError.unavailable }
        defer { close(fd); try? manager.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw InviteError.unavailable }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw InviteError.unavailable }
        return (key, true)
    }
}
