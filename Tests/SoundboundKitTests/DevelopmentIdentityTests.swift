import XCTest
@testable import SoundboundKit

final class DevelopmentIdentityTests: XCTestCase {
    private func withFile(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("identity.json"))
    }
    func testReopeningKeepsIdentityAndSignatures() throws {
        try withFile { file in
            let first = try Identity(developmentFile: file)
            let second = try Identity(developmentFile: file)
            XCTAssertEqual(first.id, second.id)
            XCTAssertTrue(first.createdDevelopmentIdentity)
            XCTAssertFalse(second.createdDevelopmentIdentity)
            let signed = try second.sign(["message": "hello"])
            XCTAssertEqual(try signed.verified(as: [String: String].self), ["message": "hello"])
        }
    }
    func testFileAndDirectoryAreOwnerOnly() throws {
        try withFile { file in
            _ = try Identity(developmentFile: file)
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            let directory = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
    }
    func testCorruptFileIsNotReplacedWithNewIdentity() throws {
        try withFile { file in
            _ = try Identity(developmentFile: file)
            let invalid = Data("broken json".utf8)
            try invalid.write(to: file)
            XCTAssertThrowsError(try Identity(developmentFile: file))
            XCTAssertEqual(try Data(contentsOf: file), invalid)
        }
    }
    func testSymbolicLinkIsRejected() throws {
        try withFile { file in
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let target = file.deletingLastPathComponent().appendingPathComponent("target.json")
            try Data("unchanged".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            XCTAssertThrowsError(try Identity(developmentFile: file))
            XCTAssertEqual(try String(contentsOf: target), "unchanged")
        }
    }
}
