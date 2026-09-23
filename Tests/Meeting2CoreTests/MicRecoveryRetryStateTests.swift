@testable import Meeting2Core
import XCTest

/// HAL startup failures are hard to force without audio hardware. These tests pin
/// the retry budget; the input-switch smoke test covers successful engine recovery.
final class MicRecoveryRetryStateTests: XCTestCase {
    func testNotificationsCoalesceIntoBoundedSettlingAttempts() {
        var state = MicRecoveryRetryState()

        XCTAssertTrue(state.mayAttempt(isScheduledRetry: false, now: 100))
        XCTAssertEqual(state.attemptNumber, 1)
        XCTAssertEqual(state.failed(now: 100), 1)
        XCTAssertFalse(state.mayAttempt(isScheduledRetry: false, now: 100.5))

        XCTAssertTrue(state.mayAttempt(isScheduledRetry: true, now: 101))
        XCTAssertEqual(state.attemptNumber, 2)
        XCTAssertEqual(state.failed(now: 101), 5)
        // A device-ready notification at 3s is covered by the pending 6s attempt.
        XCTAssertFalse(state.mayAttempt(isScheduledRetry: false, now: 103))
        XCTAssertTrue(state.mayAttempt(isScheduledRetry: true, now: 106))
        XCTAssertEqual(state.attemptNumber, 3)
        XCTAssertNil(state.failed(now: 106))
        XCTAssertFalse(state.mayAttempt(isScheduledRetry: false, now: 110))
        XCTAssertTrue(state.mayAttempt(isScheduledRetry: false, now: 111))
        XCTAssertEqual(state.attemptNumber, 1)
    }

    func testStopCancelsPendingRetry() {
        var state = MicRecoveryRetryState()
        XCTAssertTrue(state.mayAttempt(isScheduledRetry: false, now: 100))
        XCTAssertEqual(state.failed(now: 100), 1)

        state.reset()
        XCTAssertFalse(state.mayAttempt(isScheduledRetry: true, now: 101))
        XCTAssertTrue(state.mayAttempt(isScheduledRetry: false, now: 101))
    }
}
