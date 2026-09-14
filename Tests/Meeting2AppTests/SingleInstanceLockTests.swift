@testable import Meeting2
import XCTest

/// Use isolated paths, not the user's real app lock. Exercise kernel ownership rather than
/// mocking a process list: an existing file is harmless, but a live competing descriptor is not.
final class SingleInstanceLockTests: XCTestCase {
    private func lockURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Meeting2LockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("instance.lock")
    }

    func testOnlyOneOwnerAndReleaseAllowsNextLaunch() throws {
        let url = try lockURL()
        var first: SingleInstanceLock? = try XCTUnwrap(SingleInstanceLock.acquire(at: url))
        try withExtendedLifetime(first) {
            XCTAssertNil(try SingleInstanceLock.acquire(at: url))
        }
        first = nil
        let next = try XCTUnwrap(SingleInstanceLock.acquire(at: url))
        try withExtendedLifetime(next) {
            XCTAssertNil(try SingleInstanceLock.acquire(at: url))
        }
    }

    func testLeftoverUnlockedFileDoesNotBlockLaunch() throws {
        let url = try lockURL()
        try Data("leftover file".utf8).write(to: url)
        let owner = try XCTUnwrap(SingleInstanceLock.acquire(at: url))
        try withExtendedLifetime(owner) {
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "leftover file")
            XCTAssertNil(try SingleInstanceLock.acquire(at: url))
        }
    }

    func testFilesystemFailureIsNotReportedAsAnotherInstance() throws {
        let file = try lockURL()
        try Data().write(to: file)
        XCTAssertThrowsError(try SingleInstanceLock.acquire(at: file.appendingPathComponent("instance.lock")))
    }
}
