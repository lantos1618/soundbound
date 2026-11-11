import XCTest
@testable import SoundboundKit

final class AppleWebCallbackTests: XCTestCase {
    private let state = "expected-state"
    private let code = "abcdefghijklmnop1234567890"

    func testAcceptsBoundedRedemptionForThisAttempt() {
        XCTAssertEqual(AppleWebCallback.parse(URL(string: "soundbound://auth?state=\(state)&code=\(code)"), expectedState: state), .success(code))
    }
    func testRejectsWrongStateDuplicateFieldsAndOtherCallbackTargets() {
        for url in ["soundbound://auth?state=wrong&code=\(code)",
                    "soundbound://auth?state=\(state)&state=\(state)&code=\(code)",
                    "soundbound://auth?state=\(state)&code=\(code)&code=\(code)",
                    "https://auth?state=\(state)&code=\(code)",
                    "soundbound://auth/other?state=\(state)&code=\(code)",
                    "soundbound://auth?state=\(state)&code=\(code)&error=cancelled"] {
            XCTAssertEqual(AppleWebCallback.parse(URL(string: url), expectedState: state), .failure(.invalidResponse))
        }
    }
    func testReportsOnlyKnownSanitizedFailureReasons() {
        XCTAssertEqual(AppleWebCallback.parse(URL(string: "soundbound://auth?state=\(state)&error=exchange_failed"), expectedState: state), .failure(.exchange))
        XCTAssertEqual(AppleWebCallback.parse(URL(string: "soundbound://auth?state=wrong&error=configuration_failed"), expectedState: state), .failure(.invalidResponse))
        XCTAssertEqual(AppleWebCallback.parse(URL(string: "soundbound://auth?state=\(state)&error=secret-text"), expectedState: state), .failure(.invalidResponse))
    }
}
