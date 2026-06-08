import AVFoundation
@testable import Meeting2Core
import XCTest

final class PostRecordingPipelineTests: XCTestCase {
    // This pins the orchestration contract that used to live in the menu controller:
    // a finalized raw recording is compressed first, then the compressed stereo input is
    // handed to the transcriber. The fake transcriber keeps the test local and fast.
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meeting2PipelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testPendingPipelineCompressesBeforeTranscribing() async throws {
        let folder = root.appendingPathComponent("2026-06-05 12-00-00 — Pipeline")
        let store = MeetingStore(root: root)
        let pipeline = PostRecordingPipeline(
            store: store,
            envFileCandidates: { [] },
            transcriberFactory: { _ in
                PipelineFakeTranscriber(transcriptText: "speaker 1: pipeline complete")
            }
        )

        _ = try await store.markRecordingStarted(folder: folder, startedAt: Date(timeIntervalSince1970: 0))
        try writeCAF(folder.appendingPathComponent("mic.caf"), frequencyDivisor: 20)
        try writeCAF(folder.appendingPathComponent("system.caf"), frequencyDivisor: 35)
        _ = try await store.finalizeCompletedRecording(folder: folder, stats: nil)

        let result = try await pipeline.runPendingCompressionAndTranscription()

        XCTAssertEqual(result.compressionResults.count, 1)
        XCTAssertEqual(result.transcriptionResults.count, 1)
        XCTAssertTrue(result.compressionResults[0].didCompress)
        XCTAssertEqual(result.transcriptionResults[0].textCharacterCount, "speaker 1: pipeline complete".count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.caf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("system.caf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.json").path))

