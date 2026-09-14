@testable import Meeting2
import XCTest

/// Tests use seconds on an artificial monotonic clock: long silence and owner grace behavior
/// must be reproducible without waiting, playing audio, or coupling assertions to timer ticks.
final class AutoRecordPolicyTests: XCTestCase {
    func testIgnoredOwnerCannotTriggerOrKeepRecordingAlive() {
        var policy = AutoRecordPolicy()
        XCTAssertEqual(policy.evaluate(owners: ["dictation"], eligible: [], canStart: true, detectedAt: nil, now: 0), .none)
        XCTAssertEqual(policy.evaluate(owners: ["dictation", "zoom"], eligible: ["zoom"], canStart: true, detectedAt: nil, now: 1), .start("zoom"))
        XCTAssertEqual(policy.evaluate(owners: ["dictation"], eligible: [], canStart: false, detectedAt: 1, now: 61), .none)
        XCTAssertEqual(policy.evaluate(owners: ["dictation"], eligible: [], canStart: false, detectedAt: 1, now: 81), .stop(ownerActiveSeconds: 60))
    }

    func testUnknownIntervalDoesNotCountTowardStop() {
        var policy = AutoRecordPolicy()
        _ = policy.evaluate(owners: [], eligible: [], canStart: false, detectedAt: 0, now: 50)
        _ = policy.evaluate(owners: nil, eligible: [], canStart: false, detectedAt: 0, now: 65)
        XCTAssertEqual(policy.evaluate(owners: [], eligible: [], canStart: false, detectedAt: 0, now: 100), .none)
        XCTAssertEqual(policy.evaluate(owners: [], eligible: [], canStart: false, detectedAt: 0, now: 120), .stop(ownerActiveSeconds: 100))
    }

    func testStoppedOwnersDoNotBlockNewAppsOrWaitForIgnoredServiceToLeave() {
        var policy = AutoRecordPolicy()
        policy.restrict(["zoom"])
        XCTAssertEqual(policy.evaluate(owners: ["zoom", "dictation"], eligible: ["zoom"], canStart: true, detectedAt: nil, now: 0), .none)
        XCTAssertEqual(policy.evaluate(owners: ["zoom", "meet", "dictation"], eligible: ["zoom", "meet"], canStart: true, detectedAt: nil, now: 1), .start("meet"))
        _ = policy.evaluate(owners: ["dictation"], eligible: [], canStart: true, detectedAt: nil, now: 5)
        _ = policy.evaluate(owners: ["dictation"], eligible: [], canStart: true, detectedAt: nil, now: 25)
        XCTAssertEqual(policy.evaluate(owners: ["dictation", "zoom"], eligible: ["zoom"], canStart: true, detectedAt: nil, now: 26), .start("zoom"))
    }

    func testUnknownResetsReleaseTimerButKeepsRestriction() {
        var policy = AutoRecordPolicy()
        policy.restrict(["zoom"])
        _ = policy.evaluate(owners: [], eligible: [], canStart: true, detectedAt: nil, now: 0)
        _ = policy.evaluate(owners: nil, eligible: [], canStart: true, detectedAt: nil, now: 10)
        _ = policy.evaluate(owners: [], eligible: [], canStart: true, detectedAt: nil, now: 100)
        XCTAssertEqual(policy.restrictedOwners, ["zoom"])
        XCTAssertEqual(policy.evaluate(owners: ["zoom"], eligible: ["zoom"], canStart: true, detectedAt: nil, now: 101), .none)
    }

    func testDisablingRestrictedOwnerDoesNotPretendItReleasedMic() {
        var policy = AutoRecordPolicy()
        policy.restrict(["zoom"])
        _ = policy.evaluate(owners: ["zoom"], eligible: [], canStart: true, detectedAt: nil, now: 0)
        _ = policy.evaluate(owners: ["zoom"], eligible: [], canStart: true, detectedAt: nil, now: 60)
        XCTAssertEqual(policy.evaluate(owners: ["zoom"], eligible: ["zoom"], canStart: true, detectedAt: nil, now: 61), .none)
    }

    func testUnknownNeverStartsAndManualRecordingNeverAutoStops() {
        var policy = AutoRecordPolicy()
        XCTAssertEqual(policy.evaluate(owners: nil, eligible: ["zoom"], canStart: true, detectedAt: nil, now: 0), .none)
        _ = policy.evaluate(owners: [], eligible: [], canStart: false, detectedAt: nil, now: 0)
        XCTAssertEqual(policy.evaluate(owners: [], eligible: [], canStart: false, detectedAt: nil, now: 100), .none)
    }

    func testUnknownStopWaitsForConfirmedQuietWithoutRestrictingLaterAppIdentity() {
        var policy = AutoRecordPolicy()
        policy.restrict(nil)
        XCTAssertEqual(policy.evaluate(owners: ["zoom"], eligible: ["zoom"], canStart: true, detectedAt: nil, now: 1), .none)
        XCTAssertTrue(policy.restrictedOwners.isEmpty)
        _ = policy.evaluate(owners: [], eligible: [], canStart: true, detectedAt: nil, now: 2)
        _ = policy.evaluate(owners: nil, eligible: [], canStart: true, detectedAt: nil, now: 10)
        _ = policy.evaluate(owners: [], eligible: [], canStart: true, detectedAt: nil, now: 100)
        _ = policy.evaluate(owners: [], eligible: [], canStart: true, detectedAt: nil, now: 120)
        XCTAssertEqual(policy.evaluate(owners: ["zoom"], eligible: ["zoom"], canStart: true, detectedAt: nil, now: 121), .start("zoom"))
    }

    func testLaterIdentifiedStopReplacesTheUnknownGlobalRestriction() {
        var policy = AutoRecordPolicy()
        policy.restrict(nil)
        // The user manually starts again, then stops with a complete owner snapshot. That newer
        // intent has a known scope; retaining the global hold would block unrelated new calls.
        policy.restrict(["zoom"])
        XCTAssertEqual(policy.evaluate(owners: ["zoom"], eligible: ["zoom"], canStart: true, detectedAt: nil, now: 1), .none)
        XCTAssertEqual(policy.evaluate(owners: ["zoom", "meet"], eligible: ["zoom", "meet"], canStart: true, detectedAt: nil, now: 2), .start("meet"))
    }

    func testNudgeResetForSettingsDoesNotAnnounceCallEnd() {
        var nudge = CallOwnerNudge()
        XCTAssertFalse(nudge.observe(["zoom"], now: 0))
        nudge = CallOwnerNudge()
        XCTAssertFalse(nudge.observe([], now: 5))
        XCTAssertFalse(nudge.observe([], now: 10))
        XCTAssertFalse(nudge.observe(["zoom"], now: 11))
        XCTAssertFalse(nudge.observe([], now: 12))
        XCTAssertTrue(nudge.observe([], now: 15))
        XCTAssertFalse(nudge.observe([], now: 20))
    }

    func testNudgeRequiresFreshGraceAfterUnknownRead() {
        var nudge = CallOwnerNudge()
        _ = nudge.observe(["zoom"], now: 0)
        _ = nudge.observe([], now: 1)
        _ = nudge.observe(nil, now: 2)
        XCTAssertFalse(nudge.observe([], now: 10))
        XCTAssertTrue(nudge.observe([], now: 13))
    }
}
