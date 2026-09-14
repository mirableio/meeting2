@testable import Meeting2
import Meeting2Core
import XCTest

/// The real controller awaits a controllable read and drives a recording-command fake. This
/// catches stale callbacks across session boundaries that a pure policy test cannot exercise.
@MainActor
final class AutoRecordControllerTests: XCTestCase {
    private let zoom = MicOwner(bundleID: "us.zoom.xos", pid: -10)

    private func preferences() -> AutoRecordPreferences {
        let suite = "Meeting2Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = AutoRecordPreferences(defaults: defaults, resolveName: { _ in nil })
        preferences.setEnabled(true)
        return preferences
    }

    func testIdlePollFindsNewOwnerWithoutDeviceWake() async {
        let preferences = preferences()
        let commands = RecordingCommandsFake()
        var owners = [MicOwner(bundleID: "com.apple.CoreSpeech", pid: -11)]
        var time = 0.0
        let detector = AutoRecordController(controller: commands, preferences: preferences, readOwners: { owners }, now: { time })
        await detector.checkOwners()
        XCTAssertEqual(commands.starts, 0)
        XCTAssertEqual(preferences.apps.count, 1)
        owners.append(zoom)
        await detector.checkOwners()
        XCTAssertEqual(commands.starts, 1)
        XCTAssertEqual(detector.disableTarget?.bundleID, zoom.bundleID)
        await detector.checkOwners()
        XCTAssertEqual(detector.disableTarget?.bundleID, zoom.bundleID, "Keep the action during the discovery recording")

        owners = []
        time = 60
        await detector.checkOwners()
        time = 80
        await detector.checkOwners()
        owners = [zoom]
        time = 90
        await detector.checkOwners()
        XCTAssertEqual(commands.starts, 2)
        XCTAssertNil(detector.disableTarget, "Known apps must not clutter later recording menus")
    }

    func testEveryProtectiveStopBlocksRestartOfSameOwner() async {
        for reason in RecordingStopReason.allCases where reason.restrictsRestart {
            let preferences = preferences()
            let commands = RecordingCommandsFake()
            let detector = AutoRecordController(controller: commands, preferences: preferences, readOwners: { [self.zoom] })
            await detector.checkOwners()
            detector.recordingWillStop(folder: commands.currentFolder!, reason: reason)
            commands.finishStop()
            await detector.checkOwners()
            XCTAssertEqual(commands.starts, 1, "Restarted after \(reason)")
        }
    }

    func testProtectiveStopOfManualRecordingAlsoBlocksRestart() async {
        let preferences = preferences()
        let commands = RecordingCommandsFake()
        commands.beginManualRecording()
        let detector = AutoRecordController(controller: commands, preferences: preferences, readOwners: { [self.zoom] })
        await detector.checkOwners()
        detector.recordingWillStop(folder: commands.currentFolder!, reason: .silenceLimit)
        commands.finishStop()
        await detector.checkOwners()
        XCTAssertEqual(commands.starts, 0)
    }

    func testManualStopBeforeFirstSuccessfulReadCannotImmediatelyRestart() async {
        let preferences = preferences()
        let commands = RecordingCommandsFake()
        commands.beginManualRecording()
        let detector = AutoRecordController(controller: commands, preferences: preferences, readOwners: { [self.zoom] })
        detector.recordingWillStop(folder: commands.currentFolder!, reason: .manual)
        commands.finishStop()
        await detector.checkOwners()
        XCTAssertEqual(commands.starts, 0)
    }

    func testManualStopCannotUseAnIdleSnapshotFromBeforeTheRecording() async {
        let preferences = preferences()
        let commands = RecordingCommandsFake()
        var owners = [MicOwner(bundleID: "com.apple.CoreSpeech", pid: -11)]
        let detector = AutoRecordController(controller: commands, preferences: preferences, readOwners: { owners })
        await detector.checkOwners()
        commands.beginManualRecording()
        detector.recordingWillStop(folder: commands.currentFolder!, reason: .manual)
        commands.finishStop()
        owners = [zoom]
        await detector.checkOwners()
        XCTAssertEqual(commands.starts, 0)
    }