        let snapshot = try await store.snapshot(folder: folder)
        XCTAssertEqual(snapshot.state, .transcribed)
    }

    func testMissingTranscriberConfigDoesNotMarkRecordingsFailed() async throws {
        // A missing API key means the transcriber can't be built at all. That's a global
        // config problem, not a per-recording failure — the recording's job state must stay
        // clean (pending), so it transcribes later once a key is set.
        let folder = root.appendingPathComponent("2026-06-05 12-00-00 — NoKey")
        let store = MeetingStore(root: root)
        let pipeline = PostRecordingPipeline(
            store: store,
            envFileCandidates: { [] },
            transcriberFactory: { _ in
                throw TranscriptionConfigurationError.missingAPIKey
            }
        )

        _ = try await store.markRecordingStarted(folder: folder, startedAt: Date(timeIntervalSince1970: 0))
        try writeCAF(folder.appendingPathComponent("mic.caf"), frequencyDivisor: 20)
        try writeCAF(folder.appendingPathComponent("system.caf"), frequencyDivisor: 35)
        _ = try await store.finalizeCompletedRecording(folder: folder, stats: nil)

        do {
            _ = try await pipeline.runPendingCompressionAndTranscription()
            XCTFail("Expected the run to throw when the transcriber cannot be built")
        } catch {
            // Expected.
        }

        // Compression still happened; only transcription couldn't run.
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.m4a").path))
        let metadata = try AtomicJSON.read(MeetingMetadata.self, from: MeetingStore.metadataURL(in: folder))
        XCTAssertEqual(metadata.jobs.transcription.status, .pending)
        XCTAssertNil(metadata.jobs.transcription.lastError)
    }

    func testPerItemFailureDoesNotBlockOtherTranscriptions() async throws {
        let store = MeetingStore(root: root)
        let a = try await finalize("2026-06-05 12-00-00 — A", in: store)
        let b = try await finalize("2026-06-05 12-01-00 — B", in: store)
        let c = try await finalize("2026-06-05 12-02-00 — C", in: store)

        let pipeline = PostRecordingPipeline(
            store: store,
            envFileCandidates: { [] },
            transcriberFactory: { _ in SelectiveFailTranscriber(failIDs: ["2026-06-05 12-01-00"]) } // B fails
        )

        let result = try await pipeline.runPendingCompressionAndTranscription()

        // The middle item failed; the other two still got transcribed — no batch abort.
        XCTAssertEqual(result.transcriptionResults.count, 2)
        XCTAssertEqual(result.transcriptionFailures.count, 1)
        XCTAssertEqual(result.transcriptionFailures.first?.folder.lastPathComponent, "2026-06-05 12-01-00 — B")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.appendingPathComponent("transcript.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.appendingPathComponent("transcript.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.appendingPathComponent("transcript.json").path))

        // B is marked failed but still retryable (no transcript).
        let bMeta = try AtomicJSON.read(MeetingMetadata.self, from: MeetingStore.metadataURL(in: b))
        XCTAssertEqual(bMeta.jobs.transcription.status, .failed)
    }

    func testFailedTranscriptionsRunLast() async throws {
        let store = MeetingStore(root: root)
        let older = try await finalize("2026-06-05 12-00-00 — Older", in: store)
        let newer = try await finalize("2026-06-05 12-05-00 — Newer", in: store)
        // Compress both so they're transcription-pending, then mark the older one previously failed.
        _ = try await CompressionJob().perform(folder: older, store: store)
        _ = try await CompressionJob().perform(folder: newer, store: store)
        _ = try await store.markTranscriptionFailed(folder: older, error: CaptureError.invalidState("prior timeout"))

        let recorder = CallRecorder()
        let pipeline = PostRecordingPipeline(
            store: store,
            envFileCandidates: { [] },
            transcriberFactory: { _ in OrderRecordingTranscriber(recorder: recorder) }
        )

        _ = try await pipeline.runPendingTranscriptionOnly()

        // Fresh (newer) runs before the previously-failed (older), despite oldest-first scan.
        XCTAssertEqual(recorder.ids, ["2026-06-05 12-05-00", "2026-06-05 12-00-00"])
    }

    func testProgressReportsItemAndTotal() async throws {
        let store = MeetingStore(root: root)
        _ = try await finalize("2026-06-05 12-00-00 — One", in: store)
        _ = try await finalize("2026-06-05 12-05-00 — Two", in: store)

        let progress = ProgressRecorder()
        let pipeline = PostRecordingPipeline(
            store: store,
            envFileCandidates: { [] },
            transcriberFactory: { _ in PipelineFakeTranscriber(transcriptText: "ok") }
        )

        _ = try await pipeline.runPendingCompressionAndTranscription(onProgress: { progress.record($0) })

        let transcribing = progress.items.filter { $0.phase == .transcribing }
        XCTAssertEqual(transcribing.map(\.current), [1, 2])
        XCTAssertEqual(transcribing.map(\.total), [2, 2])
        let compressing = progress.items.filter { $0.phase == .compressing }
        XCTAssertEqual(compressing.map(\.current), [1, 2])
        XCTAssertEqual(compressing.map(\.total), [2, 2])
    }

    func testPendingTranscriptionCountTracksFiles() async throws {
        let store = MeetingStore(root: root)
        let pipeline = PostRecordingPipeline(
            store: store,
            envFileCandidates: { [] },
            transcriberFactory: { _ in PipelineFakeTranscriber(transcriptText: "ok") }
        )

        var count = await pipeline.pendingTranscriptionCount()
        XCTAssertEqual(count, 0)

        // Two finalized + compressed recordings are both pending a transcript.
        let a = try await finalize("2026-06-05 12-00-00 — A", in: store)
        let b = try await finalize("2026-06-05 12-01-00 — B", in: store)
        _ = try await CompressionJob().perform(folder: a, store: store)
        _ = try await CompressionJob().perform(folder: b, store: store)
        count = await pipeline.pendingTranscriptionCount()
        XCTAssertEqual(count, 2)

        // Once transcribed, none remain pending.
        _ = try await pipeline.runPendingTranscriptionOnly()
        count = await pipeline.pendingTranscriptionCount()
        XCTAssertEqual(count, 0)
    }

    func testCompressionFailureReportedAlongsideUnrelatedTranscriptionSuccess() async throws {
        // The scenario the menu must not hide: a just-stopped recording fails compression
        // while an older pending one transcribes fine. The result must carry BOTH outcomes so
        // the UI doesn't flash success and bury the failure.
        let store = MeetingStore(root: root)
        let old = try await finalize("2026-06-05 12-00-00 — Old", in: store)
        _ = try await CompressionJob().perform(folder: old, store: store) // audio.m4a, pending transcribe

        // A just-stopped recording whose CAF is unreadable, so its compression throws.
        let new = root.appendingPathComponent("2026-06-05 12-05-00 — New")
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        _ = try await store.markRecordingStarted(folder: new, startedAt: Date(timeIntervalSince1970: 300))
        try Data("not a real caf".utf8).write(to: new.appendingPathComponent("mic.caf"))

        let pipeline = PostRecordingPipeline(
            store: store,
            envFileCandidates: { [] },
            transcriberFactory: { _ in PipelineFakeTranscriber(transcriptText: "ok") }
        )

        let result = try await pipeline.runAfterRecording(folder: new)

        XCTAssertEqual(result.compressionFailures.count, 1)
        XCTAssertEqual(result.compressionFailures.first?.folder.lastPathComponent, "2026-06-05 12-05-00 — New")
        XCTAssertEqual(result.transcriptionResults.count, 1)
        XCTAssertEqual(result.transcriptionResults.first?.folder.lastPathComponent, "2026-06-05 12-00-00 — Old")
    }

    @discardableResult
    private func finalize(_ name: String, in store: MeetingStore) async throws -> URL {
        let folder = root.appendingPathComponent(name)
        _ = try await store.markRecordingStarted(folder: folder, startedAt: Date(timeIntervalSince1970: 0))
        try writeCAF(folder.appendingPathComponent("mic.caf"), frequencyDivisor: 20)
        try writeCAF(folder.appendingPathComponent("system.caf"), frequencyDivisor: 35)
        _ = try await store.finalizeCompletedRecording(folder: folder, stats: nil)
        return folder
    }

    private func writeCAF(_ url: URL, frequencyDivisor: Float) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(
            forWriting: url,
            settings: AudioFormat.cafSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let frameCount: AVAudioFrameCount = 9_600
        guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioFormat.pcmFormat, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?.pointee else {
            XCTFail("Could not allocate CAF test buffer")
            return
        }

        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            channel[frame] = sin(Float(frame) / frequencyDivisor)
        }

        try file.write(from: buffer)
    }
}

