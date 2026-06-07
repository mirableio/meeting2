import AVFoundation
@testable import Meeting2Core
import XCTest

final class TranscriptionJobTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meeting2TranscriptionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testTranscriptStoresModelTextVerbatimAndMarkdownRendersIt() throws {
        let text = """
            speaker 1: Привет.
            speaker 2: Hello.
            continued line.
            speaker 1: Great.
            """
        let transcript = Transcript(
            provider: "fake",
            model: "fake-model",
            text: text,
            createdAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(transcript.text, text)
        let markdown = TranscriptRenderer.markdown(from: transcript)
        XCTAssertTrue(markdown.contains("Provider: fake"))
        XCTAssertTrue(markdown.contains(text))
    }

    func testCombinedAudioBuilderCreatesReadableTwoChannelM4A() throws {
        let mic = root.appendingPathComponent("mic.caf")
        let system = root.appendingPathComponent("system.caf")
        let output = root.appendingPathComponent("audio.m4a")

        try writeMonoM4A(mic, frequencyDivisor: 20)
        try writeMonoM4A(system, frequencyDivisor: 35)

        try CombinedAudioBuilder().build(
            micURL: mic,
            systemURL: system,
            destinationURL: output,
            micOffsetSeconds: 0.05,
            systemOffsetSeconds: 0
        )

        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        XCTAssertGreaterThan(file.length, 0)
    }

    func testTranscriptionJobWritesTranscriptAndMarksDone() async throws {
        let folder = root.appendingPathComponent("2026-06-05 12-00-00 — Transcription")
        let store = MeetingStore(root: root)
        let transcriptText = "I can hear you.\n\nGreat, let's start."
        let transcriber = FakeTranscriber(transcriptText: transcriptText)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeStereoM4A(folder.appendingPathComponent("audio.m4a"))
        _ = try await store.markRecordingCompressed(folder: folder, now: Date(timeIntervalSince1970: 100))

        let result = try await TranscriptionJob().perform(folder: folder, store: store, transcriber: transcriber)

        XCTAssertEqual(result.textCharacterCount, transcriptText.count)
        XCTAssertTrue(transcriber.didReceiveReadableAudio)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.md").path))

        let transcript = try AtomicJSON.read(
            Transcript.self,
            from: folder.appendingPathComponent("transcript.json")
        )
        XCTAssertEqual(transcript.provider, "fake")
        XCTAssertEqual(transcript.text, transcriptText)

        let markdown = try String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains(transcriptText))

        let metadata = try AtomicJSON.read(MeetingMetadata.self, from: MeetingStore.metadataURL(in: folder))
        XCTAssertEqual(metadata.jobs.transcription.status, .done)
        XCTAssertNil(metadata.jobs.transcription.lastError)
        let snapshot = try await store.snapshot(folder: folder)
        XCTAssertFalse(TranscriptionJob().needsWork(snapshot))
    }

    func testTranscriptionFailureMarksJobFailedWithoutTranscript() async throws {
        let folder = root.appendingPathComponent("2026-06-05 12-00-00 — Failure")
        let store = MeetingStore(root: root)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeStereoM4A(folder.appendingPathComponent("audio.m4a"))
        _ = try await store.markRecordingCompressed(folder: folder, now: Date(timeIntervalSince1970: 100))

        do {
            _ = try await TranscriptionJob().perform(
                folder: folder,
                store: store,
                transcriber: FailingTranscriber()
            )
            XCTFail("Expected transcription failure")
        } catch {
            // Expected.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.json").path))
        let metadata = try AtomicJSON.read(MeetingMetadata.self, from: MeetingStore.metadataURL(in: folder))
        XCTAssertEqual(metadata.jobs.transcription.status, .failed)
        XCTAssertTrue(metadata.jobs.transcription.lastError?.contains("network failed") ?? false)
    }

    private func writeMonoM4A(_ url: URL, frequencyDivisor: Float) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: AudioFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ]
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let frameCount: AVAudioFrameCount = 4_800
            guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioFormat.pcmFormat, frameCapacity: frameCount),
                  let channel = buffer.floatChannelData?.pointee else {
                XCTFail("Could not allocate M4A test buffer")
                return
            }

            buffer.frameLength = frameCount
            for frame in 0..<Int(frameCount) {
                channel[frame] = sin(Float(frame) / frequencyDivisor)
            }

            try file.write(from: buffer)
        }
    }

    private func writeStereoM4A(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioFormat.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.sampleRate,
            channels: 2,
            interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let frameCount: AVAudioFrameCount = 4_800
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            XCTFail("Could not allocate stereo M4A test buffer")
            return
        }
        buffer.frameLength = frameCount
        for channelIndex in 0..<2 {
            guard let channel = buffer.floatChannelData?[channelIndex] else { continue }
            let divisor: Float = channelIndex == 0 ? 20 : 35
            for frame in 0..<Int(frameCount) {
                channel[frame] = sin(Float(frame) / divisor)
            }
        }

        try file.write(from: buffer)
    }
}

private final class FakeTranscriber: Transcriber {
    let id = "fake"
    let model = "fake-model"
    let transcriptText: String
    var didReceiveReadableAudio = false

    init(transcriptText: String) {
        self.transcriptText = transcriptText
    }

    func transcribe(audioFile: URL, hints: TranscriptionHints) async throws -> Transcript {
        let file = try AVAudioFile(forReading: audioFile)
        didReceiveReadableAudio = file.processingFormat.channelCount == 2 && file.length > 0
        return Transcript(provider: id, model: model, text: transcriptText)
    }
}

private struct FailingTranscriber: Transcriber {
    let id = "fake"
    let model = "fake-model"

    func transcribe(audioFile: URL, hints: TranscriptionHints) async throws -> Transcript {
        throw CaptureError.invalidState("network failed")
    }
}
