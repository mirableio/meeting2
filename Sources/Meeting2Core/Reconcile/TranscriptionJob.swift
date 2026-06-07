import Foundation

public struct MeetingTranscriptionResult: Equatable {
    public let folder: URL
    public let transcriptURL: URL
    public let markdownURL: URL
    public let provider: String
    public let model: String
    public let textCharacterCount: Int

    public var didTranscribe: Bool {
        textCharacterCount > 0
    }
}

public struct TranscriptionJob {
    public init() {}

    public func needsWork(_ snapshot: MeetingSnapshot) -> Bool {
        // Transcription is an after-the-fact reconciler: only finalized recordings whose
        // single combined `audio.m4a` exists are eligible. A missing transcript is the
        // queue item. We do not exclude stale `.running` metadata, because a crash during
        // upload would leave that status behind and the file-derived reconciler must retry.
        snapshot.metadata?.endedAt != nil &&
            snapshot.hasAudioM4A &&
            !snapshot.hasTranscript
    }

    public func runPending(
        in store: MeetingStore,
        transcriber: any Transcriber
    ) async throws -> [MeetingTranscriptionResult] {
        var results: [MeetingTranscriptionResult] = []

        for snapshot in try await store.scan() where needsWork(snapshot) {
            results.append(try await perform(folder: snapshot.folder, store: store, transcriber: transcriber))
        }

        return results
    }

    public func perform(
        folder: URL,
        store: MeetingStore,
        transcriber: any Transcriber
    ) async throws -> MeetingTranscriptionResult {
        let snapshot = try await store.snapshot(folder: folder)
        guard needsWork(snapshot), let metadata = snapshot.metadata else {
            throw CaptureError.invalidState("Recording is not ready for transcription: \(folder.path)")
        }

        let transcriptURL = folder.appendingPathComponent("transcript.json")
        let markdownURL = folder.appendingPathComponent("transcript.md")
        let audioURL = folder.appendingPathComponent("audio.m4a")

        do {
            _ = try await store.markTranscriptionRunning(folder: folder)
            // The combined file is already the stereo, time-aligned input the transcriber
            // wants (mic left, system right), so send it straight through — no temp build.
            let transcript = try await transcriber.transcribe(
                audioFile: audioURL,
                hints: TranscriptionHints(meetingID: metadata.id, displayName: metadata.displayName)
            )
            try writeTranscript(transcript, transcriptURL: transcriptURL, markdownURL: markdownURL)
            _ = try await store.markTranscriptionCompleted(folder: folder)

            DebugDiagnostics.log(
                recordingFolder: folder,
                "transcription finished provider=\(transcript.provider) model=\(transcript.model) " +
                "characters=\(transcript.text.count)"
            )

            return MeetingTranscriptionResult(
                folder: folder,
                transcriptURL: transcriptURL,
                markdownURL: markdownURL,
                provider: transcript.provider,
                model: transcript.model,
                textCharacterCount: transcript.text.count
            )
        } catch {
            _ = try? await store.markTranscriptionFailed(folder: folder, error: error)
            DebugDiagnostics.log(recordingFolder: folder, "transcription failed error=\(error)")
            throw error
        }
    }

    private func writeTranscript(
        _ transcript: Transcript,
        transcriptURL: URL,
        markdownURL: URL
    ) throws {
        try writeTextAtomically(TranscriptRenderer.markdown(from: transcript), to: markdownURL)
        try AtomicJSON.write(transcript, to: transcriptURL)
    }

    private func writeTextAtomically(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try Data(text.utf8).write(to: temporaryURL, options: [.withoutOverwriting])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(
                    url,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }
}
