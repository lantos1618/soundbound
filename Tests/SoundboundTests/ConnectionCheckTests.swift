import XCTest
@testable import Soundbound

final class ConnectionCheckTests: XCTestCase {
    func testSelectedAndConnectedNeverConfirmsOwnership() {
        var check = ConnectionCheck()
        check.observe(currentUID: "airpods", connected: true)
        XCTAssertEqual(check.phase, .unverified)
        check.answer(heard: true, currentUID: "airpods")
        XCTAssertEqual(check.phase, .unverified)
    }
    func testCompletedTestStillRequiresUserConfirmation() {
        var check = ConnectionCheck()
        check.begin(uid: "airpods")
        check.finished()
        XCTAssertEqual(check.phase, .awaitingAnswer)
        check.answer(heard: true, currentUID: "airpods")
        XCTAssertEqual(check.phase, .confirmed)
    }
    func testFailedOrChangedRouteCannotPass() {
        var check = ConnectionCheck()
        check.begin(uid: "airpods")
        check.finished()
        check.answer(heard: false, currentUID: "airpods")
        XCTAssertEqual(check.phase, .unverified)
        check.begin(uid: "airpods")
        check.finished()
        check.answer(heard: true, currentUID: "speakers")
        XCTAssertEqual(check.phase, .unverified)
    }
    func testDisconnectInvalidatesPreviousConfirmation() {
        var check = ConnectionCheck()
        check.begin(uid: "airpods")
        check.finished()
        check.answer(heard: true, currentUID: "airpods")
        check.observe(currentUID: "airpods", connected: false)
        XCTAssertEqual(check.phase, .unverified)
        check.observe(currentUID: "airpods", connected: true)
        XCTAssertEqual(check.phase, .unverified)
    }
    func testRouteChangeDuringTestDiscardsLateCompletion() {
        var check = ConnectionCheck()
        check.begin(uid: "airpods")
        check.observe(currentUID: "speakers", connected: true)
        check.finished()
        check.answer(heard: true, currentUID: "speakers")
        XCTAssertEqual(check.phase, .unverified)
    }
}
