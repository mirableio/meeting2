import Foundation

public struct PostRecordingPipelineResult: Equatable {
    public let compressionResults: [MeetingCompressionResult]
    public let transcriptionResults: [MeetingTranscriptionResult]

    public init(
        compressionResults: [MeetingCompressionResult],
        transcriptionResults: [MeetingTranscriptionResult]
    ) {
        self.compressionResults = compressionResults
        self.transcriptionResults = transcriptionResults
    }
}

public enum PostRecordingPipelineError: Error, CustomStringConvertible {
    case compression(Error)
    case transcription(Error)

    public var description: String {
        switch self {
        case let .compression(error):
            return "Compression failed: \(error)"
        case let .transcription(error):
            return "Transcription failed: \(error)"
        }
    }
}

/// Which stage of the after-the-fact work is running right now, so the UI can say
/// "Processing audio…" then "Transcribing…" instead of an opaque spinner. Emitted only
/// when that stage actually has work to do (no empty "compressing" blip on an idle launch).
public enum PostRecordingPhase: Sendable, Equatable {
    case compressing
    case transcribing
}

public typealias PostRecordingPhaseHandler = @Sendable (PostRecordingPhase) -> Void

public typealias PostRecordingTranscriberFactory = @Sendable ([URL]) throws -> any Transcriber

