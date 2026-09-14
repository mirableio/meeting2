@testable import Meeting2
import Meeting2Core
import XCTest

/// A private defaults suite proves persistence without changing the user's real auto-record
/// setting. Names are injected because discovering an app must not depend on it staying alive.
@MainActor
final class AutoRecordPreferencesTests: XCTestCase {
    func testDiscoveryDefaultsOverridesAndRelaunch() async throws {
        let suite = "Meeting2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AutoRecordPreferences(defaults: defaults, resolveName: { _ in nil })
        let siri = MicOwner(bundleID: "com.apple.CoreSpeech", pid: -10)
        let zoom = MicOwner(bundleID: "us.zoom.xos", pid: -11)
        XCTAssertEqual(preferences.observe([siri, zoom, zoom]), Set([siri.bundleID, zoom.bundleID]))
        XCTAssertEqual(preferences.apps.count, 2)
        XCTAssertFalse(preferences.enabled)
        XCTAssertFalse(preferences.allows(siri.bundleID))
        XCTAssertTrue(preferences.allows(zoom.bundleID))
        preferences.setAutoRecord(true, for: siri.bundleID)
        preferences.setAutoRecord(false, for: zoom.bundleID)
        preferences.setEnabled(true)
        let reopened = AutoRecordPreferences(defaults: defaults)
        XCTAssertTrue(reopened.enabled)
        XCTAssertTrue(reopened.allows(siri.bundleID))
        XCTAssertFalse(reopened.allows(zoom.bundleID))
        XCTAssertTrue(reopened.observe([siri, zoom]).isEmpty, "Relaunching must not rediscover known apps")
        XCTAssertEqual(reopened.apps.count, 2)
        XCTAssertTrue(reopened.allows(siri.bundleID))
    }

    func testLastKnownNameAndSearchSurviveProcessExit() async throws {
        let suite = "Meeting2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var name: String? = "Zoom Workplace"
        let preferences = AutoRecordPreferences(defaults: defaults, resolveName: { _ in name })
        let owner = MicOwner(bundleID: "us.zoom.xos", pid: -10)
        preferences.observe([owner])
        name = nil
        preferences.observe([MicOwner(bundleID: owner.bundleID, pid: -11)])
        XCTAssertEqual(preferences.name(for: owner.bundleID), "Zoom Workplace")
        XCTAssertEqual(preferences.matching(" WORKPLACE ").count, 1)
        XCTAssertEqual(preferences.matching("US.ZOOM").count, 1)
        XCTAssertTrue(preferences.matching("dictation").isEmpty)
        XCTAssertEqual(AutoRecordPreferences(defaults: defaults).apps, preferences.apps)
    }

    func testDiscoveryDoesNotOverwriteChoicesOrEmitRuleChanges() async throws {
        let suite = "Meeting2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AutoRecordPreferences(defaults: defaults, resolveName: { _ in nil })
        var changes = 0
        preferences.onRulesChanged = { changes += 1 }
        let owner = MicOwner(bundleID: "dictation", pid: -10)
        preferences.observe([owner])
        XCTAssertEqual(changes, 0)
        preferences.setAutoRecord(false, for: owner.bundleID)
        preferences.observe([owner])
        preferences.setAutoRecord(false, for: owner.bundleID)
        XCTAssertEqual(changes, 1)
        XCTAssertFalse(preferences.enabled)
        XCTAssertFalse(preferences.allows(owner.bundleID))
    }

    func testSelfExclusionAndHelperIdentitiesAreExact() async throws {
        let suite = "Meeting2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AutoRecordPreferences(defaults: defaults, resolveName: { _ in "Shared name" })
        preferences.observe([
            MicOwner(bundleID: "test.runner", pid: getpid()),
            MicOwner(bundleID: MicOwnerMonitor.meeting2BundleID, pid: -10),
            MicOwner(bundleID: "com.browser", pid: -11),
            MicOwner(bundleID: "com.browser.helper", pid: -12)
        ])
        XCTAssertEqual(preferences.apps.count, 2)
        preferences.setAutoRecord(false, for: "com.browser.helper")
        XCTAssertTrue(preferences.allows("com.browser"))
        XCTAssertFalse(preferences.allows("com.browser.helper"))
        XCTAssertFalse(preferences.allows(MicOwnerMonitor.meeting2BundleID))
    }
}
