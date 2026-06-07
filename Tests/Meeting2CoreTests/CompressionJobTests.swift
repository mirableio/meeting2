import AVFoundation
@testable import Meeting2Core
import XCTest

final class CompressionJobTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meeting2CompressionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testCompressionMergesCAFsIntoStereoM4AAndIsIdempotent() async throws {
        let folder = root.appendingPathComponent("2026-06-05 12-00-00 — Compression")
        let store = MeetingStore(root: root)
        let job = CompressionJob()

        _ = try await store.markRecordingStarted(folder: folder, startedAt: Date(timeIntervalSince1970: 0))
        try writeCAF(folder.appendingPathComponent("mic.caf"))
        try writeCAF(folder.appendingPathComponent("system.caf"))
        _ = try await store.finalizeCompletedRecording(folder: folder, stats: nil)

        let before = try await store.scan().first { $0.folder.lastPathComponent == folder.lastPathComponent }
        XCTAssertEqual(before?.state, .recorded)
        XCTAssertTrue(before.map(job.needsWork) ?? false)

        let result = try await job.perform(folder: folder, store: store)
        XCTAssertEqual(result.status, .compressed)
        XCTAssertTrue(result.didCompress)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.caf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("system.caf").path))
        let audioURL = folder.appendingPathComponent("audio.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        // The combined file is a real, readable stereo M4A (mic left, system right).
        let audioFile = try AVAudioFile(forReading: audioURL)
        XCTAssertEqual(audioFile.processingFormat.channelCount, 2)
        XCTAssertGreaterThan(audioFile.length, 0)

        let metadata = try AtomicJSON.read(MeetingMetadata.self, from: MeetingStore.metadataURL(in: folder))
        XCTAssertEqual(metadata.tracks.mic.file, "audio.m4a")
        XCTAssertEqual(metadata.tracks.system.file, "audio.m4a")

        let pendingAgain = try await job.runPending(in: store)
        XCTAssertTrue(pendingAgain.isEmpty)
    }

    func testCompressionHealsStaleMetadataWhenCombinedFileAlreadyExists() async throws {
        // Simulates a crash mid-compress: audio.m4a was produced, but the CAFs and metadata
        // were never cleaned up, so metadata still points the tracks at the CAFs. Because the
        // CAFs are still present, `needsWork` re-triggers and a re-run must heal it.
        let folder = root.appendingPathComponent("2026-06-05 14-00-00 — Heal")
        let store = MeetingStore(root: root)
        let job = CompressionJob()

        _ = try await store.markRecordingStarted(folder: folder, startedAt: Date(timeIntervalSince1970: 0))
        try writeCAF(folder.appendingPathComponent("mic.caf"))
        try writeCAF(folder.appendingPathComponent("system.caf"))
        _ = try await store.finalizeCompletedRecording(folder: folder, stats: nil)

        try CombinedAudioBuilder().build(
            micURL: folder.appendingPathComponent("mic.caf"),
            systemURL: folder.appendingPathComponent("system.caf"),
            destinationURL: folder.appendingPathComponent("audio.m4a"),
            micOffsetSeconds: 0,
            systemOffsetSeconds: 0
        )
        let before = try AtomicJSON.read(MeetingMetadata.self, from: MeetingStore.metadataURL(in: folder))
        XCTAssertEqual(before.tracks.mic.file, "mic.caf")

        let result = try await job.perform(folder: folder, store: store)
        XCTAssertEqual(result.status, .alreadyCompressed)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.caf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("system.caf").path))
        let after = try AtomicJSON.read(MeetingMetadata.self, from: MeetingStore.metadataURL(in: folder))
        XCTAssertEqual(after.tracks.mic.file, "audio.m4a")
        XCTAssertEqual(after.tracks.system.file, "audio.m4a")
    }

    func testCombinedAudioBuilderToleratesMissingTrack() throws {
        // Defensive depth: if one source track is absent (e.g. mic permission denied so no
        // mic.caf was written), the builder still emits a stereo file with that channel
        // silent rather than failing — we never drop the audio we did capture.
        let dir = root.appendingPathComponent("builder-partial")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let systemCAF = dir.appendingPathComponent("system.caf")
        try writeCAF(systemCAF)
        let missingMicCAF = dir.appendingPathComponent("mic.caf") // never written
        let destination = dir.appendingPathComponent("audio.m4a")

        try CombinedAudioBuilder().build(
            micURL: missingMicCAF,
            systemURL: systemCAF,
            destinationURL: destination,
            micOffsetSeconds: 0,
            systemOffsetSeconds: 0
        )

        let file = try AVAudioFile(forReading: destination)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        XCTAssertGreaterThan(file.length, 0)
    }

    func testTypedUnknownObjectErrorsKeepStableDescriptions() {
        XCTAssertEqual(
            CaptureError.unknownTapObject.description,
            "Invalid state: Process tap returned unknown object ID"
        )
        XCTAssertEqual(
            CaptureError.unknownAggregateObject.description,
            "Invalid state: Aggregate device returned unknown object ID"
        )
    }

    private func writeCAF(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AudioFormat.pcmFormat
        let file = try AVAudioFile(
            forWriting: url,
            settings: AudioFormat.cafSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let frameCount: AVAudioFrameCount = 9_600
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