private struct PipelineFakeTranscriber: Transcriber {
    let id = "fake"
    let model = "fake-model"
    let transcriptText: String

    func transcribe(audioFile: URL, hints: TranscriptionHints) async throws -> Transcript {
        Transcript(provider: id, model: model, text: transcriptText)
    }
}

/// Fails for the given meeting IDs, succeeds otherwise — to prove one bad item is isolated.
private struct SelectiveFailTranscriber: Transcriber {
    let id = "fake"
    let model = "fake-model"
    let failIDs: Set<String>

    func transcribe(audioFile: URL, hints: TranscriptionHints) async throws -> Transcript {
        if failIDs.contains(hints.meetingID) {
            throw CaptureError.invalidState("boom \(hints.meetingID)")
        }
        return Transcript(provider: id, model: model, text: "ok")
    }
}

/// Records the order in which meetings are handed to it — to prove failed-last ordering.
private struct OrderRecordingTranscriber: Transcriber {
    let id = "fake"
    let model = "fake-model"
    let recorder: CallRecorder

    func transcribe(audioFile: URL, hints: TranscriptionHints) async throws -> Transcript {
        recorder.record(hints.meetingID)
        return Transcript(provider: id, model: model, text: "ok")
    }
}

private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(id)
    }

    var ids: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PostRecordingProgress] = []

    func record(_ progress: PostRecordingProgress) {
        lock.lock(); defer { lock.unlock() }
        storage.append(progress)
    }

    var items: [PostRecordingProgress] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
