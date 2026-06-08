import AVFoundation
@testable import Meeting2Core
import XCTest

final class MeetingStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meeting2CoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testScanSkipsFolderWithUnreadableMetadata() async throws {
        let good = root.appendingPathComponent("2026-06-05 12-00-00 — Good")
        let bad = root.appendingPathComponent("2026-06-05 12-01-00 — Bad")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)

        let store = MeetingStore(root: root)
        _ = try await store.markRecordingStarted(folder: good, startedAt: Date(timeIntervalSince1970: 0))
        // A corrupt meeting.json must not abort the whole sweep — the good folder still scans.
        FileManager.default.createFile(
            atPath: bad.appendingPathComponent("meeting.json").path,
            contents: Data("{ not valid json".utf8)
        )

        let names = try await store.scan().map { $0.folder.lastPathComponent }
        XCTAssertTrue(names.contains("2026-06-05 12-00-00 — Good"))
        XCTAssertFalse(names.contains("2026-06-05 12-01-00 — Bad"))
    }

    func testSetDisplayNameUpdatesMetadataOnly() async throws {
        let folder = root.appendingPathComponent("2026-06-05 12-00-00 — Old Name")
        let store = MeetingStore(root: root)
        _ = try await store.markRecordingStarted(folder: folder, startedAt: Date(timeIntervalSince1970: 0))

        try await store.setDisplayName(folder: folder, "New Name")

        let metadata = try AtomicJSON.read(MeetingMetadata.self, from: MeetingStore.metadataURL(in: folder))
        XCTAssertEqual(metadata.displayName, "New Name")
        // The folder itself is untouched (only the JSON changed).
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testClearTranscriptRemovesFilesAndResetsStatus() async throws {
        let folder = root.appendingPathComponent("2026-06-05 12-00-00 — Done")
        let store = MeetingStore(root: root)
        _ = try await store.markRecordingStarted(folder: folder, startedAt: Date(timeIntervalSince1970: 0))
        _ = try await store.markTranscriptionCompleted(folder: folder)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("transcript.json").path, contents: Data("{}".utf8))
        FileManager.default.createFile(atPath: folder.appendingPathComponent("transcript.md").path, contents: Data("# t".utf8))

        try await store.clearTranscript(folder: folder)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.md").path))
        let metadata = try AtomicJSON.read(MeetingMetadata.self, from: MeetingStore.metadataURL(in: folder))
        XCTAssertEqual(metadata.jobs.transcription.status, .pending)
        XCTAssertNil(metadata.jobs.transcription.lastError)
    }

    func testReconcileHealsStaleTranscriptionStatusWhenTranscriptExists() async throws {
        let folder = root.appendingPathComponent("2026-06-05 16-00-00 — Heal")
        let store = MeetingStore(root: root)

        _ = try await store.markRecordingStarted(folder: folder, startedAt: Date(timeIntervalSince1970: 0))
        _ = try await store.markTranscriptionRunning(folder: folder)
        // A crash between writing the transcript and marking the job leaves a transcript on
        // disk but status stuck at .running.
        FileManager.default.createFile(
            atPath: folder.appendingPathComponent("transcript.json").path,
            contents: Data("{}".utf8)
        )

        await store.reconcileTranscriptionJobStatus()

        let metadata = try AtomicJSON.read(MeetingMetadata.self, from: MeetingStore.metadataURL(in: folder))
        XCTAssertEqual(metadata.jobs.transcription.status, .done)
        XCTAssertNil(metadata.jobs.transcription.lastError)
    }

    func testMarkRecordingStartedUsesTimestampPrefixAsStableID() async throws {
        let folder = root.appendingPathComponent("2026-06-05 12-00-00 — Weekly Sync")
        let store = MeetingStore(root: root)

        let metadata = try await store.markRecordingStarted(
            folder: folder,
            startedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(metadata.id, "2026-06-05 12-00-00")
        XCTAssertEqual(metadata.displayName, "Recording 2026-06-05 12-00-00")
    }

    func testRecoveryContinuesAfterBadInterruptedFolder() async throws {
        let bad = root.appendingPathComponent("2026-06-05 12-00-00 — Bad")
        let good = root.appendingPathComponent("2026-06-05 12-01-00 — Good")
        let store = MeetingStore(root: root)

        _ = try await store.markRecordingStarted(folder: bad, startedAt: Date(timeIntervalSince1970: 0))
        _ = try await store.markRecordingStarted(folder: good, startedAt: Date(timeIntervalSince1970: 60))

        FileManager.default.createFile(atPath: bad.appendingPathComponent("mic.caf").path, contents: Data())
        FileManager.default.createFile(atPath: bad.appendingPathComponent("system.caf").path, contents: Data())
        try writeCAF(good.appendingPathComponent("mic.caf"))
        try writeCAF(good.appendingPathComponent("system.caf"))

        let results = try await store.recoverInterruptedRecordings(now: Date(timeIntervalSince1970: 120))
        let byFolder = Dictionary(uniqueKeysWithValues: results.map { ($0.folder.lastPathComponent, $0) })

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(byFolder[bad.lastPathComponent]?.didRecover, false)
        XCTAssertTrue(byFolder[bad.lastPathComponent]?.message.contains("Recovery failed") ?? false)
        XCTAssertEqual(byFolder[good.lastPathComponent]?.didRecover, true)

        let snapshots = try await store.scan()
        let states = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.folder.lastPathComponent, $0.state) })
        XCTAssertEqual(states[bad.lastPathComponent], .interrupted)
        XCTAssertEqual(states[good.lastPathComponent], .recorded)
    }

    func testScanDerivesSimpleFileStates() async throws {
        let interrupted = root.appendingPathComponent("interrupted")
        let compressed = root.appendingPathComponent("compressed")
        let partial = root.appendingPathComponent("partial")
        let transcribed = root.appendingPathComponent("transcribed")

        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: compressed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transcribed, withIntermediateDirectories: true)

        FileManager.default.createFile(atPath: interrupted.appendingPathComponent("mic.caf").path, contents: Data())
        FileManager.default.createFile(atPath: interrupted.appendingPathComponent("system.caf").path, contents: Data())
        FileManager.default.createFile(atPath: compressed.appendingPathComponent("audio.m4a").path, contents: Data())
        FileManager.default.createFile(atPath: partial.appendingPathComponent("mic.caf").path, contents: Data())
        FileManager.default.createFile(atPath: transcribed.appendingPathComponent("transcript.json").path, contents: Data())

        let store = MeetingStore(root: root)
        let states = try await Dictionary(
            uniqueKeysWithValues: store.scan().map { ($0.folder.lastPathComponent, $0.state) }
        )

        XCTAssertEqual(states["interrupted"], .interrupted)
        XCTAssertEqual(states["compressed"], .recorded)
        XCTAssertEqual(states["partial"], .incomplete)
        XCTAssertEqual(states["transcribed"], .transcribed)
    }

    private func writeCAF(_ url: URL) throws {
        let format = AudioFormat.pcmFormat
        let file = try AVAudioFile(
            forWriting: url,
            settings: AudioFormat.cafSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let frameCount: AVAudioFrameCount = 4_800
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?.pointee else {
            XCTFail("Could not allocate CAF test buffer")
            return
        }

        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            channel[frame] = sin(Float(frame) / 24)
        }

        try file.write(from: buffer)
    }
}
