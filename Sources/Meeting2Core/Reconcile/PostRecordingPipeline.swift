import Foundation

/// A single recording whose compression or transcription failed this run. Carried in the
/// result (not thrown) so one bad item never aborts the batch — `message` rather than the
/// raw `Error` keeps the result `Equatable`. The per-folder job status is already persisted
/// by the job itself; this just lets the UI report the outcome.
public struct PostRecordingFailure: Equatable {
    public let folder: URL
    public let message: String

    public init(folder: URL, message: String) {
        self.folder = folder
        self.message = message
    }
}

public struct PostRecordingPipelineResult: Equatable {
    public let compressionResults: [MeetingCompressionResult]
    public let transcriptionResults: [MeetingTranscriptionResult]
    public let compressionFailures: [PostRecordingFailure]
    public let transcriptionFailures: [PostRecordingFailure]

    public init(
        compressionResults: [MeetingCompressionResult],
        transcriptionResults: [MeetingTranscriptionResult],
        compressionFailures: [PostRecordingFailure] = [],
        transcriptionFailures: [PostRecordingFailure] = []
    ) {
        self.compressionResults = compressionResults
        self.transcriptionResults = transcriptionResults
        self.compressionFailures = compressionFailures
        self.transcriptionFailures = transcriptionFailures
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

/// Which stage of the after-the-fact work is running. Reused as the `phase` of
/// `PostRecordingProgress` so the UI can say "Processing audio…" then "Transcribing…".
public enum PostRecordingPhase: Sendable, Equatable {
    case compressing
    case transcribing
}

/// Live progress for the menu: which stage, and which item of how many. Emitted once per
/// item, so the menu can show "Transcribing 2 of 3…" (the count is the UI's to hide when
/// `total == 1`). Only emitted when a stage actually has work — no phantom blip on an idle
/// launch.
public struct PostRecordingProgress: Sendable, Equatable {
    public let phase: PostRecordingPhase
    public let current: Int   // 1-based index of the item in progress
    public let total: Int

    public init(phase: PostRecordingPhase, current: Int, total: Int) {
        self.phase = phase
        self.current = current
        self.total = total
    }
}

public typealias PostRecordingProgressHandler = @Sendable (PostRecordingProgress) -> Void

public typealias PostRecordingTranscriberFactory = @Sendable ([URL]) throws -> any Transcriber

private struct CompressionBatch {
    var results: [MeetingCompressionResult] = []
    var failures: [PostRecordingFailure] = []
}

private struct TranscriptionBatch {
    var results: [MeetingTranscriptionResult] = []
    var failures: [PostRecordingFailure] = []
}

public actor PostRecordingPipeline {
    // Owns the after-the-fact reconciler queue. This is core policy, not menu policy:
    // finalized recordings are recovered, compressed, then transcribed in a serial,
    // idempotent order so app launch, manual stop, and future auto-detect all drive the
    // same file-derived workflow. Items are processed independently: a per-item failure is
    // recorded and the batch continues, so one bad recording never blocks the others.
    private let store: MeetingStore
    private let envFileCandidates: @Sendable () -> [URL]
    private let transcriberFactory: PostRecordingTranscriberFactory
    private var compressionTask: Task<CompressionBatch, Error>?
    private var transcriptionTask: Task<TranscriptionBatch, Error>?

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

    /// How many finalized recordings still await a transcript. Cheap, read-only, and not
    /// chained behind the run queue — it's a live snapshot for the menu's "N pending" label.
    public func pendingTranscriptionCount() async -> Int {
        let job = TranscriptionJob()
        let snapshots = (try? await store.scan()) ?? []
        return snapshots.filter { job.needsWork($0) }.count
    }

    public func recoverInterruptedRecordings() async throws -> [MeetingRecoveryResult] {
        // Reconcile metadata to files first: heal any transcription status a crash left
        // stale (transcript on disk ⇒ job done), then recover interrupted raw recordings.
        await store.reconcileTranscriptionJobStatus()
        return try await store.recoverInterruptedRecordings()
    }

    public func runAfterRecording(
        folder: URL,
        onProgress: PostRecordingProgressHandler? = nil
    ) async throws -> PostRecordingPipelineResult {
        let compression: CompressionBatch
        do {
            compression = try await enqueueCompression { store in
                // A just-stopped recording always has CAFs to merge, so this stage has work.
                onProgress?(PostRecordingProgress(phase: .compressing, current: 1, total: 1))
                do {
                    let result = try await CompressionJob().perform(folder: folder, store: store)
                    return CompressionBatch(results: [result], failures: [])
                } catch {
                    return CompressionBatch(
                        results: [],
                        failures: [PostRecordingFailure(folder: folder, message: String(describing: error))]
                    )
                }
            }
        } catch {
            throw PostRecordingPipelineError.compression(error)
        }

        let transcription: TranscriptionBatch
        do {
            transcription = try await runPendingTranscription(onProgress: onProgress)
        } catch {
            throw PostRecordingPipelineError.transcription(error)
        }

        return assemble(compression, transcription)
    }

    public func runPendingCompressionAndTranscription(
        onProgress: PostRecordingProgressHandler? = nil
    ) async throws -> PostRecordingPipelineResult {
        let compression: CompressionBatch
        do {
            compression = try await enqueueCompression { store in
                let job = CompressionJob()
                let pending = try await store.scan().filter { job.needsWork($0) }
                guard !pending.isEmpty else { return CompressionBatch() }

                var batch = CompressionBatch()
                let total = pending.count
                for (index, snapshot) in pending.enumerated() {
                    onProgress?(PostRecordingProgress(phase: .compressing, current: index + 1, total: total))
                    do {
                        batch.results.append(try await job.perform(folder: snapshot.folder, store: store))
                    } catch {
                        batch.failures.append(
                            PostRecordingFailure(folder: snapshot.folder, message: String(describing: error))
                        )
                    }
                }
                return batch
            }
        } catch {
            throw PostRecordingPipelineError.compression(error)
        }

        let transcription: TranscriptionBatch
        do {
            transcription = try await runPendingTranscription(onProgress: onProgress)
        } catch {
            throw PostRecordingPipelineError.transcription(error)
        }

        return assemble(compression, transcription)
    }

    public func runPendingTranscriptionOnly(
        onProgress: PostRecordingProgressHandler? = nil
    ) async throws -> PostRecordingPipelineResult {
        _ = try? await compressionTask?.value
        let transcription: TranscriptionBatch
        do {
            transcription = try await runPendingTranscription(onProgress: onProgress)
        } catch {
            throw PostRecordingPipelineError.transcription(error)
        }
        return assemble(CompressionBatch(), transcription)
    }

    private func assemble(_ compression: CompressionBatch, _ transcription: TranscriptionBatch) -> PostRecordingPipelineResult {
        PostRecordingPipelineResult(
            compressionResults: compression.results,
            transcriptionResults: transcription.results,
            compressionFailures: compression.failures,
            transcriptionFailures: transcription.failures
        )
    }

    private func enqueueCompression(
        operation: @escaping @Sendable (MeetingStore) async throws -> CompressionBatch
    ) async throws -> CompressionBatch {
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
        onProgress: PostRecordingProgressHandler? = nil
    ) async throws -> TranscriptionBatch {
        try await enqueueTranscription { store, envFiles, transcriberFactory in
            let job = TranscriptionJob()
            let pending = TranscriptionJob.orderedFreshFirst(try await store.scan().filter { job.needsWork($0) })
            guard !pending.isEmpty else { return TranscriptionBatch() }

            let transcriber: any Transcriber
            do {
                transcriber = try transcriberFactory(envFiles)
            } catch {
                // Building the transcriber failed before any recording was touched. That's a
                // global configuration problem (typically: no API key), not a per-recording
                // failure — so do NOT stain each folder's job state with `.failed`. Throw it;
                // the caller decides whether to nag (it doesn't, for a missing key). Each
                // recording stays pending and transcribes once a key is set.
                throw error
            }

            var batch = TranscriptionBatch()
            let total = pending.count
            for (index, snapshot) in pending.enumerated() {
                onProgress?(PostRecordingProgress(phase: .transcribing, current: index + 1, total: total))
                do {
                    batch.results.append(
                        try await job.perform(folder: snapshot.folder, store: store, transcriber: transcriber)
                    )
                } catch {
                    // `perform` already marked this folder failed in metadata; record it for
                    // the UI and move on so a single bad item can't block the rest.
                    batch.failures.append(
                        PostRecordingFailure(folder: snapshot.folder, message: String(describing: error))
                    )
                }
            }
            return batch
        }
    }

    private func enqueueTranscription(
        operation: @escaping @Sendable (
            MeetingStore,
            [URL],
            @escaping PostRecordingTranscriberFactory
        ) async throws -> TranscriptionBatch
    ) async throws -> TranscriptionBatch {
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
