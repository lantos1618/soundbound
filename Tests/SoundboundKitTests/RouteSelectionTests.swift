import XCTest
import Darwin
@testable import SoundboundKit

final class RouteSelectionTests: XCTestCase {
    func testRejectsUnreliableFastRouteAndKeepsNearTie() {
        let unreliable = RouteProbeScore(host: "fast", samples: [1])
        let stable = RouteProbeScore(host: "stable", samples: [8, 9, 10])
        XCTAssertEqual(RouteProbeScore.best([unreliable, stable], current: "fast"), "stable")
        let near = RouteProbeScore(host: "current", samples: [10, 10, 10])
        XCTAssertEqual(RouteProbeScore.best([stable, near], current: "current"), "current")
        XCTAssertEqual(RouteProbeScore.best([RouteProbeScore(host: "slow", samples: [90,100,110]), stable], current: "slow"), "stable")
        XCTAssertNil(RouteProbeScore.best([unreliable], current: "fast"))
    }
    func testCandidateSetIsDeduplicatedAndBounded() {
        let endpoint = LocalEndpoint(host: "host", port: 42, alternatives: ["host"] + (0..<20).map { "address-\($0)" })
        XCTAssertEqual(endpoint.candidates.count, 8)
        XCTAssertEqual(endpoint.candidates.first, "host")
        XCTAssertEqual(Set(endpoint.candidates).count, 8)
    }
    func testAddressDecodeRejectsMalformedDataAndKeepsIPv4Literal() {
        XCTAssertNil(LocalNetwork.numericHost(Data([0,1])))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let data = withUnsafeBytes(of: &address) { Data($0) }
        XCTAssertEqual(LocalNetwork.numericHost(data), "127.0.0.1")
    }
}
