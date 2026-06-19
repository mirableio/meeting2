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

        // Each raw track is retained as a compact per-track m4a (the precaution): the CAFs
        // are gone but the individual tracks remain recoverable.
        let micM4A = folder.appendingPathComponent("mic.m4a")
        let systemM4A = folder.appendingPathComponent("system.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: micM4A.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemM4A.path))
        XCTAssertGreaterThan(try AVAudioFile(forReading: micM4A).length, 0)

        let metadata = try AtomicJSON.read(MeetingMetadata.self, from: MeetingStore.metadataURL(in: folder))
        XCTAssertEqual(metadata.tracks.mic.file, "mic.m4a")
        XCTAssertEqual(metadata.tracks.system.file, "system.m4a")

        let pendingAgain = try await job.runPending(in: store)
        XCTAssertTrue(pendingAgain.results.isEmpty)
        XCTAssertTrue(pendingAgain.failures.isEmpty)
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
        // Even on the heal path (audio.m4a already present), per-track retention still runs.
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("system.m4a").path))
        let after = try AtomicJSON.read(MeetingMetadata.self, from: MeetingStore.metadataURL(in: folder))
        XCTAssertEqual(after.tracks.mic.file, "mic.m4a")
        XCTAssertEqual(after.tracks.system.file, "system.m4a")
    }

    func testLoudspeakerRecordingBuildsMicOnlyCombinedFileButKeepsSystemTrack() async throws {
        // A recording made on the built-in speakers: the combined audio.m4a must be built
        // from the mic alone (no system channel, so no echo), while the raw system audio is
        // still retained separately as system.m4a.
        let folder = root.appendingPathComponent("2026-06-09 14-00-00 — Loudspeaker")
        let store = MeetingStore(root: root)
        let job = CompressionJob()

        _ = try await store.markRecordingStarted(
            folder: folder,
            startedAt: Date(timeIntervalSince1970: 0),
            outputRoute: OutputRoute(transport: "BuiltIn", isLoudspeaker: true)
        )
        // Mic and system carry clearly different tones so we can tell whether the system
        // channel leaked into the combined file.
        try writeCAF(folder.appendingPathComponent("mic.caf"), divisor: 24)
        try writeCAF(folder.appendingPathComponent("system.caf"), divisor: 7)
        _ = try await store.finalizeCompletedRecording(folder: folder, stats: nil)

        let result = try await job.perform(folder: folder, store: store)
        XCTAssertEqual(result.status, .compressed)

        // system.m4a is preserved (precaution); audio.m4a is the mic on both channels.
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("system.m4a").path))
        let (left, right) = try decodeStereo(folder.appendingPathComponent("audio.m4a"))
        let n = min(left.count, right.count)
        XCTAssertGreaterThan(n, 0)
        // Mic-on-both-channels ⇒ the two channels are identical (centered mono).
        var maxDelta: Float = 0
        for i in 0..<n { maxDelta = max(maxDelta, abs(left[i] - right[i])) }
        XCTAssertLessThan(maxDelta, 0.02, "mic-only output channels differ (system leaked?)")
    }

    func testRunPendingIsolatesPerItemFailure() async throws {
        let store = MeetingStore(root: root)
        let job = CompressionJob()

        // Good recording with valid CAFs.
        let good = root.appendingPathComponent("2026-06-05 12-00-00 — Good")
        _ = try await store.markRecordingStarted(folder: good, startedAt: Date(timeIntervalSince1970: 0))
        try writeCAF(good.appendingPathComponent("mic.caf"))
        try writeCAF(good.appendingPathComponent("system.caf"))
        _ = try await store.finalizeCompletedRecording(folder: good, stats: nil)

        // Bad recording: finalized but with an unreadable CAF, so its compression throws.
        let bad = root.appendingPathComponent("2026-06-05 12-01-00 — Bad")
        _ = try await store.markRecordingStarted(folder: bad, startedAt: Date(timeIntervalSince1970: 60))
        try Data("not a real caf".utf8).write(to: bad.appendingPathComponent("mic.caf"))
        var badMeta = try AtomicJSON.read(MeetingMetadata.self, from: MeetingStore.metadataURL(in: bad))
        badMeta.endedAt = Date(timeIntervalSince1970: 120)
        try AtomicJSON.write(badMeta, to: MeetingStore.metadataURL(in: bad))

        let run = try await job.runPending(in: store)

        // The bad item is isolated, not fatal — the good one still compressed.
        XCTAssertEqual(run.results.count, 1)
        XCTAssertEqual(run.failures.count, 1)
        XCTAssertEqual(run.failures.first?.folder.lastPathComponent, "2026-06-05 12-01-00 — Bad")
        XCTAssertTrue(FileManager.default.fileExists(atPath: good.appendingPathComponent("audio.m4a").path))
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

    private func writeCAF(_ url: URL, divisor: Float = 24) throws {
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
            channel[frame] = sin(Float(frame) / divisor)
        }

        try file.write(from: buffer)
    }

    private func decodeStereo(_ url: URL) throws -> ([Float], [Float]) {
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw CaptureError.conversionFailed("decode buffer")
        }
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        let left = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n))
        let right = Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: n))
        return (left, right)
    }
}
