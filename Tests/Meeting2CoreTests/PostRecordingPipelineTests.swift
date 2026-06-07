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
