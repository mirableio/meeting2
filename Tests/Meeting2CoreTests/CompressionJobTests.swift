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
        var metadata = try await store.finalizeCompletedRecording(folder: folder, stats: nil)
        metadata.tracks.mic.routeChanges = 0
        metadata.tracks.system.routeChanges = 0
        try AtomicJSON.write(metadata, to: MeetingStore.metadataURL(in: folder))

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

    func testLoudspeakerWithIncompleteMicKeepsFullSystemAudio() async throws {
        let folder = root.appendingPathComponent("2026-06-09 15-00-00 — Incomplete mic")
        let store = MeetingStore(root: root)
        _ = try await store.markRecordingStarted(
            folder: folder,
            startedAt: Date(timeIntervalSince1970: 0),
            outputRoute: OutputRoute(transport: "BuiltIn", isLoudspeaker: true)
        )
        try writeCAF(folder.appendingPathComponent("mic.caf"), frameCount: 9_600)
        try writeCAF(folder.appendingPathComponent("system.caf"), divisor: 7, frameCount: 48_000)
        var metadata = try await store.finalizeCompletedRecording(folder: folder, stats: nil)
        metadata.tracks.mic.routeChanges = 0
        metadata.tracks.system.routeChanges = 0
        metadata.tracks.system.rms = 0.7
        metadata.audioHealth.systemSilent = false
        try AtomicJSON.write(metadata, to: MeetingStore.metadataURL(in: folder))

        _ = try await CompressionJob().perform(folder: folder, store: store)

        let audioURL = folder.appendingPathComponent("audio.m4a")
        let (left, right) = try decodeStereo(audioURL)
        XCTAssertGreaterThanOrEqual(left.count, 48_000)
        XCTAssertEqual(left.count, right.count)
        // The late part of *both* channels must carry system audio. Mic-only would
        // end at 0.2 s; keeping a misaligned mic on the left would leave it empty here.
        let late = left[24_000..<40_000]
        let lateRMS = sqrt(late.reduce(Float(0)) { $0 + $1 * $1 } / Float(late.count))
        XCTAssertGreaterThan(lateRMS, 0.2)
        let maxDelta = zip(left, right).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maxDelta, 0.02)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("system.m4a").path))
    }

    func testLoudspeakerWithSilentSystemKeepsSurvivingMic() async throws {
        let folder = root.appendingPathComponent("2026-06-09 15-01-00 — Silent system")
        let store = MeetingStore(root: root)
        _ = try await store.markRecordingStarted(
            folder: folder,
            startedAt: Date(timeIntervalSince1970: 0),
            outputRoute: OutputRoute(transport: "BuiltIn", isLoudspeaker: true)
        )
        try writeCAF(folder.appendingPathComponent("mic.caf"), frameCount: 9_600)
        try writeCAF(folder.appendingPathComponent("system.caf"), frameCount: 48_000, amplitude: 0)
        var metadata = try await store.finalizeCompletedRecording(folder: folder, stats: nil)
        metadata.tracks.mic.routeChanges = 0
        metadata.tracks.system.routeChanges = 0
        metadata.audioHealth.systemSilent = true
        try AtomicJSON.write(metadata, to: MeetingStore.metadataURL(in: folder))

        _ = try await CompressionJob().perform(folder: folder, store: store)

        let (left, right) = try decodeStereo(folder.appendingPathComponent("audio.m4a"))
        XCTAssertLessThan(left.count, 20_000)
        XCTAssertEqual(left.count, right.count)
        let peak = left.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.5)
    }

    func testFullLengthSilentMicFallsBackToSystemIncludingQuietAudio() async throws {
        // A zero-filled mic has a healthy duration. Duration alone cannot justify
        // discarding the only captured speech, even below the short-mic RMS floor.
        let store = MeetingStore(root: root)
        for amplitude: Float in [0.7, 0.003] {
            let folder = root.appendingPathComponent("silent-mic-\(amplitude)")
            _ = try await store.markRecordingStarted(
                folder: folder,
                startedAt: Date(timeIntervalSince1970: 0),
                outputRoute: OutputRoute(isLoudspeaker: true)
            )
            let mic = folder.appendingPathComponent("mic.caf")
            let system = folder.appendingPathComponent("system.caf")
            try writeCAF(mic, amplitude: 0)
            try writeCAF(system, amplitude: amplitude)
            let stats = RecordingStats(
                mic: TrackStats(url: mic, rms: 0, peak: 0, droppedBytes: 0),
                system: TrackStats(url: system, rms: Double(amplitude) / sqrt(2), peak: amplitude, droppedBytes: 0)
            )
            _ = try await store.finalizeCompletedRecording(folder: folder, stats: stats)

            _ = try await CompressionJob().perform(folder: folder, store: store)

            let (left, right) = try decodeStereo(folder.appendingPathComponent("audio.m4a"))
            XCTAssertGreaterThan(left.map(abs).max() ?? 0, amplitude / 2)
            XCTAssertGreaterThan(right.map(abs).max() ?? 0, amplitude / 2)
            XCTAssertLessThan(zip(left, right).map { abs($0 - $1) }.max() ?? 0, 0.01)
        }
    }

    func testLoudspeakerWithUnknownSystemLevelKeepsSurvivingMic() async throws {
        let folder = root.appendingPathComponent("2026-06-09 15-02-00 — Unknown system level")
        let store = MeetingStore(root: root)
        _ = try await store.markRecordingStarted(
            folder: folder,
            startedAt: Date(timeIntervalSince1970: 0),
            outputRoute: OutputRoute(transport: "BuiltIn", isLoudspeaker: true)
        )
        try writeCAF(folder.appendingPathComponent("mic.caf"), frameCount: 9_600)
        try writeCAF(folder.appendingPathComponent("system.caf"), divisor: 7, frameCount: 48_000)
        var metadata = try await store.finalizeCompletedRecording(folder: folder, stats: nil)
        metadata.tracks.mic.routeChanges = 0
        metadata.tracks.system.routeChanges = 0
        try AtomicJSON.write(metadata, to: MeetingStore.metadataURL(in: folder))

        _ = try await CompressionJob().perform(folder: folder, store: store)

        let (left, _) = try decodeStereo(folder.appendingPathComponent("audio.m4a"))
        XCTAssertLessThan(left.count, 20_000)
        XCTAssertGreaterThan(left.map(abs).max() ?? 0, 0.5)
    }

    func testLoudspeakerWithSparseSystemSoundKeepsSurvivingMic() async throws {
        let folder = root.appendingPathComponent("2026-06-09 15-03-00 — Sparse system")
        let store = MeetingStore(root: root)
        _ = try await store.markRecordingStarted(
            folder: folder,
            startedAt: Date(timeIntervalSince1970: 0),
            outputRoute: OutputRoute(transport: "BuiltIn", isLoudspeaker: true)
        )
        try writeCAF(folder.appendingPathComponent("mic.caf"), frameCount: 9_600)
        try writeCAF(folder.appendingPathComponent("system.caf"), divisor: 7, frameCount: 48_000, activeFrames: 5)
        var metadata = try await store.finalizeCompletedRecording(folder: folder, stats: nil)
        metadata.tracks.mic.routeChanges = 0
        metadata.tracks.system.routeChanges = 0
        metadata.tracks.system.rms = 0.0035
        metadata.tracks.system.peak = 0.54
        metadata.audioHealth.systemSilent = false
        try AtomicJSON.write(metadata, to: MeetingStore.metadataURL(in: folder))

        _ = try await CompressionJob().perform(folder: folder, store: store)

        let (left, _) = try decodeStereo(folder.appendingPathComponent("audio.m4a"))
        XCTAssertLessThan(left.count, 20_000)
        XCTAssertGreaterThan(left.map(abs).max() ?? 0, 0.5)
    }

    func testChangedRoutesKeepBothTracksRegardlessOfStartingRoute() async throws {
        // Returning to speakers does not undo the headphone interval. The persisted
        // counters, not the final device, must prevent discarding the remote voice.
        let cases: [(name: String, loudspeaker: Bool, micChanges: Int, systemChanges: Int)] = [
            ("speakers-to-headphones", true, 0, 1),
            ("speakers-to-headphones-and-back", true, 0, 2),
            ("headphones-to-speakers", false, 0, 1),
            ("headphones-to-speakers-and-back", false, 0, 2),
            ("input-changed", true, 1, 0)
        ]
        let store = MeetingStore(root: root)
        for test in cases {
            let folder = root.appendingPathComponent(test.name)
            _ = try await store.markRecordingStarted(
                folder: folder,
                startedAt: Date(timeIntervalSince1970: 0),
                outputRoute: OutputRoute(isLoudspeaker: test.loudspeaker)
            )
            try writeCAF(folder.appendingPathComponent("mic.caf"), divisor: 24)
            try writeCAF(folder.appendingPathComponent("system.caf"), divisor: 7, frameCount: 19_200)
            let stats = RecordingStats(
                mic: TrackStats(
                    url: folder.appendingPathComponent("mic.caf"), rms: 0.7, peak: 1,
                    droppedBytes: 0, routeChanges: test.micChanges
                ),
                system: TrackStats(
                    url: folder.appendingPathComponent("system.caf"), rms: 0.7, peak: 1,
                    droppedBytes: 0, routeChanges: test.systemChanges
                )
            )
            _ = try await store.finalizeCompletedRecording(folder: folder, stats: stats)

            _ = try await CompressionJob().perform(folder: folder, store: store)

            let (left, right) = try decodeStereo(folder.appendingPathComponent("audio.m4a"))
            XCTAssertGreaterThanOrEqual(right.count, 19_200, test.name)
            XCTAssertGreaterThan(left.map(abs).max() ?? 0, 0.5, test.name)
            XCTAssertGreaterThan(right.suffix(9_600).map(abs).max() ?? 0, 0.5, test.name)
            let maxDelta = zip(left, right).map { abs($0 - $1) }.max() ?? 0
            XCTAssertGreaterThan(maxDelta, 0.5, "\(test.name): tracks were reduced to centered mono")
        }
    }

    func testRecoveredLoudspeakerRecordingWithUnknownRoutesKeepsBothTracks() async throws {
        // A crash leaves the starting route but no live counters. Treating missing
        // counters as zero would lose any headphone interval that happened before it.
        let folder = root.appendingPathComponent("2026-10-13 12-00-00")
        let store = MeetingStore(root: root)
        _ = try await store.markRecordingStarted(
            folder: folder,
            startedAt: Date(timeIntervalSince1970: 0),
            outputRoute: OutputRoute(isLoudspeaker: true)
        )
        try writeCAF(folder.appendingPathComponent("mic.caf"), divisor: 24)
        try writeCAF(folder.appendingPathComponent("system.caf"), divisor: 7, frameCount: 19_200)
        let recovered = try await store.recoverInterruptedRecordings()
        XCTAssertEqual(recovered.filter(\.didRecover).count, 1)
        let snapshot = try await store.snapshot(folder: folder)
        let metadata = try XCTUnwrap(snapshot.metadata)
        XCTAssertNil(metadata.tracks.mic.routeChanges)
        XCTAssertNil(metadata.tracks.system.routeChanges)

        _ = try await CompressionJob().perform(folder: folder, store: store)

        let (left, right) = try decodeStereo(folder.appendingPathComponent("audio.m4a"))
        XCTAssertGreaterThanOrEqual(right.count, 19_200)
        XCTAssertGreaterThan(left.map(abs).max() ?? 0, 0.5)
        XCTAssertGreaterThan(right.suffix(9_600).map(abs).max() ?? 0, 0.5)
        let maxDelta = zip(left, right).map { abs($0 - $1) }.max() ?? 0
        XCTAssertGreaterThan(maxDelta, 0.5)
    }

    func testRouteChangeDoesNotStretchSystemAudioAsClockDrift() async throws {
        let store = MeetingStore(root: root)

        func compressedLength(micRouteChanges: Int) async throws -> AVAudioFramePosition {
            let folder = root.appendingPathComponent("route-changes-\(micRouteChanges)")
            _ = try await store.markRecordingStarted(folder: folder, startedAt: Date(timeIntervalSince1970: 0))
            try writeCAF(folder.appendingPathComponent("mic.caf"), frameCount: 48_000)
            try writeCAF(folder.appendingPathComponent("system.caf"), frameCount: 48_384)
            var metadata = try await store.finalizeCompletedRecording(folder: folder, stats: nil)
            metadata.tracks.mic.routeChanges = micRouteChanges
            metadata.tracks.system.routeChanges = 0
            try AtomicJSON.write(metadata, to: MeetingStore.metadataURL(in: folder))

            _ = try await CompressionJob().perform(folder: folder, store: store)
            return try AVAudioFile(forReading: folder.appendingPathComponent("audio.m4a")).length
        }

        let corrected = try await compressedLength(micRouteChanges: 0)
        let unchanged = try await compressedLength(micRouteChanges: 1)
        XCTAssertGreaterThan(unchanged, corrected + 250)
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

    private func writeCAF(
        _ url: URL,
        divisor: Float = 24,
        frameCount: AVAudioFrameCount = 9_600,
        amplitude: Float = 1,
        activeFrames: Int? = nil
    ) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AudioFormat.pcmFormat
        let file = try AVAudioFile(
            forWriting: url,
            settings: AudioFormat.cafSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?.pointee else {
            XCTFail("Could not allocate CAF test buffer")
            return
        }

        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            channel[frame] = frame < (activeFrames ?? Int(frameCount))
                ? amplitude * sin(Float(frame) / divisor)
                : 0
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
