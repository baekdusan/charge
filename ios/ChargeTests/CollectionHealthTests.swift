import XCTest
@testable import Charge

final class CollectionHealthTests: XCTestCase {
    private let firstAttempt: TimeInterval = 1_789_344_000

    private func issue(_ status: String) -> CollectorDevice.CollectIssue {
        .init(providerId: "claude", providerName: "Claude", status: status)
    }

    func testRecoverySuggestionRequiresBothAttemptsAndTime() {
        let last = Date(timeIntervalSince1970: firstAttempt + 20 * 60)
        XCTAssertFalse(issue("error;failures=4;since=\(Int(firstAttempt))").isPersistent(lastAttempt: last))
        let fifth = issue("auth_expired;failures=5;since=\(Int(firstAttempt))")
        XCTAssertFalse(fifth.isPersistent(lastAttempt: last.addingTimeInterval(-1)))
        XCTAssertTrue(fifth.isPersistent(lastAttempt: last))
        XCTAssertFalse(fifth.isPersistent(lastAttempt: nil))
        XCTAssertFalse(issue("error").isPersistent(lastAttempt: last))
        XCTAssertFalse(issue("error;failures=5;since=nan").isPersistent(lastAttempt: last))
        XCTAssertFalse(issue("error;failures=5;since=-1").isPersistent(lastAttempt: last))
    }

    func testErrorCausesRemainDistinctFromSubscriptionCancellation() {
        XCTAssertTrue(issue("error:rate_limited;failures=5").isRateLimited)
        XCTAssertFalse(issue("error:rate_limited;failures=5").isAccessDenied)
        XCTAssertFalse(issue("error:rate_limited;failures=5").isAuthExpired)
        XCTAssertTrue(issue("error:credentials_missing;failures=1").needsSetup)
        XCTAssertTrue(issue("error:credentials_missing:signed_out;failures=1").needsSetup)
        XCTAssertTrue(issue("error:credentials_missing:signed_out;failures=1").isSignedOut)
        XCTAssertFalse(issue("error:credentials_missing:signed_out;failures=1").isAuthExpired)
        XCTAssertTrue(issue("error:access_denied;failures=5").isAccessDenied)
    }

    func testHiddenProvidersDoNotLeaveDeviceWarnings() {
        let device = CollectorDevice(id: "test", label: nil, lastSeenAt: nil,
                                     collectStatus: ["claude": "auth_expired;failures=5", "codex": "error", "gemini": "ok"])
        XCTAssertEqual(device.visibleCollectIssues(hidden: ["claude"]).map(\.providerId), ["codex"])
        XCTAssertTrue(device.visibleCollectIssues(hidden: ["claude", "codex"]).isEmpty)
        XCTAssertEqual(device.visibleCollectIssues(hidden: []).count, 2)
    }
}