    func testUnknownStopWithOnlyIgnoredOwnerHistoryCannotRestart() async {
        let preferences = preferences()
        let commands = RecordingCommandsFake()
        commands.beginManualRecording()
        var owners: [MicOwner]? = [MicOwner(bundleID: "com.apple.CoreSpeech", pid: -11)]
        let detector = AutoRecordController(controller: commands, preferences: preferences, readOwners: { owners })
        await detector.checkOwners()
        owners = nil
        await detector.checkOwners()
        detector.recordingWillStop(folder: commands.currentFolder!, reason: .manual)
        commands.finishStop()
        owners = [zoom]
        await detector.checkOwners()
        XCTAssertEqual(commands.starts, 0)
    }

    func testUnknownStopCannotAssumeLastKnownOwnersAreStillTheCompleteSet() async {
        let preferences = preferences()
        let commands = RecordingCommandsFake()
        var owners: [MicOwner]? = [zoom]
        let detector = AutoRecordController(controller: commands, preferences: preferences, readOwners: { owners })
        await detector.checkOwners()
        owners = nil
        await detector.checkOwners()
        detector.recordingWillStop(folder: commands.currentFolder!, reason: .manual)
        commands.finishStop()
        owners = [MicOwner(bundleID: "another.call", pid: -11)]
        await detector.checkOwners()
        XCTAssertEqual(commands.starts, 1, "An unknown interval cannot prove this owner appeared after Stop")
    }

    func testManualReplacementBetweenTicksCannotBeAutoStopped() async {
        let preferences = preferences()
        let commands = RecordingCommandsFake()
        var owners: [MicOwner] = [zoom]
        var time = 0.0
        let detector = AutoRecordController(controller: commands, preferences: preferences, readOwners: { owners }, now: { time })
        await detector.checkOwners()
        detector.recordingWillStop(folder: commands.currentFolder!, reason: .manual)
        commands.beginManualRecording()
        owners = []
        time = 100
        await detector.checkOwners()
        time = 200
        await detector.checkOwners()
        XCTAssertTrue(commands.stopDurations.isEmpty)
        XCTAssertEqual(commands.currentFolder?.lastPathComponent, "manual")
    }

    func testPendingReadCannotStopOrRestrictReplacementRecording() async {
        let preferences = preferences()
        let commands = RecordingCommandsFake()
        let reader = SuspendedOwnerRead(owners: [zoom])
        var time = 0.0
        let detector = AutoRecordController(controller: commands, preferences: preferences, readOwners: { await reader.read() }, now: { time })
        await detector.checkOwners()
        reader.owners = []
        time = 10
        await detector.checkOwners()
        time = 100
        let suspended = expectation(description: "Owner read suspended")
        reader.suspend = true
        reader.onSuspend = { suspended.fulfill() }
        let pending = Task { await detector.checkOwners() }
        await fulfillment(of: [suspended], timeout: 2)
        detector.recordingWillStop(folder: commands.currentFolder!, reason: .manual)
        commands.beginManualRecording()
        reader.resume([])
        await pending.value
        time = 200
        await detector.checkOwners()
        XCTAssertTrue(commands.stopDurations.isEmpty)
        XCTAssertNil(detector.disableTarget)
        XCTAssertEqual(commands.currentFolder?.lastPathComponent, "manual")
    }

    func testUnknownReadCannotPruneAndStopNeedsNewGrace() async {
        let preferences = preferences()
        let commands = RecordingCommandsFake()
        var owners: [MicOwner]? = [zoom]
        var time = 0.0
        let detector = AutoRecordController(controller: commands, preferences: preferences, readOwners: { owners }, now: { time })
        await detector.checkOwners()
        owners = []
        time = 10
        await detector.checkOwners()
        owners = nil
        time = 25
        await detector.checkOwners()
        owners = []
        time = 100
        await detector.checkOwners()
        XCTAssertTrue(commands.stopDurations.isEmpty)
        time = 120
        await detector.checkOwners()
        XCTAssertEqual(commands.stopDurations, [100])
    }