public actor PostRecordingPipeline {
    // Owns the after-the-fact reconciler queue. This is core policy, not menu policy:
    // finalized recordings are recovered, compressed, then transcribed in a serial,
    // idempotent order so app launch, manual stop, and future auto-detect all drive the
    // same file-derived workflow.
    private let store: MeetingStore
    private let envFileCandidates: @Sendable () -> [URL]
    private let transcriberFactory: PostRecordingTranscriberFactory
    private var compressionTask: Task<[MeetingCompressionResult], Error>?
    private var transcriptionTask: Task<[MeetingTranscriptionResult], Error>?

    public init(store: MeetingStore) {
        self.init(
            store: store,
            envFileCandidates: {
                Self.defaultTranscriptionEnvFileCandidates()
            }
        )
    }

    public init(
        store: MeetingStore,
        envFileCandidates: @escaping @Sendable () -> [URL]
    ) {
        self.init(
            store: store,
            envFileCandidates: envFileCandidates,
            transcriberFactory: { envFiles in
                GeminiTranscriber(configuration: try .fromEnvironment(envFiles: envFiles))
            }
        )
    }

    public init(
        store: MeetingStore,
        envFileCandidates: @escaping @Sendable () -> [URL],
        transcriberFactory: @escaping PostRecordingTranscriberFactory
    ) {
        self.store = store
        self.envFileCandidates = envFileCandidates
        self.transcriberFactory = transcriberFactory
    }

    public func recoverInterruptedRecordings() async throws -> [MeetingRecoveryResult] {
        // Reconcile metadata to files first: heal any transcription status a crash left
        // stale (transcript on disk ⇒ job done), then recover interrupted raw recordings.
        await store.reconcileTranscriptionJobStatus()
        return try await store.recoverInterruptedRecordings()
    }

    public func runAfterRecording(
        folder: URL,
        onPhase: PostRecordingPhaseHandler? = nil
    ) async throws -> PostRecordingPipelineResult {
        let compressionResults: [MeetingCompressionResult]
        do {
            compressionResults = try await enqueueCompression { store in
                // A just-stopped recording always has CAFs to merge, so this stage has work.
                onPhase?(.compressing)
                return [try await CompressionJob().perform(folder: folder, store: store)]
            }
        } catch {
            throw PostRecordingPipelineError.compression(error)
        }

        let transcriptionResults: [MeetingTranscriptionResult]
        do {
            transcriptionResults = try await runPendingTranscription(onPhase: onPhase)
        } catch {
            throw PostRecordingPipelineError.transcription(error)
        }

        return PostRecordingPipelineResult(
            compressionResults: compressionResults,
            transcriptionResults: transcriptionResults
        )
    }

    public func runPendingCompressionAndTranscription(
        onPhase: PostRecordingPhaseHandler? = nil
    ) async throws -> PostRecordingPipelineResult {
        let compressionResults: [MeetingCompressionResult]
        do {
            compressionResults = try await enqueueCompression { store in
                // Announce "compressing" only when something is actually pending, so an
                // idle launch (nothing to do) doesn't flash a phantom progress state.
                let job = CompressionJob()
                let pending = try await store.scan().filter { job.needsWork($0) }
                guard !pending.isEmpty else { return [] }
                onPhase?(.compressing)
                var results: [MeetingCompressionResult] = []
                for snapshot in pending {
                    results.append(try await job.perform(folder: snapshot.folder, store: store))
                }
                return results
            }
        } catch {
            throw PostRecordingPipelineError.compression(error)
        }

        let transcriptionResults: [MeetingTranscriptionResult]
        do {
            transcriptionResults = try await runPendingTranscription(onPhase: onPhase)
        } catch {
            throw PostRecordingPipelineError.transcription(error)
        }

        return PostRecordingPipelineResult(
            compressionResults: compressionResults,
            transcriptionResults: transcriptionResults
        )
    }

    public func runPendingTranscriptionOnly(
        onPhase: PostRecordingPhaseHandler? = nil
    ) async throws -> PostRecordingPipelineResult {
        _ = try? await compressionTask?.value
        do {
            return PostRecordingPipelineResult(
                compressionResults: [],
                transcriptionResults: try await runPendingTranscription(onPhase: onPhase)
            )
        } catch {
            throw PostRecordingPipelineError.transcription(error)
        }
    }

    private func enqueueCompression(
        operation: @escaping @Sendable (MeetingStore) async throws -> [MeetingCompressionResult]
    ) async throws -> [MeetingCompressionResult] {
        let previousTask = compressionTask
        let store = store
        let task = Task.detached(priority: .utility) {
            _ = try? await previousTask?.value
            return try await operation(store)
        }
        compressionTask = task
        return try await task.value
    }

    private func runPendingTranscription(
        onPhase: PostRecordingPhaseHandler? = nil
    ) async throws -> [MeetingTranscriptionResult] {
        try await enqueueTranscription { store, envFiles, transcriberFactory in
            let job = TranscriptionJob()
            let pending = try await store.scan().filter { job.needsWork($0) }
            guard !pending.isEmpty else { return [] }
            onPhase?(.transcribing)

            let transcriber: any Transcriber
            do {
                transcriber = try transcriberFactory(envFiles)
            } catch {
                // Building the transcriber failed before any recording was touched. That's a
                // global configuration problem (typically: no API key), not a per-recording
                // failure — so do NOT stain each folder's job state with `.failed`. Just
                // surface it; the caller decides whether to nag (it doesn't, for a missing
                // key). Each recording stays pending and transcribes once a key is set.
                throw error
            }

            var results: [MeetingTranscriptionResult] = []
            for snapshot in pending {
                results.append(
                    try await job.perform(
                        folder: snapshot.folder,
                        store: store,
                        transcriber: transcriber
                    )
                )
            }
            return results
        }
    }

    private func enqueueTranscription(
        operation: @escaping @Sendable (
            MeetingStore,
            [URL],
            @escaping PostRecordingTranscriberFactory
        ) async throws -> [MeetingTranscriptionResult]
    ) async throws -> [MeetingTranscriptionResult] {
        let previousTask = transcriptionTask
        let store = store
        let envFiles = envFileCandidates()
        let transcriberFactory = transcriberFactory
        let task = Task.detached(priority: .utility) {
            _ = try? await previousTask?.value
            return try await operation(store, envFiles, transcriberFactory)
        }
        transcriptionTask = task
        return try await task.value
    }

    private static func defaultTranscriptionEnvFileCandidates() -> [URL] {
        // Finder-launched apps do not inherit a shell's environment. During local
        // development, support both the current working directory and SwiftPM packaged
        // app locations under `.build`. Product settings/keychain should replace this
        // dev lookup later; keeping it here avoids baking `.env` into menu presentation.
        var candidates: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"),
            URL(fileURLWithPath: NSString(string: "~/.meeting2.env").expandingTildeInPath)
        ]

        var directory = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<8 {
            candidates.append(directory.appendingPathComponent(".env"))
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
