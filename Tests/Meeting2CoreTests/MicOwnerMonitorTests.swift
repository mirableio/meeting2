@testable import Meeting2Core
import CoreAudio
import XCTest

/// Exercise enumeration failures as evidence failures, not simulated silence. These reads are
/// injected at HAL boundaries so the suite does not depend on microphone permissions or devices.
final class MicOwnerMonitorTests: XCTestCase {
    private enum Failure: Error { case unavailable }

    func testCompleteEmptyReadIsDifferentFromFailure() {
        let empty = MicOwnerMonitor.readExternalOwners(listProcesses: { [] }, readProcess: { _ in nil })
        XCTAssertEqual(empty, [])
        XCTAssertNil(MicOwnerMonitor.readExternalOwners(
            listProcesses: { throw Failure.unavailable }, readProcess: { _ in nil }
        ))
    }

    func testFailedPropertyInvalidatesPartialOwnerSet() {
        let result = MicOwnerMonitor.readExternalOwners(listProcesses: { [1, 2] }) { id in
            if id == 2 { throw Failure.unavailable }
            return MicOwner(bundleID: "us.zoom.xos", pid: 123)
        }
        XCTAssertNil(result)
    }

    func testExcludesBothCurrentPIDAndAnotherMeeting2Instance() {
        let candidates = [
            MicOwner(bundleID: "test.runner", pid: getpid()),
            MicOwner(bundleID: MicOwnerMonitor.meeting2BundleID, pid: -20),
            MicOwner(bundleID: "us.zoom.xos", pid: -21)
        ]
        let result = MicOwnerMonitor.readExternalOwners(listProcesses: { [0, 1, 2] }) {
            candidates[Int($0)]
        }
        XCTAssertEqual(result, [candidates[2]])
    }

    func testInactiveAndSuccessfullyUnidentifiedProcessesAreIgnored() {
        XCTAssertEqual(MicOwnerMonitor.readExternalOwners(listProcesses: { [1] }, readProcess: { _ in nil }), [])
        XCTAssertEqual(MicOwnerMonitor.readExternalOwners(listProcesses: { [1] }) { _ in
            MicOwner(bundleID: "", pid: -21)
        }, [])
    }

    func testEmptyIdentityDoesNotDiscardIdentifiedOwnersOrBareNames() {
        let candidates = [
            MicOwner(bundleID: "us.zoom.xos", pid: -21),
            MicOwner(bundleID: "", pid: -22),
            MicOwner(bundleID: "systemsoundserverd", pid: -23)
        ]
        let result = MicOwnerMonitor.readExternalOwners(listProcesses: { [0, 1, 2] }) {
            candidates[Int($0)]
        }
        XCTAssertEqual(result, [candidates[0], candidates[2]])
    }
}