    func testStoppingDuringUnknownReadKeepsKnownOwnerRestricted() async {
        let preferences = preferences()
        let commands = RecordingCommandsFake()
        var owners: [MicOwner]? = [zoom]
        let detector = AutoRecordController(controller: commands, preferences: preferences, readOwners: { owners })
        await detector.checkOwners()
        owners = nil
        await detector.checkOwners()
        detector.recordingWillStop(folder: commands.currentFolder!, reason: .durationLimit)
        commands.finishStop()
        owners = [zoom]
        await detector.checkOwners()
        XCTAssertEqual(commands.starts, 1)
    }

    func testDisableWhileReadIsPendingPreventsStart() async {
        let preferences = preferences()
        let commands = RecordingCommandsFake()
        let reader = SuspendedOwnerRead(owners: [zoom])
        let detector = AutoRecordController(controller: commands, preferences: preferences, readOwners: { await reader.read() })
        let suspended = expectation(description: "Owner read suspended")
        reader.suspend = true
        reader.onSuspend = { suspended.fulfill() }
        let pending = Task { await detector.checkOwners() }
        await fulfillment(of: [suspended], timeout: 2)
        preferences.setEnabled(false)
        detector.disable()
        preferences.setEnabled(true)
        reader.resume([zoom])
        await pending.value
        XCTAssertEqual(commands.starts, 0)
    }

    func testFailedStartDoesNotRetryEveryPollButNewOwnerCanStart() async {
        let preferences = preferences()
        let commands = RecordingCommandsFake()
        commands.failStart = true
        var owners = [zoom]
        let detector = AutoRecordController(controller: commands, preferences: preferences, readOwners: { owners })
        await detector.checkOwners()
        await detector.checkOwners()
        XCTAssertEqual(commands.starts, 1)
        commands.failStart = false
        owners.append(MicOwner(bundleID: "com.browser", pid: -11))
        await detector.checkOwners()
        XCTAssertEqual(commands.starts, 2)
        XCTAssertNil(detector.disableTarget, "Multiple enabled owners must not produce a one-app shortcut")
    }

    func testAppPreferenceChangeStopsOnlyAutomaticRecordingAfterGrace() async {
        let preferences = preferences()
        let commands = RecordingCommandsFake()
        var time = 0.0
        let detector = AutoRecordController(controller: commands, preferences: preferences, readOwners: { [self.zoom] }, now: { time })
        await detector.checkOwners()
        preferences.setAutoRecord(false, for: zoom.bundleID)
        time = 60
        await detector.checkOwners()
        XCTAssertTrue(commands.stopDurations.isEmpty)
        XCTAssertNil(detector.disableTarget)
        time = 80
        await detector.checkOwners()
        XCTAssertEqual(commands.stopDurations, [60])
    }
}

@MainActor
private final class RecordingCommandsFake: AutoRecordingCommands {
    var canStart = true
    var canStop = false
    var currentFolder: URL?
    var starts = 0
    var failStart = false
    var stopDurations: [TimeInterval] = []

    func startRecording(source: MeetingSource, completion: ((Bool) -> Void)?) {
        starts += 1
        guard !failStart else { completion?(false); return }
        currentFolder = URL(fileURLWithPath: "/test/auto-\(starts)")
        canStart = false
        canStop = true
        completion?(true)
    }

    func stopAutoRecording(ownerActiveSeconds: TimeInterval) {
        stopDurations.append(ownerActiveSeconds)
        finishStop()
    }

    func finishStop() {
        canStart = true
        canStop = false
        currentFolder = nil
    }

    func beginManualRecording() {
        currentFolder = URL(fileURLWithPath: "/test/manual")
        canStart = false
        canStop = true
    }
}

@MainActor
private final class SuspendedOwnerRead {
    var owners: [MicOwner]?
    var suspend = false
    var onSuspend: (() -> Void)?
    private var continuation: CheckedContinuation<[MicOwner]?, Never>?

    init(owners: [MicOwner]?) { self.owners = owners }

    func read() async -> [MicOwner]? {
        guard suspend else { return owners }
        suspend = false
        return await withCheckedContinuation {
            continuation = $0
            onSuspend?()
        }
    }

    func resume(_ owners: [MicOwner]?) {
        continuation?.resume(returning: owners)
        continuation = nil
    }
}
